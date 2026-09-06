import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct CapturePickerImportResult: Equatable {
  let selectedCount: Int
  let importedCount: Int
  let rejectedCount: Int

  static let cancelled = CapturePickerImportResult(
    selectedCount: 0,
    importedCount: 0,
    rejectedCount: 0
  )

  var platformMap: [String: Int] {
    [
      "selectedCount": selectedCount,
      "importedCount": importedCount,
      "rejectedCount": rejectedCount,
    ]
  }
}

/// iOS entry point for the picker path Android exposes through its quick settings
/// tile (`MainActivity.launchCapturePicker`).
///
/// `PHPickerViewController` runs out of process, so no photo library permission and
/// no `NSPhotoLibraryUsageDescription` are required. Selected images are never handed
/// back to Dart directly: they go through the ingestor into the pending queue, and
/// Dart is told to drain — the same ordering Android uses so a snapshot commit is
/// still what acknowledges an input.
final class CapturePickerPresenter: NSObject {
  static let shared = CapturePickerPresenter()
  static let maxSelectionCount = 100
  static let maxBatchBytes: Int64 = 512 * 1024 * 1024
  static let minimumFreeBytesAfterNativeImport: Int64 = 128 * 1024 * 1024

  static func canAccept(
    currentBatchBytes: Int64,
    payloadBytes: Int64,
    availableBytesAfterPayloadCopy: Int64?
  ) -> Bool {
    guard currentBatchBytes >= 0, payloadBytes > 0 else { return false }
    guard payloadBytes <= maxBatchBytes - currentBatchBytes else { return false }
    guard let availableBytesAfterPayloadCopy, availableBytesAfterPayloadCopy >= 0 else {
      return false
    }
    let proposedBatchBytes = currentBatchBytes + payloadBytes
    return availableBytesAfterPayloadCopy
      >= proposedBatchBytes + minimumFreeBytesAfterNativeImport
  }

  static func resolvedAvailableCapacity(
    importantUsage: Int64?,
    general: Int?
  ) -> Int64? {
    importantUsage ?? general.map(Int64.init)
  }

  /// Called after at least one image was accepted into the pending queue.
  var onPendingChanged: (() -> Void)?

  private var isPresenting = false
  /// `PHPickerViewController.delegate` is weak, so the delegate has to be held
  /// here. Without this it deallocates immediately and selecting a photo silently
  /// does nothing.
  private var activeDelegate: PickerDelegate?

  private override init() {
    super.init()
  }

  func present(completion: @escaping (Result<CapturePickerImportResult, PickerError>) -> Void) {
    guard !isPresenting else {
      completion(.failure(.alreadyPresenting))
      return
    }
    guard let host = Self.topViewController() else {
      completion(.failure(.noHostViewController))
      return
    }

    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = Self.maxSelectionCount

    let picker = PHPickerViewController(configuration: configuration)
    let delegate = PickerDelegate(presenter: self, completion: completion)
    activeDelegate = delegate
    picker.delegate = delegate

    isPresenting = true
    host.present(picker, animated: true)
  }

  fileprivate func finishPresenting() {
    isPresenting = false
    // Released on the next turn so the delegate is not deallocated while its own
    // callback is still running.
    DispatchQueue.main.async { [weak self] in
      self?.activeDelegate = nil
    }
  }

  /// Loads and validates one provider at a time, then atomically records every
  /// accepted one-image payload when the batch is complete.
  fileprivate func ingest(
    results: [PHPickerResult],
    completion: @escaping (CapturePickerImportResult) -> Void
  ) {
    guard !results.isEmpty else {
      completion(.cancelled)
      return
    }
    guard results.count <= Self.maxSelectionCount else {
      completion(
        CapturePickerImportResult(
          selectedCount: results.count,
          importedCount: 0,
          rejectedCount: results.count
        )
      )
      return
    }
    PickerBatchImportOperation(
      results: results,
      onPendingChanged: { [weak self] in self?.onPendingChanged?() },
      completion: completion
    ).start()
  }

  private static func topViewController() -> UIViewController? {
    let scene =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard
      var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        ?? scene?.windows.first?.rootViewController
    else {
      return nil
    }
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  enum PickerError: String, Error {
    case alreadyPresenting = "picker_already_presenting"
    case noHostViewController = "picker_unavailable"
  }
}

private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
  private weak var presenter: CapturePickerPresenter?
  private let completion:
    (Result<CapturePickerImportResult, CapturePickerPresenter.PickerError>) -> Void

