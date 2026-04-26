import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let offlineBackupChannelName = "pulseconnect/offline_backup"
  private let autoBackupFolderName = "PulseConnect"
  private var offlineBackupChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let flutterController = window?.rootViewController as? FlutterViewController {
      setupOfflineBackupChannelIfNeeded(binaryMessenger: flutterController.binaryMessenger)
    }
    return didFinish
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OfflineBackupBridge")
    setupOfflineBackupChannelIfNeeded(binaryMessenger: registrar.messenger())
  }

  private func setupOfflineBackupChannelIfNeeded(binaryMessenger: FlutterBinaryMessenger) {
    if offlineBackupChannel != nil {
      return
    }

    let channel = FlutterMethodChannel(
      name: offlineBackupChannelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "App delegate unavailable.", details: nil))
        return
      }
      switch call.method {
      case "writeBackupFileAuto":
        self.writeBackupFileAuto(call: call, result: result)
      case "readBackupFileAuto":
        self.readBackupFileAuto(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    offlineBackupChannel = channel
  }

  private func writeBackupFileAuto(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let fileNameRaw = (args["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let typedBytes = args["bytes"] as? FlutterStandardTypedData
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "fileName and bytes are required.",
          details: nil
        )
      )
      return
    }

    guard let fileName = validatedFileName(fileNameRaw) else {
      result(
        FlutterError(
          code: "invalid_filename",
          message: "fileName is invalid.",
          details: nil
        )
      )
      return
    }

    let data = typedBytes.data

    do {
      let folderURL = try autoBackupDirectoryURL()
      let fileURL = folderURL.appendingPathComponent(fileName, isDirectory: false)
      try data.write(to: fileURL, options: .atomic)
      result(true)
    } catch {
      result(
        FlutterError(
          code: "write_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func readBackupFileAuto(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let fileNameRaw = (args["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "fileName is required.",
          details: nil
        )
      )
      return
    }

    guard let fileName = validatedFileName(fileNameRaw) else {
      result(
        FlutterError(
          code: "invalid_filename",
          message: "fileName is invalid.",
          details: nil
        )
      )
      return
    }

    do {
      let folderURL = try autoBackupDirectoryURL()
      let fileURL = folderURL.appendingPathComponent(fileName, isDirectory: false)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        result(nil)
        return
      }
      let data = try Data(contentsOf: fileURL)
      result(FlutterStandardTypedData(bytes: data))
    } catch {
      result(
        FlutterError(
          code: "read_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func autoBackupDirectoryURL() throws -> URL {
    let fileManager = FileManager.default
    let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    guard let documentsURL = docs else {
      throw NSError(
        domain: "pulseconnect.offline_backup",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable."]
      )
    }
    let folderURL = documentsURL.appendingPathComponent(autoBackupFolderName, isDirectory: true)
    if !fileManager.fileExists(atPath: folderURL.path) {
      try fileManager.createDirectory(
        at: folderURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }
    return folderURL
  }

  private func validatedFileName(_ fileName: String) -> String? {
    if fileName.isEmpty { return nil }
    if fileName.contains("/") || fileName.contains("\\") { return nil }
    if fileName == "." || fileName == ".." { return nil }
    return fileName
  }
}
