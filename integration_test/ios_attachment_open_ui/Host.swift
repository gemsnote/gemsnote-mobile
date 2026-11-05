import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private let receipt = UILabel()

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let root = UIViewController()
    root.view.backgroundColor = .systemBackground
    receipt.accessibilityIdentifier = "open-receipt"
    receipt.text = "Waiting"
    receipt.numberOfLines = 0
    receipt.translatesAutoresizingMaskIntoConstraints = false
    root.view.addSubview(receipt)
    NSLayoutConstraint.activate([
      receipt.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 20),
      receipt.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -20),
      receipt.centerYAnchor.constraint(equalTo: root.view.centerYAnchor),
    ])
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = root
    window.makeKeyAndVisible()
    self.window = window
    if let url = launchOptions?[.url] as? URL { receive(url) }
    return true
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    receive(url)
    return true
  }

  private func receive(_ url: URL) {
    do {
      let data = try Data(contentsOf: url)
      let value: [String: String] = [
        "name": url.lastPathComponent,
        "bytes": data.base64EncodedString(),
      ]
      let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      receipt.text = String(decoding: encoded, as: UTF8.self)
    } catch {
      receipt.text = "error: " + String(describing: error)
    }
  }
}
