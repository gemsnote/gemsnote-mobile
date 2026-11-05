import Flutter
import UIKit
import AVFoundation
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sharedTextBridge: SharedTextBridge?
  private var avatarCamera: AvatarCamera?
  private var languageChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "com.github.gemsnote.resourceCache")
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "com.github.gemsnote.noteSync")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    sharedTextBridge = SharedTextBridge(messenger: engineBridge.applicationRegistrar.messenger())
    avatarCamera = AvatarCamera(messenger: engineBridge.applicationRegistrar.messenger())
    let language = FlutterMethodChannel(name: "gemsnote/app_language",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    language.setMethodCallHandler { call, result in
      guard call.method == "setLanguage" else { result(FlutterMethodNotImplemented); return }
      do {
        guard let args = call.arguments as? [String: Any],
          let preference = args["language"] as? String else {
          throw SharedTextStore.Failure("语言设置无效")
        }
        try NativeLanguage.set(preference)
        result(nil)
      } catch {
        result(FlutterError(code: "language", message: error.localizedDescription, details: nil))
      }
    }
    languageChannel = language
  }
}

/// Capture only: no photo-library access or persistent copy of the portrait.
final class AvatarCamera: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gemsnote/avatar_camera", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      guard call.method == "capture" else { result(FlutterMethodNotImplemented); return }
      guard self.pending == nil else {
        result(FlutterError(code: "cameraBusy",
          message: NativeLanguage.text("相机已打开", "Camera is already open"), details: nil))
        return
      }
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
        result(FlutterError(code: "cameraUnavailable",
          message: NativeLanguage.text("没有可用相机", "No camera is available"), details: nil))
        return
      }
      self.pending = result
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: self.presentCamera()
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
          DispatchQueue.main.async {
            if allowed { self?.presentCamera() } else { self?.permissionDenied() }
          }
        }
      default: self.permissionDenied()
      }
    }
  }

  private func finish(_ value: Any?) {
    let callback = pending
    pending = nil
    callback?(value)
  }

  private func permissionDenied() {
    finish(FlutterError(code: "cameraPermission",
      message: NativeLanguage.text("请在系统设置中允许相机权限后拍摄头像",
        "Allow camera access in Settings to take an avatar photo"), details: nil))
  }

  private func presentCamera() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      finish(FlutterError(code: "cameraInactive",
        message: NativeLanguage.text("请返回应用后重试", "Return to the app and try again"), details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    guard !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else {
      finish(FlutterError(code: "cameraInactive",
        message: NativeLanguage.text("请返回应用后重试", "Return to the app and try again"), details: nil))
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image"]
    picker.delegate = self
    picker.modalPresentationStyle = .fullScreen
    presenter.present(picker, animated: true)
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true) { self.finish(nil) }
  }

  func imagePickerController(_ picker: UIImagePickerController,
                             didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    var response: Any = FlutterError(code: "cameraImage",
      message: NativeLanguage.text("无法处理照片", "Unable to process the photo"), details: nil)
    if let image = info[.originalImage] as? UIImage, image.size.width > 0, image.size.height > 0 {
      let scale = min(1, 1024 / max(image.size.width, image.size.height))
      let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                        height: max(1, (image.size.height * scale).rounded()))
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      // Drawing normalizes the camera orientation and strips EXIF/location metadata.
      let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      if let bytes = normalized.jpegData(compressionQuality: 0.85),
        !bytes.isEmpty, bytes.count <= 2 * 1024 * 1024 {
        response = FlutterStandardTypedData(bytes: bytes)
      }
    }
    let value = response
    picker.dismiss(animated: true) { self.finish(value) }
  }
}
