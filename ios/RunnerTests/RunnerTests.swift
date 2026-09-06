import Flutter
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {
  func testCapturePickerBatchLimitAndPlatformCounts() {
    XCTAssertEqual(CapturePickerPresenter.maxSelectionCount, 100)

    let result = CapturePickerImportResult(
      selectedCount: 7,
      importedCount: 5,
      rejectedCount: 2
    )
    XCTAssertEqual(
      result.platformMap,
      [
        "selectedCount": 7,
        "importedCount": 5,
        "rejectedCount": 2,
      ]
    )
    XCTAssertEqual(CapturePickerImportResult.cancelled.platformMap.values.reduce(0, +), 0)

    let mebibyte: Int64 = 1024 * 1024
    XCTAssertTrue(
      CapturePickerPresenter.canAccept(
        currentBatchBytes: 500 * mebibyte,
        payloadBytes: 12 * mebibyte,
        availableBytesAfterPayloadCopy: 640 * mebibyte
      )
    )
    XCTAssertFalse(
      CapturePickerPresenter.canAccept(
        currentBatchBytes: 501 * mebibyte,
        payloadBytes: 12 * mebibyte,
        availableBytesAfterPayloadCopy: 2_000 * mebibyte
      )
    )
    XCTAssertFalse(
      CapturePickerPresenter.canAccept(
        currentBatchBytes: 0,
        payloadBytes: mebibyte,
        availableBytesAfterPayloadCopy: nil
      ),
      "An unavailable capacity lookup must fail closed."
    )
    XCTAssertFalse(
      CapturePickerPresenter.canAccept(
        currentBatchBytes: 0,
        payloadBytes: mebibyte,
        availableBytesAfterPayloadCopy: -1
      )
    )
    XCTAssertEqual(
      CapturePickerPresenter.resolvedAvailableCapacity(
        importantUsage: 200,
        general: 100
      ),
      200
    )
    XCTAssertEqual(
      CapturePickerPresenter.resolvedAvailableCapacity(
        importantUsage: nil,
        general: 100
      ),
      100
    )
    XCTAssertNil(
      CapturePickerPresenter.resolvedAvailableCapacity(
        importantUsage: nil,
        general: nil
      )
    )
  }
}