  init(
    presenter: CapturePickerPresenter,
    completion:
      @escaping (
        Result<CapturePickerImportResult, CapturePickerPresenter.PickerError>
      ) -> Void
  ) {
    self.presenter = presenter
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)

    guard let presenter else {
      completion(.success(.cancelled))
      return
    }
    presenter.ingest(results: results) { [presenter, completion] importResult in
      DispatchQueue.main.async {
        presenter.finishPresenting()
        completion(.success(importResult))
      }
    }
  }
}

/// Owns one picker import so provider loading, validation and private-storage
/// copies stay sequential. At most one provider representation is live at once.
private final class PickerBatchImportOperation {
  private let results: [PHPickerResult]
  private let onPendingChanged: () -> Void
  private let completion: (CapturePickerImportResult) -> Void
  private let fileManager = FileManager.default
  private let queue = DispatchQueue(
    label: "com.orialthq.ori_beauty.capture-picker-import",
    qos: .userInitiated
  )
  private let stagingDirectory: URL

  private var nextIndex = 0
  private var payloads: [IncomingSharePayload] = []
  private var batchBytes: Int64 = 0

  init(
    results: [PHPickerResult],
    onPendingChanged: @escaping () -> Void,
    completion: @escaping (CapturePickerImportResult) -> Void
  ) {
    self.results = results
    self.onPendingChanged = onPendingChanged
    self.completion = completion
    stagingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("incoming_share_staging", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  func start() {
    queue.async { [self] in
      do {
        try fileManager.createDirectory(
          at: stagingDirectory,
          withIntermediateDirectories: true
        )
        loadNextProvider()
      } catch {
        completeWithoutImport()
      }
    }
  }

  private func loadNextProvider() {
    guard nextIndex < results.count else {
      commitBatch()
      return
    }

    let provider = results[nextIndex].itemProvider
    nextIndex += 1
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      loadNextProvider()
      return
    }

    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
      [self] sourceURL, _ in
      // The provider URL expires when this callback returns, so stage it here.
      guard let sourceURL else {
        queue.async { [self] in loadNextProvider() }
        return
      }
      let pathExtension = sourceURL.pathExtension.isEmpty ? "img" : sourceURL.pathExtension
      let stagedURL = stagingDirectory.appendingPathComponent(
        "\(UUID().uuidString).\(pathExtension)"
      )
      do {
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        queue.async { [self] in ingest(stagedURL: stagedURL) }
      } catch {
        queue.async { [self] in loadNextProvider() }
      }
    }
  }

  private func ingest(stagedURL: URL) {
    defer {
      try? fileManager.removeItem(at: stagedURL)
      loadNextProvider()
    }
    guard
      let payload = IncomingShareIngestor.shared.ingest(
        sourceURLs: [stagedURL],
        declaredMimeType: nil,
        sourcePackage: nil
      )
    else {
      return
    }
    let payloadBytes = payload.attachments.reduce(Int64(0)) { partial, attachment in
      partial + attachment.byteSize
    }
    guard
      CapturePickerPresenter.canAccept(
        currentBatchBytes: batchBytes,
        payloadBytes: payloadBytes,
        availableBytesAfterPayloadCopy: availableCapacity()
      )
    else {
      IncomingShareIngestor.shared.deleteAttachments(payload.attachments)
      return
    }
    payloads.append(payload)
    batchBytes += payloadBytes
  }

  private func availableCapacity() -> Int64? {
    do {
      let values = try stagingDirectory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      return CapturePickerPresenter.resolvedAvailableCapacity(
        importantUsage: values.volumeAvailableCapacityForImportantUsage,
        general: values.volumeAvailableCapacity
      )
    } catch {
      // Capacity is a safety boundary: an unknown value must reject this image
      // instead of being treated as effectively unlimited storage.
      return nil
    }
  }

  private func commitBatch() {
    defer { try? fileManager.removeItem(at: stagingDirectory) }

    let committed = !payloads.isEmpty && IncomingShareStore.shared.appendAll(payloads)
    if !committed {
      payloads.forEach { payload in
        IncomingShareIngestor.shared.deleteAttachments(payload.attachments)
      }
    }
    let importedCount = committed ? payloads.count : 0
    if importedCount > 0 {
      onPendingChanged()
    }
    completion(
      CapturePickerImportResult(
        selectedCount: results.count,
        importedCount: importedCount,
        rejectedCount: results.count - importedCount
      )
    )
  }

  private func completeWithoutImport() {
    try? fileManager.removeItem(at: stagingDirectory)
    completion(
      CapturePickerImportResult(
        selectedCount: results.count,
        importedCount: 0,
        rejectedCount: results.count
      )
    )
  }
}
