package com.henrikvindshoj.gitnote

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrikvindshoj.gitnote.data.GitEngine
import com.henrikvindshoj.gitnote.data.TokenStore
import com.henrikvindshoj.gitnote.domain.RepositoryAddress
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class GitNoteDeviceTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    private val context get() = ApplicationProvider.getApplicationContext<android.content.Context>()

    @After
    fun cleanCredentials() {
        TokenStore(context).clear()
    }

    @Test
    fun launchesWorkingCopyHome() {
        composeRule.onNodeWithText("GitNote").assertIsDisplayed()
        composeRule.onNodeWithText("Working copies").assertIsDisplayed()
    }

    @Test
    fun tokenRoundTripsThroughAndroidKeystore() {
        val store = TokenStore(context)
        store.clear()
        store.save("github_pat_test-value")
        assertEquals("github_pat_test-value", store.read())
        store.clear()
        assertEquals(null, store.read())
    }

    @Test
    fun clonesPublicRepositoryAndDetectsMarkdownChange() {
        val address = RepositoryAddress("henrikvindshoj", "GitNote-Test-Repo")
        val destination = File(context.cacheDir, "android-integration-clone")
        destination.deleteRecursively()
        try {
            val engine = GitEngine()
            val workspace = engine.clone(address, destination, null)
            assertTrue(File(destination, ".git").isDirectory)
            assertTrue(engine.list(workspace, query = "").any { !it.isDirectory })
            assertEquals("Already up to date.", engine.sync(workspace, null, "", "", "").message)

            val created = engine.createNote(workspace, "Android/Emulator-test")
            engine.save(workspace, created, "# Android emulator\n\nGitNote is working.")
            assertTrue(engine.isDirty(workspace))
            assertTrue(engine.changes(workspace).any { it.relativePath == "Android/Emulator-test.md" })
        } finally {
            destination.deleteRecursively()
        }
    }
}
