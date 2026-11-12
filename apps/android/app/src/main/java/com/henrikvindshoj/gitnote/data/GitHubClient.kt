package com.henrikvindshoj.gitnote.data

import com.henrikvindshoj.gitnote.domain.GitHubAccount
import com.henrikvindshoj.gitnote.domain.GitHubRepository
import com.henrikvindshoj.gitnote.domain.GitNoteException
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

class GitHubClient {
    fun account(token: String): GitHubAccount {
        val json = JSONObject(request("/user", token))
        return GitHubAccount(json.getString("login"), json.optString("avatar_url").ifBlank { null })
    }

    fun repositories(token: String): List<GitHubRepository> {
        val result = mutableListOf<GitHubRepository>()
        var page = 1
        while (page <= 10) {
            val values = JSONArray(
                request(
                    "/user/repos?per_page=100&page=$page&sort=updated&affiliation=owner,collaborator,organization_member",
                    token,
                ),
            )
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val owner = value.getJSONObject("owner").getString("login")
                result += GitHubRepository(
                    owner = owner,
                    name = value.getString("name"),
                    isPrivate = value.getBoolean("private"),
                    defaultBranch = value.optString("default_branch", "main"),
                )
            }
            if (values.length() < 100) break
            page += 1
        }
        return result
    }

    private fun request(path: String, token: String): String {
        val uri = URI("https", "api.github.com", path.substringBefore('?'), path.substringAfter('?', "").ifBlank { null }, null)
        require(uri.host == "api.github.com" && uri.scheme == "https")
        val connection = (URL(uri.toASCIIString()).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = false
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            setRequestProperty("User-Agent", "GitNote-Android/0.1")
        }
        return try {
            val body = (if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (connection.responseCode !in 200..299) {
                val detail = runCatching { JSONObject(body).optString("message") }.getOrNull()
                throw GitNoteException(detail?.ifBlank { null } ?: "GitHub returned ${connection.responseCode}")
            }
            body
        } finally {
            connection.disconnect()
        }
    }
}
