import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private enum MapProvider: String, CaseIterable {
    case naver
    case kakao
    case google
  }

  private var placeReminderChannel: FlutterMethodChannel?
  private var portableTipChannel: FlutterMethodChannel?
  private var incomingShareChannel: FlutterMethodChannel?
  private let nativeTriggerScheduler = NativeTriggerSchedulerBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    nativeTriggerScheduler.applicationDidFinishLaunching()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if nativeTriggerScheduler.handleWillPresent(notification, completion: completionHandler) {
      return
    }
    super.userNotificationCenter(
      center,
      willPresent: notification,
      withCompletionHandler: completionHandler
    )
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if nativeTriggerScheduler.handleResponse(response, completion: completionHandler) {
      return
    }
    super.userNotificationCenter(
      center,
      didReceive: response,
      withCompletionHandler: completionHandler
    )
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if PortableTipInbox.shared.stage(url: url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    nativeTriggerScheduler.attach(to: engineBridge.applicationRegistrar.messenger())

    let incomingChannel = FlutterMethodChannel(
      name: "com.orialthq.ori_beauty/incoming_share/v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    incomingChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "drainPendingShares":
        result(IncomingShareStore.shared.pending())
      case "presentCapturePicker":
        CapturePickerPresenter.shared.present { outcome in
          switch outcome {
          case .success(let importResult):
            result(importResult.platformMap)
          case .failure(let error):
            result(
              FlutterError(
                code: error.rawValue,
                message: "The capture picker could not be presented.",
                details: nil
              )
            )
          }
        }
      case "loadAppSnapshot":
        result(AppSnapshotFileStore.shared.load())
      case "loadPlanSnapshot":
        result(AppSnapshotFileStore.shared.loadPlanSnapshot())
      case "saveAppSnapshot":
        guard let snapshot = call.arguments as? String, !snapshot.isEmpty else {
          result(
            FlutterError(
              code: "invalid_snapshot",
              message: "App snapshot must be a non-empty string.",
              details: nil
            )
          )
          return
        }
        if AppSnapshotFileStore.shared.save(snapshot) {
          result(true)
        } else {
          result(
            FlutterError(
              code: "snapshot_save_failed",
              message: "App snapshot could not be committed to durable storage.",
              details: nil
            )
          )
        }
      case "savePlanSnapshot":
        guard let snapshot = call.arguments as? String, !snapshot.isEmpty else {
          result(
            FlutterError(
              code: "invalid_plan_snapshot",
              message: "Plan snapshot must be a non-empty string.",
              details: nil
            )
          )
          return
        }
        if AppSnapshotFileStore.shared.savePlanSnapshot(snapshot) {
          result(true)
        } else {
          result(
            FlutterError(
              code: "plan_snapshot_save_failed",
              message: "Plan snapshot could not be committed to durable storage.",
              details: nil
            )
          )
        }
      case "acknowledgeShares":
        let arguments = call.arguments as? [String: Any]
        let ids = arguments?["ids"] as? [String] ?? []
        if IncomingShareStore.shared.acknowledge(ids: ids) {
          result(nil)
        } else {
          result(
            FlutterError(
              code: "share_acknowledge_failed",
              message: "Pending shares could not be committed to durable storage.",
              details: nil
            )
          )
        }
      case "keepSharedSource":
        result(nil)
      case "deleteSharedSource":
        // iOS copies out of the photo library rather than owning the original.
        result("unavailable")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    incomingShareChannel = incomingChannel
    CapturePickerPresenter.shared.onPendingChanged = { [weak incomingChannel] in
      DispatchQueue.main.async {
        incomingChannel?.invokeMethod("pendingSharesChanged", arguments: nil)
      }
    }

    let channel = FlutterMethodChannel(
      name: "com.orialthq.ori_beauty/place_reminders/v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "map_unavailable",
            message: "The map handler is unavailable.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "getMapProviders":
        result(self.mapProviderOptions())
      case "openMapProvider":
        self.openMap(arguments: call.arguments, result: result)
      case "openMap":
        var arguments = call.arguments as? [String: Any] ?? [:]
        arguments["provider"] = MapProvider.naver.rawValue
        self.openMap(arguments: arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    placeReminderChannel = channel

    let portableChannel = FlutterMethodChannel(
      name: "com.orialthq.ori_beauty/portable_tip/v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    portableChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "pendingPackages":
        result(PortableTipInbox.shared.pending())
      case "acknowledgePackages":
        let arguments = call.arguments as? [String: Any]
        let transportIds = arguments?["transportIds"] as? [String] ?? []
        PortableTipInbox.shared.acknowledge(transportIds: transportIds)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    PortableTipInbox.shared.onPendingChanged = { [weak portableChannel] in
      DispatchQueue.main.async {
        portableChannel?.invokeMethod("pendingPackagesChanged", arguments: nil)
      }
    }
    portableTipChannel = portableChannel
  }

  private func mapProviderOptions() -> [[String: Any]] {
    MapProvider.allCases.map { provider in
      [
        "id": provider.rawValue,
        "appInstalled": mapAppURL(provider: provider, query: "Trun On")
          .map(UIApplication.shared.canOpenURL) ?? false,
        "available": true,
      ]
    }
  }

  private func openMap(arguments: Any?, result: @escaping FlutterResult) {
    let values = arguments as? [String: Any]
    guard
      let providerName = values?["provider"] as? String,
      let provider = MapProvider(rawValue: providerName)
    else {
      result(
        FlutterError(
          code: "invalid_map_provider",
          message: "A supported map provider is required.",
          details: nil
        )
      )
      return
    }

    let explicitQuery =
      (values?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = (values?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let address =
      (values?["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let query =
      explicitQuery?.isEmpty == false
      ? explicitQuery!
      : [name, address]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !query.isEmpty else {
      result(
        FlutterError(
          code: "invalid_place",
          message: "A map query is required.",
          details: nil
        )
      )
      return
    }

    // Dart already reduced the capture to `상호명 + 지역`, which is the query the
    // provider is expected to resolve. Nothing here second-guesses it.
    let appURL = mapAppURL(provider: provider, query: query)
    let appInstalled = appURL.map(UIApplication.shared.canOpenURL) ?? false
    let webURL = mapWebURL(provider: provider, query: query)

    guard let targetURL = appInstalled ? appURL : webURL else {
      result(
        FlutterError(
          code: "map_unavailable",
          message: "A map URL could not be created.",
          details: nil
        )
      )
      return
    }

    UIApplication.shared.open(targetURL, options: [:]) { opened in
      DispatchQueue.main.async {
        if opened {
          result([
            "provider": provider.rawValue,
            "openedInApp": appInstalled,
          ])
        } else {
          result(
            FlutterError(
              code: "map_unavailable",
              message: "No map app or browser could open the place.",
              details: nil
            )
          )
        }
      }
    }
  }

  private func mapAppURL(provider: MapProvider, query: String) -> URL? {
    var components: URLComponents
    switch provider {
    case .naver:
      components = URLComponents()
      components.scheme = "nmap"
      components.host = "search"
      components.queryItems = [
        URLQueryItem(name: "query", value: query),
        URLQueryItem(
          name: "appname",
          value: Bundle.main.bundleIdentifier ?? "com.orialthq.ori_beauty"
        ),
      ]
    case .kakao:
      components = URLComponents()
      components.scheme = "kakaomap"
      components.host = "search"
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    case .google:
      components = URLComponents(string: "comgooglemaps://") ?? URLComponents()
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    }
    return components.url
  }

  private func mapWebURL(provider: MapProvider, query: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    switch provider {
    case .naver:
      components.host = "map.naver.com"
      components.path = "/p/search/\(query)"
    case .kakao:
      components.host = "map.kakao.com"
      components.path = "/link/search/\(query)"
    case .google:
      components.host = "www.google.com"
      components.path = "/maps/search/"
      components.queryItems = [
        URLQueryItem(name: "api", value: "1"),
        URLQueryItem(name: "query", value: query),
      ]
    }
    return components.url
  }
}
