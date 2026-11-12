package com.henrikvindshoj.gitnote

import com.henrikvindshoj.gitnote.data.GitEngine
import com.henrikvindshoj.gitnote.domain.GitNoteException
import com.henrikvindshoj.gitnote.domain.Workspace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.eclipse.jgit.api.Git
import java.nio.file.Files

class GitEngineFileTest {
    private val engine = GitEngine()

    @Test
    fun createsReadsAndListsNestedMarkdown() {
        val root = Files.createTempDirectory("gitnote-files").toFile()
        try {
            val workspace = Workspace("owner--repo", "owner", "repo", root, "main")
            val path = engine.createNote(workspace, "Notes/Plan")
            engine.save(workspace, path, "# Plan\n\nHello")

            assertEquals("Notes/Plan.md", path)
            assertEquals("# Plan\n\nHello", engine.read(workspace, path))
            assertTrue(engine.list(workspace).any { it.isDirectory && it.name == "Notes" })
            assertTrue(engine.list(workspace, "Notes").any { !it.isDirectory && it.name == "Plan.md" })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rejectsTraversalHiddenPathsAndSymlinks() {
        val parent = Files.createTempDirectory("gitnote-containment")
        val root = Files.createDirectory(parent.resolve("repo")).toFile()
        val outside = Files.createDirectory(parent.resolve("outside"))
        val workspace = Workspace("owner--repo", "owner", "repo", root, "main")
        try {
            assertThrowsGitNote { engine.createNote(workspace, "../outside/secret.md") }
            assertThrowsGitNote { engine.createNote(workspace, ".git/config.md") }

            runCatching { Files.createSymbolicLink(root.toPath().resolve("linked"), outside) }
                .onSuccess { assertThrowsGitNote { engine.createNote(workspace, "linked/secret.md") } }
        } finally {
            parent.toFile().deleteRecursively()
        }
    }

    @Test
    fun cleanCommitAheadOfGitHubStillShowsAsDirty() {
        val root = Files.createTempDirectory("gitnote-ahead").toFile()
        try {
            Git.init().setDirectory(root).call().use { git ->
                val branch = git.repository.branch
                root.resolve("note.md").writeText("first")
                git.add().addFilepattern(".").call()
                val published = git.commit().setMessage("First").setAuthor("GitNote", "gitnote@example.com").call()
                git.repository.updateRef("refs/remotes/origin/$branch").apply {
                    setNewObjectId(published.id)
                    forceUpdate()
                }
                val workspace = Workspace("owner--repo", "owner", "repo", root, branch)
                assertFalse(engine.isDirty(workspace))

                root.resolve("note.md").writeText("second")
                git.add().addFilepattern(".").call()
                git.commit().setMessage("Second").setAuthor("GitNote", "gitnote@example.com").call()
                assertTrue(engine.isDirty(workspace))
            }
        } finally {
            root.deleteRecursively()
        }
    }

    private fun assertThrowsGitNote(block: () -> Unit) {
        var thrown = false
        try {
            block()
        } catch (_: GitNoteException) {
            thrown = true
        }
        assertTrue("Expected GitNoteException", thrown)
    }
}
