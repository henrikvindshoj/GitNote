package com.henrikvindshoj.gitnote

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.henrikvindshoj.gitnote.data.GitEngine
import com.henrikvindshoj.gitnote.data.GitHubClient
import com.henrikvindshoj.gitnote.data.GitHubOAuthClient
import com.henrikvindshoj.gitnote.data.TokenStore
import com.henrikvindshoj.gitnote.data.WorkspaceStore
import com.henrikvindshoj.gitnote.domain.FileChange
import com.henrikvindshoj.gitnote.domain.GitHubAccount
import com.henrikvindshoj.gitnote.domain.GitHubDeviceAuthorization
import com.henrikvindshoj.gitnote.domain.GitHubOAuthPollResult
import com.henrikvindshoj.gitnote.domain.GitHubRepository
import com.henrikvindshoj.gitnote.domain.GitNoteException
import com.henrikvindshoj.gitnote.domain.MarkdownEntry
import com.henrikvindshoj.gitnote.domain.RepositoryAddress
import com.henrikvindshoj.gitnote.domain.Workspace
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

data class AppState(
    val workspaces: List<Workspace> = emptyList(),
    val account: GitHubAccount? = null,
    val githubDeviceAuthorization: GitHubDeviceAuthorization? = null,
    val githubSignInInProgress: Boolean = false,
    val availableRepositories: List<GitHubRepository> = emptyList(),
    val selectedWorkspace: Workspace? = null,
    val folder: String = "",
    val entries: List<MarkdownEntry> = emptyList(),
    val changes: List<FileChange> = emptyList(),
    val busyMessage: String? = null,
    val notice: String? = null,
    val error: String? = null,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val tokenStore = TokenStore(application)
    private val workspaceStore = WorkspaceStore(application)
    private val gitHub = GitHubClient()
    private val gitHubOAuth = GitHubOAuthClient()
    private val git = GitEngine()
    private var githubSignInJob: Job? = null
    private val mutableState = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = mutableState.asStateFlow()

    init {
        refreshAll()
        tokenStore.read()?.let { token ->
            launchOperation("Connecting to GitHub…", preserveNotice = true) {
                val account = gitHub.account(token)
                mutableState.update { it.copy(account = account) }
            }
        }
    }

    fun refreshAll() {
        launchOperation(null, preserveNotice = true) {
            val workspaces = workspaceStore.load().map { workspace ->
                workspace.copy(isDirty = runCatching { git.isDirty(workspace) }.getOrDefault(false))
            }
            mutableState.update { current ->
                current.copy(
                    workspaces = workspaces,
                    selectedWorkspace = current.selectedWorkspace?.let { selected ->
                        workspaces.firstOrNull { it.id == selected.id }
                    },
                )
            }
        }
    }

    fun connect(token: String) {
        cancelGitHubSignIn(showNotice = false)
        launchOperation("Validating GitHub account…") {
            val cleanToken = token.trim()
            if (cleanToken.isEmpty()) throw GitNoteException("Paste a fine-grained GitHub token first.")
            val account = gitHub.account(cleanToken)
            tokenStore.save(cleanToken)
            mutableState.update { it.copy(account = account, notice = "Connected as ${account.login}.") }
        }
    }

    fun disconnect() {
        cancelGitHubSignIn(showNotice = false)
        tokenStore.clear()
        mutableState.update { it.copy(account = null, availableRepositories = emptyList(), notice = "GitHub account disconnected.") }
    }

    fun startGitHubSignIn() {
        if (githubSignInJob?.isActive == true) return
        githubSignInJob = viewModelScope.launch {
            mutableState.update {
                it.copy(
                    githubSignInInProgress = true,
                    githubDeviceAuthorization = null,
                    error = null,
                    notice = null,
                )
            }
            try {
                val clientId = BuildConfig.GITHUB_OAUTH_CLIENT_ID.trim()
                if (clientId.isEmpty()) throw GitNoteException("GitHub login is not configured.")
                val authorization = withContext(Dispatchers.IO) { gitHubOAuth.begin(clientId) }
                mutableState.update { it.copy(githubDeviceAuthorization = authorization) }

                val expiresAt = System.currentTimeMillis() + authorization.expiresInSeconds * 1_000
                var intervalSeconds = authorization.intervalSeconds
                while (System.currentTimeMillis() < expiresAt) {
                    delay(intervalSeconds * 1_000)
                    when (val result = withContext(Dispatchers.IO) {
                        gitHubOAuth.poll(clientId, authorization.deviceCode)
                    }) {
                        GitHubOAuthPollResult.Pending -> Unit
                        GitHubOAuthPollResult.SlowDown -> intervalSeconds += 5
                        is GitHubOAuthPollResult.Authorized -> {
                            val account = withContext(Dispatchers.IO) { gitHub.account(result.token) }
                            tokenStore.save(result.token)
                            mutableState.update {
                                it.copy(
                                    account = account,
                                    githubDeviceAuthorization = null,
                                    githubSignInInProgress = false,
                                    notice = "Connected as ${account.login}.",
                                )
                            }
                            return@launch
                        }
                    }
                }
                throw GitNoteException("The GitHub login code expired. Start again.")
            } catch (_: CancellationException) {
                // Cancellation is an expected result of the user closing the login flow.
            } catch (error: Exception) {
                mutableState.update { it.copy(error = error.message ?: "GitHub login failed.") }
            } finally {
                mutableState.update {
                    it.copy(githubDeviceAuthorization = null, githubSignInInProgress = false)
                }
            }
        }
    }

    fun cancelGitHubSignIn(showNotice: Boolean = true) {
        val wasActive = githubSignInJob?.isActive == true
        githubSignInJob?.cancel()
        githubSignInJob = null
        mutableState.update {
            it.copy(
                githubDeviceAuthorization = null,
                githubSignInInProgress = false,
                notice = if (showNotice && wasActive) "GitHub login cancelled." else it.notice,
            )
        }
    }

    fun loadRepositories() {
        launchOperation("Loading repositories…") {
            val token = requireToken()
            val repositories = gitHub.repositories(token)
            mutableState.update { it.copy(availableRepositories = repositories) }
        }
    }

    fun clone(rawAddress: String, onComplete: (() -> Unit)? = null) {
        launchOperation("Cloning repository…") {
            val address = RepositoryAddress.parse(rawAddress)
                ?: throw GitNoteException("Enter a repository as owner/name or a GitHub HTTPS URL.")
            if (mutableState.value.workspaces.any { it.id == address.workspaceId }) {
                throw GitNoteException("That repository already has a working copy.")
            }
            val workspace = git.clone(address, workspaceStore.directory(address.workspaceId), tokenStore.read())
            val workspaces = mutableState.value.workspaces + workspace
            workspaceStore.save(workspaces)
            mutableState.update { it.copy(workspaces = workspaces, notice = "Cloned ${workspace.slug}.") }
            withContext(Dispatchers.Main) { onComplete?.invoke() }
        }
    }

    fun openWorkspace(workspace: Workspace, folder: String = "") {
        launchOperation(null, preserveNotice = true) {
            val refreshed = workspace.copy(isDirty = git.isDirty(workspace))
            val entries = git.list(refreshed, folder)
            val changes = git.changes(refreshed)
            mutableState.update { state ->
                state.copy(
                    selectedWorkspace = refreshed,
                    folder = folder,
                    entries = entries,
                    changes = changes,
                    workspaces = state.workspaces.map { if (it.id == refreshed.id) refreshed else it },
                )
            }
        }
    }

    fun search(query: String) {
        val workspace = mutableState.value.selectedWorkspace ?: return
        launchOperation(null, preserveNotice = true) {
            val entries = git.list(workspace, mutableState.value.folder, query)
            mutableState.update { it.copy(entries = entries) }
        }
    }

    suspend fun read(relativePath: String): String = withContext(Dispatchers.IO) {
        val workspace = mutableState.value.selectedWorkspace ?: throw GitNoteException("No working copy is open.")
        git.read(workspace, relativePath)
    }

    fun save(relativePath: String, markdown: String, onComplete: (() -> Unit)? = null) {
        val workspace = mutableState.value.selectedWorkspace ?: return
        launchOperation("Saving note…") {
            git.save(workspace, relativePath, markdown)
            refreshWorkspaceData(workspace)
            mutableState.update { it.copy(notice = "Saved ${relativePath.substringAfterLast('/')}.") }
            withContext(Dispatchers.Main) { onComplete?.invoke() }
        }
    }

    fun createNote(relativePath: String, onCreated: (String) -> Unit) {
        val workspace = mutableState.value.selectedWorkspace ?: return
        launchOperation("Creating note…") {
            val path = combineFolder(mutableState.value.folder, relativePath)
            val created = git.createNote(workspace, path)
            refreshWorkspaceData(workspace)
            withContext(Dispatchers.Main) { onCreated(created) }
        }
    }

    fun createFolder(relativePath: String) {
        val workspace = mutableState.value.selectedWorkspace ?: return
        launchOperation("Creating folder…") {
            git.createFolder(workspace, combineFolder(mutableState.value.folder, relativePath))
            refreshWorkspaceData(workspace)
            mutableState.update { it.copy(notice = "Folder created.") }
        }
    }

    fun sync(message: String, authorName: String, authorEmail: String) {
        val workspace = mutableState.value.selectedWorkspace ?: return
        launchOperation("Synchronizing with GitHub…") {
            val result = git.sync(workspace, tokenStore.read(), message, authorName, authorEmail)
            refreshWorkspaceData(workspace)
            mutableState.update { it.copy(notice = result.message) }
        }
    }

    fun removeWorkspace(workspace: Workspace, onComplete: (() -> Unit)? = null) {
        launchOperation("Removing local copy…") {
            workspaceStore.remove(workspace)
            val workspaces = mutableState.value.workspaces.filterNot { it.id == workspace.id }
            workspaceStore.save(workspaces)
            mutableState.update {
                it.copy(
                    workspaces = workspaces,
                    selectedWorkspace = if (it.selectedWorkspace?.id == workspace.id) null else it.selectedWorkspace,
                    notice = "Removed the local copy. The GitHub repository was not changed.",
                )
            }
            withContext(Dispatchers.Main) { onComplete?.invoke() }
        }
    }

    suspend fun createExportArchive(): File = withContext(Dispatchers.IO) {
        val workspace = mutableState.value.selectedWorkspace ?: throw GitNoteException("No working copy is open.")
        val file = File(getApplication<Application>().cacheDir, "${workspace.name}.zip")
        git.exportArchive(workspace, file)
        file
    }

    fun clearMessages() {
        mutableState.update { it.copy(error = null, notice = null) }
    }

    private suspend fun refreshWorkspaceData(workspace: Workspace) {
        val refreshed = workspace.copy(isDirty = git.isDirty(workspace))
        val entries = git.list(refreshed, mutableState.value.folder)
        val changes = git.changes(refreshed)
        val workspaces = mutableState.value.workspaces.map { if (it.id == workspace.id) refreshed else it }
        workspaceStore.save(workspaces)
        mutableState.update {
            it.copy(workspaces = workspaces, selectedWorkspace = refreshed, entries = entries, changes = changes)
        }
    }

    private fun requireToken(): String = tokenStore.read()
        ?: throw GitNoteException("Connect a fine-grained GitHub token first.")

    private fun combineFolder(folder: String, child: String): String =
        if (folder.isBlank()) child else "$folder/$child"

    private fun launchOperation(
        busyMessage: String?,
        preserveNotice: Boolean = false,
        operation: suspend () -> Unit,
    ) {
        viewModelScope.launch {
            mutableState.update {
                it.copy(
                    busyMessage = busyMessage,
                    error = null,
                    notice = if (preserveNotice) it.notice else null,
                )
            }
            try {
                withContext(Dispatchers.IO) { operation() }
            } catch (error: Exception) {
                mutableState.update { it.copy(error = error.message ?: "The operation failed.") }
            } finally {
                mutableState.update { it.copy(busyMessage = null) }
            }
        }
    }
}
