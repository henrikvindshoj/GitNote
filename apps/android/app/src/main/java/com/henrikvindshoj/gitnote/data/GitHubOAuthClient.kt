package com.henrikvindshoj.gitnote.data

import com.henrikvindshoj.gitnote.domain.GitHubDeviceAuthorization
import com.henrikvindshoj.gitnote.domain.GitHubOAuthPollResult
import com.henrikvindshoj.gitnote.domain.GitNoteException
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

class GitHubOAuthClient {
    fun begin(clientId: String): GitHubDeviceAuthorization {
        val json = post(
            path = "/login/device/code",
            fields = mapOf("client_id" to clientId, "scope" to REQUESTED_SCOPE),
        )
        return GitHubDeviceAuthorization(
            deviceCode = json.required("device_code"),
            userCode = json.required("user_code"),
            verificationUri = json.required("verification_uri").also(::validateVerificationUri),
            expiresInSeconds = json.optLong("expires_in", 900).coerceAtLeast(1),
            intervalSeconds = json.optLong("interval", 5).coerceAtLeast(1),
        )
    }

    fun poll(clientId: String, deviceCode: String): GitHubOAuthPollResult {
        val json = post(
            path = "/login/oauth/access_token",
            fields = mapOf(
                "client_id" to clientId,
                "device_code" to deviceCode,
                "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
            ),
        )
        json.optString("access_token").takeIf(String::isNotBlank)?.let {
            return GitHubOAuthPollResult.Authorized(it)
        }
        return when (val error = json.optString("error")) {
            "authorization_pending" -> GitHubOAuthPollResult.Pending
            "slow_down" -> GitHubOAuthPollResult.SlowDown
            "expired_token" -> throw GitNoteException("The GitHub login code expired. Start again.")
            "access_denied" -> throw GitNoteException("GitHub login was cancelled or denied.")
            "device_flow_disabled" -> throw GitNoteException("Device Flow is not enabled for the GitNote OAuth App.")
            else -> throw GitNoteException(
                json.optString("error_description").ifBlank {
                    if (error.isBlank()) "GitHub returned an invalid OAuth response." else "GitHub login failed ($error)."
                },
            )
        }
    }

    private fun post(path: String, fields: Map<String, String>): JSONObject {
        val uri = URI("https", "github.com", path, null)
        check(uri.scheme == "https" && uri.host == "github.com")
        val body = fields.entries.sortedBy { it.key }.joinToString("&") { (key, value) ->
            "${encode(key)}=${encode(value)}"
        }.toByteArray(StandardCharsets.UTF_8)
        val connection = (uri.toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = false
            doOutput = true
            setFixedLengthStreamingMode(body.size)
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            setRequestProperty("User-Agent", "GitNote-Android/0.1")
        }
        return try {
            connection.outputStream.use { it.write(body) }
            val responseBody = (if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val json = runCatching { JSONObject(responseBody) }
                .getOrElse { throw GitNoteException("GitHub returned an invalid OAuth response.") }
            if (connection.responseCode !in 200..299) {
                throw GitNoteException(
                    json.optString("error_description").ifBlank {
                        json.optString("error").ifBlank { "GitHub login failed (${connection.responseCode})." }
                    },
                )
            }
            json
        } finally {
            connection.disconnect()
        }
    }

    private fun JSONObject.required(key: String): String = optString(key).takeIf(String::isNotBlank)
        ?: throw GitNoteException("GitHub returned an invalid OAuth response.")

    private fun validateVerificationUri(raw: String) {
        val uri = runCatching { URI(raw) }.getOrNull()
        if (uri?.scheme != "https" || uri.host != "github.com") {
            throw GitNoteException("GitHub returned an invalid verification address.")
        }
    }

    private fun encode(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8.toString())

    companion object {
        const val REQUESTED_SCOPE = "public_repo"
    }
}
