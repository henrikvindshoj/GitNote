package com.henrikvindshoj.gitnote.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddLink
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FormatBold
import androidx.compose.material.icons.filled.FormatItalic
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.henrikvindshoj.gitnote.AppState
import com.henrikvindshoj.gitnote.AppViewModel
import com.henrikvindshoj.gitnote.domain.ChangeKind
import com.henrikvindshoj.gitnote.domain.FileChange
import com.henrikvindshoj.gitnote.domain.MarkdownEntry
import com.henrikvindshoj.gitnote.domain.Workspace
import com.mohamedrejeb.richeditor.model.HeadingStyle
import com.mohamedrejeb.richeditor.model.rememberRichTextState
import com.mohamedrejeb.richeditor.ui.material3.OutlinedRichTextEditor
import kotlinx.coroutines.launch

private sealed interface Screen {
    data object Home : Screen
    data object Repository : Screen
    data class Editor(val path: String) : Screen
}

@Composable
fun GitNoteApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsState()
    // The selected workspace lives in the ViewModel. Keeping the matching route in
    // ordinary composition state prevents Android from restoring a repository/editor
    // screen after the process has lost that workspace selection.
    var screen: Screen by remember { mutableStateOf(Screen.Home) }
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(state.error, state.notice) {
        val message = state.error ?: state.notice
        if (message != null) {
            snackbar.showSnackbar(message)
            viewModel.clearMessages()
        }
    }

    Box(Modifier.fillMaxSize()) {
        when (val current = screen) {
            Screen.Home -> HomeScreen(
                state = state,
                snackbar = snackbar,
                onOpen = { workspace ->
                    viewModel.openWorkspace(workspace)
                    screen = Screen.Repository
                },
                onRefresh = viewModel::refreshAll,
                viewModel = viewModel,
            )
            Screen.Repository -> RepositoryScreen(
                state = state,
                snackbar = snackbar,
                viewModel = viewModel,
                onBack = { screen = Screen.Home },
                onOpenNote = { screen = Screen.Editor(it) },
            )
            is Screen.Editor -> EditorScreen(
                path = current.path,
                viewModel = viewModel,
                onBack = {
                    state.selectedWorkspace?.let(viewModel::openWorkspace)
                    screen = Screen.Repository
                },
            )
        }

        if (state.busyMessage != null) {
            Surface(
                color = Color.Black.copy(alpha = 0.32f),
                modifier = Modifier.fillMaxSize(),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Card(shape = RoundedCornerShape(22.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(24.dp),
                        ) {
                            CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
                            Spacer(Modifier.width(16.dp))
                            Text(state.busyMessage.orEmpty(), style = MaterialTheme.typography.titleMedium)
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeScreen(
    state: AppState,
    snackbar: SnackbarHostState,
    onOpen: (Workspace) -> Unit,
    onRefresh: () -> Unit,
    viewModel: AppViewModel,
) {
    var showAccount by remember { mutableStateOf(false) }
    var showAdd by remember { mutableStateOf(false) }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("GitNote", fontWeight = FontWeight.Black, fontSize = 30.sp)
                        Text("Working copies", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                actions = {
                    IconButton(onClick = { showAccount = true }) {
                        Icon(Icons.Default.AccountCircle, "GitHub account")
                    }
                    IconButton(onClick = { showAdd = true }) {
                        Icon(Icons.Default.Add, "Add repository")
                    }
                    IconButton(onClick = onRefresh) { Icon(Icons.Default.Refresh, "Refresh") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                modifier = Modifier.statusBarsPadding(),
            )
        },
    ) { padding ->
        if (state.workspaces.isEmpty()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
                modifier = Modifier.fillMaxSize().padding(padding).padding(32.dp),
            ) {
                Icon(Icons.Default.Description, null, Modifier.size(72.dp), tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.height(20.dp))
                Text("Your notes, backed by GitHub", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                Text("Clone a public repository or connect a fine-grained token for private repositories and sync.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(24.dp))
                Button(onClick = { showAdd = true }) {
                    Icon(Icons.Default.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Add repository")
                }
            }
        } else {
            LazyColumn(
                contentPadding = padding,
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            ) {
                item { Spacer(Modifier.height(12.dp)) }
                items(state.workspaces, key = { it.id }) { workspace ->
                    WorkspaceCard(workspace = workspace, onClick = { onOpen(workspace) })
                }
                item { Spacer(Modifier.height(24.dp).navigationBarsPadding()) }
            }
        }
    }

    if (showAccount) {
        AccountDialog(state, viewModel, onDismiss = { showAccount = false })
    }
    if (showAdd) {
        AddRepositoryDialog(state, viewModel, onDismiss = { showAdd = false })
    }
}

@Composable
private fun WorkspaceCard(workspace: Workspace, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(18.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(46.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            ) {
                Icon(Icons.Default.Description, null, tint = MaterialTheme.colorScheme.primary)
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(workspace.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(workspace.owner, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (workspace.isDirty) {
                Surface(color = MaterialTheme.colorScheme.tertiaryContainer, shape = CircleShape) {
                    Text("Changed", Modifier.padding(horizontal = 10.dp, vertical = 5.dp), style = MaterialTheme.typography.labelMedium)
                }
            }
        }
    }
}

@Composable
private fun AccountDialog(state: AppState, viewModel: AppViewModel, onDismiss: () -> Unit) {
    var token by remember { mutableStateOf("") }
    val context = LocalContext.current
    val authorization = state.githubDeviceAuthorization
    AlertDialog(
        onDismissRequest = {
            if (!state.githubSignInInProgress) onDismiss()
        },
        title = { Text(if (state.account == null) "Connect GitHub" else "GitHub account") },
        text = {
            if (state.account == null) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Selected repositories", fontWeight = FontWeight.Bold)
                    Text("Use a fine-grained token limited to the repositories GitNote should access, with Contents read/write permission.")
                    OutlinedTextField(
                        value = token,
                        onValueChange = { token = it },
                        label = { Text("Fine-grained token") },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                    )
                    Button(
                        enabled = token.isNotBlank() && !state.githubSignInInProgress,
                        onClick = {
                            viewModel.connect(token)
                            token = ""
                            onDismiss()
                        },
                    ) { Text("Connect selected repositories") }
                    HorizontalDivider()
                    Text("GitHub", fontWeight = FontWeight.Bold)
                    when {
                        authorization != null -> {
                            Text("Copy this one-time code, then authorize GitNote on GitHub:")
                            Text(
                                authorization.userCode,
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            OutlinedButton(
                                onClick = {
                                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    clipboard.setPrimaryClip(ClipData.newPlainText("GitHub device code", authorization.userCode))
                                    context.startActivity(Intent(Intent.ACTION_VIEW, authorization.verificationUri.toUri()))
                                },
                            ) { Text("Copy code and open GitHub") }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                                Text("Waiting for authorization…")
                            }
                            TextButton(onClick = viewModel::cancelGitHubSignIn) { Text("Cancel login") }
                        }
                        state.githubSignInInProgress -> {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                                Text("Starting GitHub login…")
                            }
                            TextButton(onClick = viewModel::cancelGitHubSignIn) { Text("Cancel login") }
                        }
                        else -> {
                            OutlinedButton(onClick = viewModel::startGitHubSignIn) {
                                Text("Connect public repositories with GitHub")
                            }
                            Text(
                                "GitHub login grants access to public repositories. Use a fine-grained token above for selected or private repositories.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            } else {
                Text("Connected as ${state.account.login}. Local working copies remain on this device after disconnecting.")
            }
        },
        confirmButton = {
            if (state.account != null) {
                Button(onClick = { viewModel.disconnect(); onDismiss() }) { Text("Disconnect") }
            }
        },
        dismissButton = {
            if (!state.githubSignInInProgress) {
                TextButton(onClick = onDismiss) { Text(if (state.account == null) "Close" else "Done") }
            }
        },
    )
}

@Composable
private fun AddRepositoryDialog(state: AppState, viewModel: AppViewModel, onDismiss: () -> Unit) {
    var address by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf("") }
    val repositories = state.availableRepositories.filter { it.slug.contains(filter, ignoreCase = true) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add repository") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = address,
                    onValueChange = { address = it },
                    label = { Text("owner/repository") },
                    singleLine = true,
                )
                if (state.account != null) {
                    OutlinedButton(onClick = viewModel::loadRepositories) { Text("Browse my repositories") }
                }
                if (state.availableRepositories.isNotEmpty()) {
                    OutlinedTextField(filter, { filter = it }, label = { Text("Filter repositories") }, singleLine = true)
                    LazyColumn(Modifier.height(180.dp)) {
                        items(repositories, key = { it.slug }) { repository ->
                            Row(
                                modifier = Modifier.fillMaxWidth().clickable { address = repository.slug }.padding(vertical = 9.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Default.Description, null)
                                Spacer(Modifier.width(10.dp))
                                Text(repository.slug, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                if (repository.isPrivate) Text("Private", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { Button(onClick = { viewModel.clone(address, onDismiss) }) { Text("Clone") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RepositoryScreen(
    state: AppState,
    snackbar: SnackbarHostState,
    viewModel: AppViewModel,
    onBack: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    val workspace = state.selectedWorkspace ?: return
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var showCreate by remember { mutableStateOf(false) }
    var showSync by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var moreExpanded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri != null) {
            scope.launch {
                runCatching {
                    val archive = viewModel.createExportArchive()
                    context.contentResolver.openOutputStream(uri)?.use { output -> archive.inputStream().use { it.copyTo(output) } }
                        ?: error("The selected document could not be opened.")
                }.onSuccess { snackbar.showSnackbar("Exported ${workspace.name}.zip") }
                    .onFailure { snackbar.showSnackbar(it.message ?: "Export failed") }
            }
        }
    }

    fun navigateBack() {
        if (state.folder.isBlank()) onBack()
        else viewModel.openWorkspace(workspace, state.folder.substringBeforeLast('/', ""))
    }
    BackHandler { navigateBack() }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(workspace.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (state.folder.isNotBlank()) Text(state.folder, style = MaterialTheme.typography.labelSmall)
                    }
                },
                navigationIcon = { IconButton(onClick = ::navigateBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    IconButton(onClick = { showSync = true }) { Icon(Icons.Default.Sync, "Sync") }
                    IconButton(onClick = { moreExpanded = true }) { Icon(Icons.Default.MoreVert, "More") }
                    DropdownMenu(expanded = moreExpanded, onDismissRequest = { moreExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text("Export working copy") },
                            leadingIcon = { Icon(Icons.Default.Download, null) },
                            onClick = { moreExpanded = false; exportLauncher.launch("${workspace.name}.zip") },
                        )
                        DropdownMenuItem(
                            text = { Text("Remove local copy") },
                            leadingIcon = { Icon(Icons.Default.Delete, null) },
                            onClick = { moreExpanded = false; showDelete = true },
                        )
                    }
                },
                modifier = Modifier.statusBarsPadding(),
            )
        },
        floatingActionButton = {
            if (tab == 0) Button(onClick = { showCreate = true }) {
                Icon(Icons.Default.Add, null)
                Spacer(Modifier.width(8.dp))
                Text("New")
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            PrimaryTabRow(selectedTabIndex = tab) {
                Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Notes") })
                Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Changes (${state.changes.size})") })
            }
            if (tab == 0) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it; viewModel.search(it) },
                    label = { Text("Search Markdown files") },
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                )
                if (state.folder.isNotBlank()) {
                    TextButton(onClick = { viewModel.openWorkspace(workspace, state.folder.substringBeforeLast('/', "")) }, modifier = Modifier.padding(horizontal = 12.dp)) {
                        Icon(Icons.Default.Home, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Parent folder")
                    }
                }
                EntryList(state.entries, onClick = { entry ->
                    if (entry.isDirectory) viewModel.openWorkspace(workspace, entry.relativePath)
                    else onOpenNote(entry.relativePath)
                })
            } else {
                ChangeList(state.changes)
            }
        }
    }

    if (showCreate) CreateDialog(viewModel, onDismiss = { showCreate = false }, onOpenNote = onOpenNote)
    if (showSync) SyncDialog(workspace.isDirty, viewModel, onDismiss = { showSync = false })
    if (showDelete) {
        AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text("Remove local copy?") },
            text = { Text("This deletes the working copy from this device. It does not delete the GitHub repository.") },
            confirmButton = {
                Button(onClick = { showDelete = false; viewModel.removeWorkspace(workspace, onBack) }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun EntryList(entries: List<MarkdownEntry>, onClick: (MarkdownEntry) -> Unit) {
    if (entries.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No Markdown files here", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    } else {
        LazyColumn(Modifier.fillMaxSize()) {
            items(entries, key = { it.relativePath }) { entry ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().clickable { onClick(entry) }.padding(horizontal = 20.dp, vertical = 14.dp),
                ) {
                    Icon(if (entry.isDirectory) Icons.Default.Folder else Icons.Default.Description, null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(14.dp))
                    Text(entry.name, style = MaterialTheme.typography.bodyLarge)
                }
                HorizontalDivider(Modifier.padding(start = 58.dp))
            }
            item { Spacer(Modifier.height(90.dp).navigationBarsPadding()) }
        }
    }
}

@Composable
private fun ChangeList(changes: List<FileChange>) {
    if (changes.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Working copy is clean") }
    } else {
        LazyColumn(Modifier.fillMaxSize()) {
            items(changes, key = { "${it.kind}:${it.relativePath}" }) { change ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        color = when (change.kind) {
                            ChangeKind.DELETED, ChangeKind.CONFLICTING -> MaterialTheme.colorScheme.errorContainer
                            ChangeKind.ADDED, ChangeKind.UNTRACKED -> MaterialTheme.colorScheme.primaryContainer
                            else -> MaterialTheme.colorScheme.secondaryContainer
                        },
                        shape = RoundedCornerShape(8.dp),
                    ) {
                        Text(change.kind.name.take(1), Modifier.padding(horizontal = 9.dp, vertical = 5.dp), fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(change.relativePath, Modifier.weight(1f))
                }
                HorizontalDivider(Modifier.padding(start = 58.dp))
            }
        }
    }
}

@Composable
private fun CreateDialog(viewModel: AppViewModel, onDismiss: () -> Unit, onOpenNote: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var folder by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (folder) "New folder" else "New Markdown file") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text(if (folder) "Folder name" else "File name or path") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(onClick = { folder = false }) { Icon(Icons.Default.Description, null); Text(" File") }
                    FilledTonalButton(onClick = { folder = true }) { Icon(Icons.Default.CreateNewFolder, null); Text(" Folder") }
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                if (folder) viewModel.createFolder(name) else viewModel.createNote(name, onOpenNote)
                onDismiss()
            }) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun SyncDialog(isDirty: Boolean, viewModel: AppViewModel, onDismiss: () -> Unit) {
    var message by remember { mutableStateOf("Update notes from GitNote Android") }
    var author by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Synchronize") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(if (isDirty) "GitNote will fetch first, then stage all local changes, commit, and push when the histories are compatible." else "GitNote will fetch and safely download newer commits when possible.")
                if (isDirty) {
                    OutlinedTextField(message, { message = it }, label = { Text("Commit message") })
                    OutlinedTextField(author, { author = it }, label = { Text("Author name") }, singleLine = true)
                    OutlinedTextField(email, { email = it }, label = { Text("Author email") }, singleLine = true)
                }
            }
        },
        confirmButton = { Button(onClick = { viewModel.sync(message, author, email); onDismiss() }) { Text("Sync") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditorScreen(path: String, viewModel: AppViewModel, onBack: () -> Unit) {
    val richState = rememberRichTextState()
    var original by remember { mutableStateOf<String?>(null) }
    var rawVisible by remember { mutableStateOf(false) }
    var headingMenu by remember { mutableStateOf(false) }
    var linkDialog by remember { mutableStateOf(false) }
    var discardDialog by remember { mutableStateOf(false) }
    val currentMarkdown = remember(richState.annotatedString) { if (original == null) "" else richState.toMarkdown() }
    val dirty = original != null && currentMarkdown != original

    LaunchedEffect(path) {
        val markdown = viewModel.read(path)
        richState.setMarkdown(markdown)
        original = markdown
    }

    fun attemptBack() {
        if (dirty) discardDialog = true else onBack()
    }
    BackHandler { attemptBack() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(path.substringAfterLast('/'), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = ::attemptBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    IconButton(onClick = { rawVisible = true }) { Icon(Icons.Default.Code, "View raw Markdown") }
                    IconButton(
                        enabled = dirty,
                        onClick = {
                            val markdown = richState.toMarkdown()
                            viewModel.save(path, markdown) { original = markdown }
                        },
                    ) { Icon(Icons.Default.Save, "Save") }
                },
                modifier = Modifier.statusBarsPadding(),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant).padding(8.dp),
            ) {
                item {
                    Box {
                        FormatButton(Icons.Default.FormatSize, "Heading") { headingMenu = true }
                        DropdownMenu(headingMenu, onDismissRequest = { headingMenu = false }) {
                            listOf(HeadingStyle.Normal, HeadingStyle.H1, HeadingStyle.H2, HeadingStyle.H3, HeadingStyle.H4, HeadingStyle.H5, HeadingStyle.H6).forEach { style ->
                                DropdownMenuItem(
                                    text = { Text(if (style == HeadingStyle.Normal) "Paragraph" else style.name) },
                                    onClick = { richState.setHeadingStyle(style); headingMenu = false },
                                )
                            }
                        }
                    }
                }
                item { FormatButton(Icons.Default.FormatBold, "Bold") { richState.toggleSpanStyle(SpanStyle(fontWeight = FontWeight.Bold)) } }
                item { FormatButton(Icons.Default.FormatItalic, "Italic") { richState.toggleSpanStyle(SpanStyle(fontStyle = FontStyle.Italic)) } }
                item { FormatButton(Icons.AutoMirrored.Filled.FormatListBulleted, "Bulleted list") { richState.toggleUnorderedList() } }
                item { FormatButton(Icons.AutoMirrored.Filled.List, "Numbered list") { richState.toggleOrderedList() } }
                item { FormatButton(Icons.Default.Code, "Inline code") { richState.toggleCodeSpan() } }
                item { FormatButton(Icons.Default.AddLink, "Link") { linkDialog = true } }
            }
            if (original == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else {
                OutlinedRichTextEditor(
                    state = richState,
                    modifier = Modifier.fillMaxSize().padding(12.dp),
                )
            }
        }
    }

    if (rawVisible) {
        AlertDialog(
            onDismissRequest = { rawVisible = false },
            title = { Text("Raw Markdown") },
            text = {
                OutlinedTextField(
                    value = richState.toMarkdown(),
                    onValueChange = {},
                    readOnly = true,
                    modifier = Modifier.fillMaxWidth().height(360.dp),
                )
            },
            confirmButton = { Button(onClick = { rawVisible = false }) { Text("Done") } },
        )
    }
    if (linkDialog) LinkDialog(onDismiss = { linkDialog = false }) { text, url -> richState.addLink(text, url) }
    if (discardDialog) {
        AlertDialog(
            onDismissRequest = { discardDialog = false },
            title = { Text("Discard unsaved edits?") },
            text = { Text("The note has changes that have not been saved to the working copy.") },
            confirmButton = { Button(onClick = { discardDialog = false; onBack() }) { Text("Discard") } },
            dismissButton = { TextButton(onClick = { discardDialog = false }) { Text("Keep editing") } },
        )
    }
}

@Composable
private fun FormatButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, contentPadding = androidx.compose.foundation.layout.PaddingValues(10.dp)) {
        Icon(icon, description, Modifier.size(20.dp))
    }
}

@Composable
private fun LinkDialog(onDismiss: () -> Unit, onInsert: (String, String) -> Unit) {
    var text by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("https://") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add link") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(text, { text = it }, label = { Text("Link text") })
                OutlinedTextField(url, { url = it }, label = { Text("Destination") })
            }
        },
        confirmButton = { Button(onClick = { onInsert(text.ifBlank { "link" }, url); onDismiss() }) { Text("Insert") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
