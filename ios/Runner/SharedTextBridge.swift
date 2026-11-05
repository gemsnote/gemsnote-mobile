import Flutter
import Foundation

final class SharedTextBridge {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.github.gemsnote.share-inbox")

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gemsnote/shared_text", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      guard ["peek", "claim", "acknowledge", "readResource"].contains(call.method) else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.queue.async {
        do {
          let store = try SharedTextStore.appGroup()
          var value: Any?
          if call.method == "peek" {
            value = try store.peek()?.dictionary
          } else {
            guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
              throw SharedTextStore.Failure("缺少分享标识")
            }
            if call.method == "claim" || call.method == "readResource" {
              guard let accountKey = args["accountKey"] as? String else {
                throw SharedTextStore.Failure("缺少分享目标账号")
              }
              if call.method == "claim" {
                try store.claim(id: id, accountKey: accountKey)
              } else {
                value = FlutterStandardTypedData(bytes: try store.readResource(id: id, accountKey: accountKey))
              }
            } else {
              try store.acknowledge(id: id)
            }
          }
          let response = value
          DispatchQueue.main.async { result(response) }
        } catch {
          let failure = FlutterError(code: "shareInbox", message: error.localizedDescription, details: nil)
          DispatchQueue.main.async { result(failure) }
        }
      }
    }
  }
}
