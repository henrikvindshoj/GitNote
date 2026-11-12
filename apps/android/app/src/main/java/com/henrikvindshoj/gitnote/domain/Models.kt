package com.henrikvindshoj.gitnote.domain

import java.io.File

data class RepositoryAddress(
    val owner: String,
    val repository: String,
) {
    val slug: String = "$owner/$repository"
    val cloneUrl: String = "https://github.com/$owner/$repository.git"
    val workspaceId: String = "${owner.lowercase()}--${repository.lowercase()}"

    companion object {
        private val component = Regex("^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$")

        fun parse(raw: String): RepositoryAddress? {
            var value = raw.trim().removeSuffix("/").removeSuffix(".git")
            if (value.startsWith("https://github.com/", ignoreCase = true)) {
                value = value.substringAfter("https://github.com/")
            }
            val parts = value.split('/')
            if (parts.size != 2) return null
            val owner = parts[0]
            val repository = parts[1]
            if (!component.matches(owner) || !component.matches(repository)) return null
            if (owner == "." || owner == ".." || repository == "." || repository == "..") return null
            return RepositoryAddress(owner, repository)
        }
    }
}

data class Workspace(
    val id: String,
    val owner: String,
    val repository: String,
    val directory: File,
    val defaultBranch: String,
    val isDirty: Boolean = false,
) {
    val name: String get() = repository
    val slug: String get() = "$owner/$repository"
    val address: RepositoryAddress get() = RepositoryAddress(owner, repository)
}

data class MarkdownEntry(
    val relativePath: String,
    val name: String,
    val isDirectory: Boolean,
)

enum class ChangeKind { ADDED, MODIFIED, DELETED, RENAMED, UNTRACKED, CONFLICTING }

data class FileChange(
    val relativePath: String,
    val kind: ChangeKind,
)

data class GitHubAccount(
    val login: String,
    val avatarUrl: String?,
)

data class GitHubDeviceAuthorization(
    val deviceCode: String,
    val userCode: String,
    val verificationUri: String,
    val expiresInSeconds: Long,
    val intervalSeconds: Long,
)

sealed interface GitHubOAuthPollResult {
    data object Pending : GitHubOAuthPollResult
    data object SlowDown : GitHubOAuthPollResult
    data class Authorized(val token: String) : GitHubOAuthPollResult
}

data class GitHubRepository(
    val owner: String,
    val name: String,
    val isPrivate: Boolean,
    val defaultBranch: String,
) {
    val slug: String get() = "$owner/$name"
}

data class SyncResult(
    val message: String,
    val downloaded: Boolean = false,
    val uploaded: Boolean = false,
)

class GitNoteException(message: String, cause: Throwable? = null) : Exception(message, cause)
