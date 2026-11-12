package com.henrikvindshoj.gitnote.data

import android.content.Context
import com.henrikvindshoj.gitnote.domain.Workspace
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class WorkspaceStore(context: Context) {
    private val root = File(context.filesDir, "repositories").apply { mkdirs() }
    private val metadata = File(context.filesDir, "workspaces.json")

    fun directory(id: String): File = File(root, id)

    @Synchronized
    fun load(): List<Workspace> {
        if (!metadata.isFile) return emptyList()
        return runCatching {
            val array = JSONArray(metadata.readText())
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    val id = item.getString("id")
                    val directory = directory(id)
                    if (File(directory, ".git").isDirectory) {
                        add(
                            Workspace(
                                id = id,
                                owner = item.getString("owner"),
                                repository = item.getString("repository"),
                                directory = directory,
                                defaultBranch = item.optString("defaultBranch", "main"),
                            ),
                        )
                    }
                }
            }
        }.getOrDefault(emptyList())
    }

    @Synchronized
    fun save(workspaces: List<Workspace>) {
        val array = JSONArray()
        workspaces.forEach { workspace ->
            array.put(
                JSONObject()
                    .put("id", workspace.id)
                    .put("owner", workspace.owner)
                    .put("repository", workspace.repository)
                    .put("defaultBranch", workspace.defaultBranch),
            )
        }
        val temporary = File(metadata.parentFile, "${metadata.name}.tmp")
        temporary.writeText(array.toString())
        if (!temporary.renameTo(metadata)) {
            temporary.copyTo(metadata, overwrite = true)
            temporary.delete()
        }
    }

    fun remove(workspace: Workspace) {
        workspace.directory.deleteRecursively()
    }
}
