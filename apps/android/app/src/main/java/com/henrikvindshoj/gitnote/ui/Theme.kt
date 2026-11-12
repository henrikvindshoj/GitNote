package com.henrikvindshoj.gitnote.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF5B4FE9),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE5E1FF),
    onPrimaryContainer = Color(0xFF21145F),
    background = Color(0xFFF8F8FC),
    surface = Color(0xFFFFFFFF),
    surfaceVariant = Color(0xFFF0EFF7),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFC7BFFF),
    primaryContainer = Color(0xFF4335C8),
)

@Composable
fun GitNoteTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        content = content,
    )
}
