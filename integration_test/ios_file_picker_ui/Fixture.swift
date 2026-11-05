import UIKit

/// Disposable local Files location, independent of the user's app documents.
@main
final class PickerFiles: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try! Data("Local picker fixture".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
    let window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
