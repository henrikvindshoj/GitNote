package com.henrikvindshoj.gitnote

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.henrikvindshoj.gitnote.ui.GitNoteApp
import com.henrikvindshoj.gitnote.ui.GitNoteTheme

class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            GitNoteTheme {
                GitNoteApp(viewModel)
            }
        }
    }
}
