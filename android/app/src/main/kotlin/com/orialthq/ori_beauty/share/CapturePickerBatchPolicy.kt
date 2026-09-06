package com.orialthq.ori_beauty.share

object CapturePickerBatchPolicy {
    const val MAX_SELECTION = 100
    const val MAX_BATCH_BYTES = 512L * 1024L * 1024L
    const val MIN_FREE_BYTES_AFTER_NATIVE_IMPORT = 128L * 1024L * 1024L

    fun systemSelectionLimit(systemLimit: Int): Int =
        minOf(MAX_SELECTION, systemLimit)

    /**
     * Keeps enough room for Dart to copy the native staging files into the
     * durable library before it acknowledges and removes the staging batch.
     */
    fun canAccept(
        currentBatchBytes: Long,
        payloadBytes: Long,
        usableBytesAfterPayloadCopy: Long,
    ): Boolean {
        if (currentBatchBytes < 0L || payloadBytes <= 0L) return false
        if (payloadBytes > MAX_BATCH_BYTES - currentBatchBytes) return false
        val proposedBatchBytes = currentBatchBytes + payloadBytes
        return usableBytesAfterPayloadCopy >=
            proposedBatchBytes + MIN_FREE_BYTES_AFTER_NATIVE_IMPORT
    }

    fun resultMap(
        selectedCount: Int,
        importedCount: Int,
        rejectedCount: Int,
    ): Map<String, Int> =
        mapOf(
            "selectedCount" to selectedCount,
            "importedCount" to importedCount,
            "rejectedCount" to rejectedCount,
        )
}
