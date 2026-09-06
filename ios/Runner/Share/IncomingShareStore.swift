import Foundation

/// Mirror of `share/IncomingShareStore.kt` for the pending-share queue.
///
/// Android keeps the queue in `SharedPreferences`; iOS keeps it in a JSON file next
/// to the attachments. The app snapshot is *not* handled here — iOS already stores it
/// through `AppSnapshotFileStore`, so this type covers only the queue that
/// `drainPendingShares` and `acknowledgeShares` operate on.
final class IncomingShareStore {
  static let shared = IncomingShareStore()

  private let fileManager = FileManager.default
  private let lock = NSLock()

  private lazy var queueURL: URL? = {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    do {
      try fileManager.createDirectory(
        at: base,
        withIntermediateDirectories: true,
        attributes: nil
      )
      return base.appendingPathComponent("incoming_share_pending_v1.json", isDirectory: false)
    } catch {
      return nil
    }
  }()

  private lazy var attachmentDirectory: URL? = {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    return base.appendingPathComponent(
      IncomingShareIngestor.attachmentDirectoryName,
      isDirectory: true
    )
  }()

  private init() {}

  @discardableResult
  func append(_ payload: IncomingSharePayload) -> Bool {
    appendAll([payload])
  }

  /// Commits a picker batch with one atomic queue-file replacement. This keeps
  /// Dart from observing only part of a multi-image selection.
  @discardableResult
  func appendAll(_ payloads: [IncomingSharePayload]) -> Bool {
    guard !payloads.isEmpty else { return true }

    lock.lock()
    defer { lock.unlock() }

    var pending = readArray()
    pending.append(contentsOf: payloads.map(Self.storedItem))
    return writeArray(pending)
  }

  private static func storedItem(_ payload: IncomingSharePayload) -> [String: Any] {
    [
      "id": payload.id,
      "receivedAtEpochMs": payload.receivedAtEpochMs,
      "sharedText": payload.sharedText,
      "discoveredUrl": payload.discoveredUrl as Any,
      "sourcePackage": payload.sourcePackage as Any,
      "mimeType": payload.mimeType,
      "wasTruncated": payload.wasTruncated,
      "originalLength": payload.originalLength,
      "shareKind": payload.shareKind,
      "attachments": payload.attachments.map { attachment in
        [
          "id": attachment.id,
          "filePath": attachment.filePath,
          "mimeType": attachment.mimeType,
          "byteSize": attachment.byteSize,
          "width": attachment.width,
          "height": attachment.height,
          "sha256": attachment.sha256,
        ] as [String: Any]
      },
    ]
  }

  /// Platform maps consumed by `IncomingShare.fromPlatformMap` on the Dart side.
  func pending() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }

    return readArray().compactMap { item in
      guard let id = item["id"] as? String, !id.isEmpty,
        let receivedAtEpochMs = item["receivedAtEpochMs"] as? Int64
          ?? (item["receivedAtEpochMs"] as? Int).map(Int64.init),
        let sharedText = item["sharedText"] as? String
      else {
        return nil
      }
      let attachments = attachmentMaps(item["attachments"])
      return [
        "id": id,
        "receivedAtEpochMs": receivedAtEpochMs,
        "sharedText": sharedText,
        "discoveredUrl": (item["discoveredUrl"] as? String)?.nilWhenBlank as Any,
        "sourcePackage": (item["sourcePackage"] as? String)?.nilWhenBlank as Any,
        "mimeType": (item["mimeType"] as? String)?.nilWhenBlank ?? "text/plain",
        "wasTruncated": item["wasTruncated"] as? Bool ?? false,
        "originalLength": item["originalLength"] as? Int ?? sharedText.count,
        "shareKind": (item["shareKind"] as? String)?.nilWhenBlank
          ?? (attachments.isEmpty ? ShareKind.text : ShareKind.image),
        "attachments": attachments,
      ]
    }
  }

  @discardableResult
  func acknowledge(ids: [String]) -> Bool {
    guard !ids.isEmpty else { return true }

    lock.lock()
    defer { lock.unlock() }

    let acknowledged = Set(ids)
    var remaining: [[String: Any]] = []
    var acknowledgedAttachmentPaths: [String] = []

    for item in readArray() {
      guard let id = item["id"] as? String else { continue }
      if acknowledged.contains(id) {
        for attachment in attachmentMaps(item["attachments"]) {
          if let path = (attachment["filePath"] as? String)?.nilWhenBlank {
            acknowledgedAttachmentPaths.append(path)
          }
        }
      } else {
        remaining.append(item)
      }
    }

    guard writeArray(remaining) else {
      return false
    }
    acknowledgedAttachmentPaths.forEach(deleteManagedAttachment)
    return true
  }

  private func attachmentMaps(_ raw: Any?) -> [[String: Any]] {
    guard let items = raw as? [[String: Any]] else { return [] }
    return items.compactMap { attachment in
      guard let id = attachment["id"] as? String,
        let filePath = attachment["filePath"] as? String,
        let mimeType = attachment["mimeType"] as? String,
        let sha256 = attachment["sha256"] as? String
      else {
        return nil
      }
      let byteSize =
        attachment["byteSize"] as? Int64
        ?? (attachment["byteSize"] as? Int).map(Int64.init)
        ?? 0
      return [
        "id": id,
        "filePath": filePath,
        "mimeType": mimeType,
        "byteSize": byteSize,
        "width": attachment["width"] as? Int ?? 0,
        "height": attachment["height"] as? Int ?? 0,
        "sha256": sha256,
      ]
    }
  }

  private func readArray() -> [[String: Any]] {
    guard let queueURL,
      let data = try? Data(contentsOf: queueURL),
      !data.isEmpty,
      let decoded = try? JSONSerialization.jsonObject(with: data),
      let array = decoded as? [[String: Any]]
    else {
      return []
    }
    return array
  }

  private func writeArray(_ value: [[String: Any]]) -> Bool {
    guard let queueURL,
      let data = try? JSONSerialization.data(withJSONObject: value)
    else {
      return false
    }
    do {
      try data.write(to: queueURL, options: [.atomic, .completeFileProtection])
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      var mutableURL = queueURL
      try? mutableURL.setResourceValues(resourceValues)
      return true
    } catch {
      return false
    }
  }

  private func deleteManagedAttachment(filePath: String) {
    guard let attachmentDirectory else { return }
    let root = URL(fileURLWithPath: attachmentDirectory.path).standardizedFileURL
    let file = URL(fileURLWithPath: filePath).standardizedFileURL
    guard file.deletingLastPathComponent() == root else { return }
    try? fileManager.removeItem(at: file)
  }
}

extension String {
  fileprivate var nilWhenBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : self
  }
}
