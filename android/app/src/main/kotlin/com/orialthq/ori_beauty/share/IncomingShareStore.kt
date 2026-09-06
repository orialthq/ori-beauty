package com.orialthq.ori_beauty.share

import android.content.Context
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

class IncomingShareStore(context: Context) {
    private val attachmentDirectory =
        File(context.noBackupFilesDir, IncomingShareIngestor.ATTACHMENT_DIRECTORY_NAME)
    private val preferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun append(payload: IncomingSharePayload): Boolean = appendAll(listOf(payload))

    /**
     * Appends a picker batch with one durable preferences commit. Either every
     * payload becomes visible to Dart, or none of them do.
     */
    @Synchronized
    fun appendAll(payloads: Collection<IncomingSharePayload>): Boolean {
        if (payloads.isEmpty()) {
            return true
        }
        val pending = readArray()
        payloads.forEach { payload -> pending.put(payload.toJson()) }
        return writeArray(pending)
    }

    @Synchronized
    fun pending(): List<Map<String, Any?>> {
        val pending = readArray()
        return buildList {
            for (index in 0 until pending.length()) {
                val item = pending.getJSONObject(index)
                val attachments =
                    item.optJSONArray("attachments")?.toAttachmentMaps().orEmpty()
                add(
                    mapOf(
                        "id" to item.getString("id"),
                        "receivedAtEpochMs" to item.getLong("receivedAtEpochMs"),
                        "sharedText" to item.getString("sharedText"),
                        "discoveredUrl" to item.optString("discoveredUrl").ifBlank { null },
                        "sourcePackage" to
                            item.optString("sourcePackage").ifBlank { null },
                        "mimeType" to item.optString("mimeType", "text/plain"),
                        "wasTruncated" to item.optBoolean("wasTruncated", false),
                        "originalLength" to
                            item.optInt(
                                "originalLength",
                                item.getString("sharedText").length,
                            ),
                        "shareKind" to
                            item.optString("shareKind").ifBlank {
                                if (attachments.isEmpty()) SHARE_KIND_TEXT else SHARE_KIND_IMAGE
                            },
                        "attachments" to attachments,
                    ),
                )
            }
        }
    }

    @Synchronized
    fun loadAppSnapshot(): String? = preferences.getString(KEY_APP_SNAPSHOT, null)

    @Synchronized
    fun saveAppSnapshot(snapshot: String): Boolean {
        if (snapshot.isBlank()) {
            return false
        }
        return preferences
            .edit()
            .putString(KEY_APP_SNAPSHOT, snapshot)
            .commit()
    }

    @Synchronized
    fun loadPlanSnapshot(): String? = preferences.getString(KEY_PLAN_SNAPSHOT, null)

    @Synchronized
    fun savePlanSnapshot(snapshot: String): Boolean {
        if (snapshot.isBlank()) {
            return false
        }
        return preferences
            .edit()
            .putString(KEY_PLAN_SNAPSHOT, snapshot)
            .commit()
    }

    @Synchronized
    fun acknowledge(ids: Collection<String>): Boolean {
        if (ids.isEmpty()) {
            return true
        }
        val pending = readArray()
        val remaining = JSONArray()
        val acknowledgedAttachmentPaths = mutableListOf<String>()
        for (index in 0 until pending.length()) {
            val item = pending.getJSONObject(index)
            if (item.getString("id") !in ids) {
                remaining.put(item)
            } else {
                val attachments = item.optJSONArray("attachments")
                if (attachments != null) {
                    for (attachmentIndex in 0 until attachments.length()) {
                        attachments
                            .optJSONObject(attachmentIndex)
                            ?.optString("filePath")
                            ?.takeIf(String::isNotBlank)
                            ?.let(acknowledgedAttachmentPaths::add)
                    }
                }
            }
        }
        if (!writeArray(remaining)) {
            return false
        }
        acknowledgedAttachmentPaths.forEach(::deleteManagedAttachment)
        return true
    }

    private fun readArray(): JSONArray {
        val raw = preferences.getString(KEY_PENDING_SHARES, null)
        return if (raw.isNullOrBlank()) JSONArray() else runCatching { JSONArray(raw) }
            .getOrDefault(JSONArray())
    }

    private fun writeArray(value: JSONArray): Boolean {
        return preferences
            .edit()
            .putString(KEY_PENDING_SHARES, value.toString())
            .commit()
    }

    private fun IncomingSharePayload.toJson(): JSONObject =
        JSONObject()
            .put("id", id)
            .put("receivedAtEpochMs", receivedAtEpochMs)
            .put("sharedText", sharedText)
            .put("discoveredUrl", discoveredUrl)
            .put("sourcePackage", sourcePackage)
            .put("mimeType", mimeType)
            .put("wasTruncated", wasTruncated)
            .put("originalLength", originalLength)
            .put("shareKind", shareKind)
            .put(
                "attachments",
                JSONArray().apply {
                    attachments.forEach { attachment ->
                        put(
                            JSONObject()
                                .put("id", attachment.id)
                                .put("filePath", attachment.filePath)
                                .put("mimeType", attachment.mimeType)
                                .put("byteSize", attachment.byteSize)
                                .put("width", attachment.width)
                                .put("height", attachment.height)
                                .put("sha256", attachment.sha256),
                        )
                    }
                },
            )

    private fun JSONArray.toAttachmentMaps(): List<Map<String, Any?>> {
        return buildList {
            for (index in 0 until length()) {
                val attachment = optJSONObject(index) ?: continue
                add(
                    mapOf(
                        "id" to attachment.optString("id"),
                        "filePath" to attachment.optString("filePath"),
                        "mimeType" to attachment.optString("mimeType"),
                        "byteSize" to attachment.optLong("byteSize"),
                        "width" to attachment.optInt("width"),
                        "height" to attachment.optInt("height"),
                        "sha256" to attachment.optString("sha256"),
                    ),
                )
            }
        }
    }

    private fun deleteManagedAttachment(filePath: String) {
        val root = runCatching { attachmentDirectory.canonicalFile }.getOrNull() ?: return
        val file = runCatching { File(filePath).canonicalFile }.getOrNull() ?: return
        if (file.parentFile == root) {
            file.delete()
        }
    }

    companion object {
        private const val PREFERENCES_NAME = "incoming_share_store"
        private const val KEY_PENDING_SHARES = "pending_shares_v1"
        private const val KEY_APP_SNAPSHOT = "app_snapshot_v1"
        private const val KEY_PLAN_SNAPSHOT = "plan_snapshot_v1"
    }
}
