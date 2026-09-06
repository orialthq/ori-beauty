package com.orialthq.ori_beauty.share

import org.junit.Assert.assertEquals
import org.junit.Test

class CapturePickerBatchPolicyTest {
    @Test
    fun capsTheModernSystemPickerAtOneHundred() {
        assertEquals(100, CapturePickerBatchPolicy.systemSelectionLimit(150))
        assertEquals(75, CapturePickerBatchPolicy.systemSelectionLimit(75))
        assertEquals(0, CapturePickerBatchPolicy.systemSelectionLimit(0))
    }

    @Test
    fun exposesStableMethodChannelCounts() {
        assertEquals(
            mapOf(
                "selectedCount" to 7,
                "importedCount" to 5,
                "rejectedCount" to 2,
            ),
            CapturePickerBatchPolicy.resultMap(
                selectedCount = 7,
                importedCount = 5,
                rejectedCount = 2,
            ),
        )
    }

    @Test
    fun capsBatchBytesAndReservesRoomForTheDurableCopy() {
        val mebibyte = 1024L * 1024L
        assertEquals(
            true,
            CapturePickerBatchPolicy.canAccept(
                currentBatchBytes = 500L * mebibyte,
                payloadBytes = 12L * mebibyte,
                usableBytesAfterPayloadCopy = 640L * mebibyte,
            ),
        )
        assertEquals(
            false,
            CapturePickerBatchPolicy.canAccept(
                currentBatchBytes = 501L * mebibyte,
                payloadBytes = 12L * mebibyte,
                usableBytesAfterPayloadCopy = 2_000L * mebibyte,
            ),
        )
        assertEquals(
            false,
            CapturePickerBatchPolicy.canAccept(
                currentBatchBytes = 500L * mebibyte,
                payloadBytes = 12L * mebibyte,
                usableBytesAfterPayloadCopy = 639L * mebibyte,
            ),
        )
    }
}
