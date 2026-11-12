package com.henrikvindshoj.gitnote.data

import com.henrikvindshoj.gitnote.domain.ChangeKind
import com.henrikvindshoj.gitnote.domain.FileChange
import com.henrikvindshoj.gitnote.domain.GitNoteException
import com.henrikvindshoj.gitnote.domain.MarkdownEntry
import com.henrikvindshoj.gitnote.domain.RepositoryAddress
import com.henrikvindshoj.gitnote.domain.SyncResult
import com.henrikvindshoj.gitnote.domain.Workspace
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.ResetCommand
import org.eclipse.jgit.lib.Constants
import org.eclipse.jgit.lib.ObjectId
import org.eclipse.jgit.lib.ProgressMonitor
import org.eclipse.jgit.revwalk.RevWalk
import org.eclipse.jgit.transport.CredentialsProvider
import org.eclipse.jgit.transport.PushResult
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import org.eclipse.jgit.transport.URIish
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class GitEngine {
    fun clone(
        address: RepositoryAddress,
        destination: File,
        token: String?,
    ): Workspace {
        if (destination.exists()) destination.deleteRecursively()
        destination.parentFile?.mkdirs()
        validateRemote(address.cloneUrl, address)
        try {
            val command = Git.cloneRepository()
                .setURI(address.cloneUrl)
                .setDirectory(destination)
                .setTimeout(NETWORK_TIMEOUT_SECONDS)
                .setProgressMonitor(BoundedProgressMonitor())
            credentials(token)?.let(command::setCredentialsProvider)
            command.call().use { git ->
                enforceWorkspaceBudget(destination)
                val branch = git.repository.branch ?: "main"
                return Workspace(
                    id = address.workspaceId,
                    owner = address.owner,
                    repository = address.repository,
                    directory = destination,
                    defaultBranch = branch,
                    isDirty = false,
                )
            }
        } catch (error: Exception) {
            destination.deleteRecursively()
            throw GitNoteException(humanMessage("Clone failed", error), error)
        }
    }

    fun isDirty(workspace: Workspace): Boolean = withGit(workspace) { git ->
        !git.status().call().isClean || hasUnpublishedCommits(git)
    }

    fun changes(workspace: Workspace): List<FileChange> = withGit(workspace) { git ->
        val status = git.status().call()
        buildList {
            status.added.forEach { add(FileChange(it, ChangeKind.ADDED)) }
            status.changed.forEach { add(FileChange(it, ChangeKind.MODIFIED)) }
            status.modified.forEach { add(FileChange(it, ChangeKind.MODIFIED)) }
            status.missing.forEach { add(FileChange(it, ChangeKind.DELETED)) }
            status.removed.forEach { add(FileChange(it, ChangeKind.DELETED)) }
            status.untracked.forEach { add(FileChange(it, ChangeKind.UNTRACKED)) }
            status.conflicting.forEach { add(FileChange(it, ChangeKind.CONFLICTING)) }
        }.distinctBy { it.relativePath }.sortedBy { it.relativePath.lowercase() }
    }

    fun sync(
        workspace: Workspace,
        token: String?,
        message: String,
        authorName: String,
        authorEmail: String,
    ): SyncResult = withGit(workspace) { git ->
        val repository = git.repository
        val remoteUrl = repository.config.getString("remote", "origin", "url")
            ?: throw GitNoteException("This working copy has no origin remote.")
        val pushUrl = repository.config.getString("remote", "origin", "pushurl") ?: remoteUrl
        validateRemote(remoteUrl, workspace.address)
        validateRemote(pushUrl, workspace.address)

        val provider = credentials(token)
        val fetch = git.fetch()
            .setRemote("origin")
            .setRemoveDeletedRefs(true)
            .setTimeout(NETWORK_TIMEOUT_SECONDS)
            .setProgressMonitor(BoundedProgressMonitor())
        provider?.let(fetch::setCredentialsProvider)
        fetch.call()

        val branch = repository.branch ?: workspace.defaultBranch
        val localId = repository.resolve(Constants.HEAD)
            ?: throw GitNoteException("The local branch has no commit.")
        val remoteId = repository.resolve("refs/remotes/origin/$branch")
            ?: throw GitNoteException("GitHub no longer exposes branch $branch.")
        val statusBefore = git.status().call()

        val relationship = Pair(
            isAncestor(repository, localId, remoteId),
            isAncestor(repository, remoteId, localId),
        )
        val localBehind = relationship.first && !relationship.second
        val localAhead = relationship.second && !relationship.first
        val diverged = !relationship.first && !relationship.second

        if (diverged) {
            throw GitNoteException("Local and GitHub history have diverged. Reconcile them in another Git client before syncing.")
        }
        if (localBehind) {
            if (!statusBefore.isClean) {
                throw GitNoteException("GitHub has newer commits and this copy has local changes. Commit or reconcile them in another Git client.")
            }
            git.reset().setMode(ResetCommand.ResetType.HARD).setRef(remoteId.name).call()
            enforceWorkspaceBudget(workspace.directory)
            return@withGit SyncResult("Downloaded the latest changes from GitHub.", downloaded = true)
        }

        var committed = false
        if (!statusBefore.isClean) {
            if (message.isBlank()) throw GitNoteException("Enter a commit message before uploading changes.")
            if (authorName.isBlank() || authorEmail.isBlank()) {
                throw GitNoteException("Enter your name and email before uploading changes.")
            }
            git.add().addFilepattern(".").call()
            git.add().setUpdate(true).addFilepattern(".").call()
            git.commit()
                .setMessage(message.trim())
                .setAuthor(authorName.trim(), authorEmail.trim())
                .setCommitter(authorName.trim(), authorEmail.trim())
                .call()
            committed = true
        }

        if (committed || localAhead) {
            val push = git.push()
                .setRemote("origin")
                .setTimeout(NETWORK_TIMEOUT_SECONDS)
                .setProgressMonitor(BoundedProgressMonitor())
            provider?.let(push::setCredentialsProvider)
            val results = push.call().toList()
            ensurePushSucceeded(results)
            return@withGit SyncResult("Uploaded changes to GitHub.", uploaded = true)
        }
        SyncResult("Already up to date.")
    }

    fun list(workspace: Workspace, folder: String = "", query: String = ""): List<MarkdownEntry> {
        val root = workspaceRoot(workspace)
        if (query.isNotBlank()) {
            return Files.walk(root).use { paths ->
                paths.filter { path ->
                    path != root && safeVisiblePath(root, path) &&
                        (Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || isMarkdown(path.fileName.toString()))
                }.map { path ->
                    val relative = normalize(root.relativize(path))
                    MarkdownEntry(relative, path.fileName.toString(), Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS))
                }.filter { it.name.contains(query, ignoreCase = true) }
                    .sorted(compareByDescending<MarkdownEntry> { it.isDirectory }.thenBy { it.relativePath.lowercase() })
                    .toList()
            }
        }

        val directory = resolve(workspace, folder, allowDirectory = true, mustExist = true)
        return Files.list(directory).use { paths ->
            paths.filter(::notHiddenOrGit)
                .filter { !Files.isSymbolicLink(it) }
                .filter { Files.isDirectory(it, LinkOption.NOFOLLOW_LINKS) || isMarkdown(it.fileName.toString()) }
                .map { path ->
                    val relative = normalize(root.relativize(path))
                    MarkdownEntry(relative, path.fileName.toString(), Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS))
                }
                .sorted(compareByDescending<MarkdownEntry> { it.isDirectory }.thenBy { it.name.lowercase() })
                .toList()
        }
    }

    fun read(workspace: Workspace, relativePath: String): String {
        val path = resolve(workspace, relativePath, allowDirectory = false, mustExist = true)
        if (!isMarkdown(path.fileName.toString())) throw GitNoteException("Only Markdown files can be opened.")
        if (Files.size(path) > MAX_NOTE_BYTES) throw GitNoteException("This note is larger than 2 MB.")
        return Files.newBufferedReader(path, Charsets.UTF_8).use { it.readText() }
    }

    fun save(workspace: Workspace, relativePath: String, markdown: String) {
        val bytes = markdown.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_NOTE_BYTES) throw GitNoteException("Notes are limited to 2 MB.")
        val path = resolve(workspace, relativePath, allowDirectory = false, mustExist = false)
        if (!isMarkdown(path.fileName.toString())) throw GitNoteException("Only Markdown files can be saved.")
        path.parent?.let(Files::createDirectories)
        val temporary = path.resolveSibling(".${path.fileName}.gitnote-tmp")
        Files.write(temporary, bytes)
        try {
            Files.move(
                temporary,
                path,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: Exception) {
            Files.move(temporary, path, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
    }

    fun createFolder(workspace: Workspace, relativePath: String) {
        val path = resolve(workspace, relativePath, allowDirectory = true, mustExist = false)
        Files.createDirectories(path)
    }

    fun createNote(workspace: Workspace, relativePath: String): String {
        val normalized = if (relativePath.endsWith(".md", true) || relativePath.endsWith(".markdown", true)) {
            relativePath
        } else {
            "$relativePath.md"
        }
        val path = resolve(workspace, normalized, allowDirectory = false, mustExist = false)
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) throw GitNoteException("A file already exists at that path.")
        save(workspace, normalized, "")
        return normalized.replace('\\', '/')
    }

    fun exportArchive(workspace: Workspace, destination: File) {
        val root = workspaceRoot(workspace)
        ZipOutputStream(destination.outputStream().buffered()).use { zip ->
            Files.walk(root).use { paths ->
                paths.filter { it != root && safeVisiblePath(root, it) && Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }
                    .forEach { path ->
                        val name = normalize(root.relativize(path))
                        zip.putNextEntry(ZipEntry(name))
                        Files.newInputStream(path).use { it.copyTo(zip) }
                        zip.closeEntry()
                    }
            }
        }
    }

    private fun <T> withGit(workspace: Workspace, action: (Git) -> T): T {
        try {
            return Git.open(workspace.directory).use(action)
        } catch (error: GitNoteException) {
            throw error
        } catch (error: Exception) {
            throw GitNoteException(humanMessage("Git operation failed", error), error)
        }
    }

    private fun credentials(token: String?): CredentialsProvider? = token?.takeIf { it.isNotBlank() }
        ?.let { UsernamePasswordCredentialsProvider("x-access-token", it) }

    private fun validateRemote(rawUrl: String, expected: RepositoryAddress) {
        val uri = runCatching { URIish(rawUrl) }.getOrElse { throw GitNoteException("The Git remote URL is invalid.") }
        val expectedPath = "/${expected.owner}/${expected.repository}.git"
        val actualPath = "/${uri.path.orEmpty().trimStart('/').removeSuffix(".git")}.git"
        if (uri.scheme != "https" || !uri.host.equals("github.com", true) ||
            (uri.port != -1 && uri.port != 443) || uri.user != null || uri.pass != null ||
            !actualPath.equals(expectedPath, true)
        ) {
            throw GitNoteException("Refusing to send credentials to an unexpected Git remote.")
        }
    }

    private fun ensurePushSucceeded(results: List<PushResult>) {
        if (results.isEmpty()) throw GitNoteException("GitHub did not return a push result.")
        val failed = results.flatMap { it.remoteUpdates }.firstOrNull { update ->
            update.status.name !in setOf("OK", "UP_TO_DATE")
        }
        if (failed != null) throw GitNoteException(failed.message ?: "GitHub rejected the push (${failed.status}).")
    }

    private fun hasUnpublishedCommits(git: Git): Boolean {
        val repository = git.repository
        val branch = repository.branch ?: return false
        val local = repository.resolve(Constants.HEAD) ?: return false
        val remote = repository.resolve("refs/remotes/origin/$branch") ?: return false
        return !isAncestor(repository, local, remote)
    }

    private fun isAncestor(repository: org.eclipse.jgit.lib.Repository, ancestor: ObjectId, tip: ObjectId): Boolean =
        RevWalk(repository).use { walk ->
            walk.isMergedInto(walk.parseCommit(ancestor), walk.parseCommit(tip))
        }

    private fun workspaceRoot(workspace: Workspace): Path {
        val root = workspace.directory.toPath().toRealPath(LinkOption.NOFOLLOW_LINKS)
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root)) {
            throw GitNoteException("The working-copy directory is unavailable.")
        }
        return root
    }

    private fun resolve(
        workspace: Workspace,
        relativePath: String,
        allowDirectory: Boolean,
        mustExist: Boolean,
    ): Path {
        val root = workspaceRoot(workspace)
        val components = validatedComponents(relativePath)
        var current = root
        components.forEach { component ->
            current = current.resolve(component)
            if (Files.exists(current, LinkOption.NOFOLLOW_LINKS) && Files.isSymbolicLink(current)) {
                throw GitNoteException("Symbolic links cannot be opened by GitNote.")
            }
        }
        val normalized = current.normalize()
        if (!normalized.startsWith(root)) throw GitNoteException("The path escapes this working copy.")
        if (mustExist && !Files.exists(normalized, LinkOption.NOFOLLOW_LINKS)) {
            throw GitNoteException("The file no longer exists.")
        }
        if (Files.exists(normalized, LinkOption.NOFOLLOW_LINKS)) {
            val isDirectory = Files.isDirectory(normalized, LinkOption.NOFOLLOW_LINKS)
            if (allowDirectory != isDirectory) throw GitNoteException("The selected path has the wrong type.")
        }
        return normalized
    }

    private fun validatedComponents(relativePath: String): List<String> {
        if (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
            throw GitNoteException("Use a path inside the working copy.")
        }
        if (relativePath.isBlank()) return emptyList()
        val values = relativePath.replace('\\', '/').split('/')
        if (values.any { value ->
                value.isBlank() || value == "." || value == ".." || value.startsWith('.') ||
                    value.any { it.code < 32 } || value.contains(':')
            }
        ) {
            throw GitNoteException("The path contains an unsupported component.")
        }
        return values
    }

    private fun safeVisiblePath(root: Path, path: Path): Boolean {
        val relative = root.relativize(path)
        return !Files.isSymbolicLink(path) && relative.none { component -> component.toString().startsWith('.') }
    }

    private fun notHiddenOrGit(path: Path): Boolean = !path.fileName.toString().startsWith('.')
    private fun isMarkdown(name: String): Boolean = name.endsWith(".md", true) || name.endsWith(".markdown", true)
    private fun normalize(path: Path): String = path.joinToString("/") { it.toString() }

    private fun enforceWorkspaceBudget(root: File) {
        var files = 0
        var bytes = 0L
        Files.walk(root.toPath()).use { paths ->
            paths.filter { path ->
                !path.toString().contains("${File.separator}.git${File.separator}") &&
                    Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)
            }.forEach { path ->
                files += 1
                val size = Files.size(path)
                bytes += size
                if (files > MAX_FILES || size > MAX_FILE_BYTES || bytes > MAX_CHECKOUT_BYTES) {
                    throw GitNoteException("This repository exceeds GitNote's safety limits.")
                }
            }
        }
    }

    private fun humanMessage(prefix: String, error: Throwable): String {
        val detail = generateSequence(error) { it.cause }.mapNotNull { it.message }.firstOrNull { it.isNotBlank() }
        return if (detail == null) prefix else "$prefix: $detail"
    }

    private class BoundedProgressMonitor : ProgressMonitor {
        private val cancelled = AtomicBoolean(false)
        private val startedAt = System.nanoTime()
        private var completed = 0L

        override fun start(totalTasks: Int) = Unit
        override fun beginTask(title: String?, totalWork: Int) = Unit
        override fun update(completed: Int) {
            this.completed += completed
            if (this.completed > MAX_PROGRESS_UNITS || elapsedSeconds() > NETWORK_TIMEOUT_SECONDS) cancelled.set(true)
        }
        override fun endTask() = Unit
        override fun isCancelled(): Boolean = cancelled.get() || elapsedSeconds() > NETWORK_TIMEOUT_SECONDS
        override fun showDuration(enabled: Boolean) = Unit
        private fun elapsedSeconds(): Long = (System.nanoTime() - startedAt) / 1_000_000_000
    }

    companion object {
        private const val NETWORK_TIMEOUT_SECONDS = 120
        private const val MAX_NOTE_BYTES = 2L * 1024 * 1024
        private const val MAX_FILE_BYTES = 20L * 1024 * 1024
        private const val MAX_CHECKOUT_BYTES = 100L * 1024 * 1024
        private const val MAX_FILES = 10_000
        private const val MAX_PROGRESS_UNITS = 20_000_000L
    }
}
