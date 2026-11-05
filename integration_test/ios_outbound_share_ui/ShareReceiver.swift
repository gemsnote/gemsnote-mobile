import UIKit
import UniformTypeIdentifiers

/// Disposable local receiver; reports actual provider data for UI assertions.
final class ShareReceiver: UIViewController {
  private let receipt = UILabel()
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    receipt.numberOfLines = 0
    receipt.accessibilityIdentifier = "share-receipt"
    receipt.text = "Loading"
    let done = UIButton(type: .system)
    done.setTitle("Close receiver", for: .normal)
    done.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [receipt, done])
    stack.axis = .vertical
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
    ])
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    guard providers.count == 1, let provider = providers.first else {
      report(["error": "Expected exactly one provider"]); return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
        if let text = item as? String { self.report(["text": text]) }
        else { self.report(["error": "Text provider failed: \(String(describing: error))"]) }
      }
    } else {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
        do {
          guard let url = url else { throw NSError(domain: "MissingFile", code: 1) }
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
          guard size >= 0 && size <= 1024 * 1024 else { throw NSError(domain: "FixtureSize", code: 1) }
          let data = try Data(contentsOf: url)
          self.report(["name": url.lastPathComponent, "bytes": data.base64EncodedString()])
        } catch { self.report(["error": String(describing: error)]) }
      }
    }
  }
  private func report(_ value: [String: String]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    DispatchQueue.main.async { self.receipt.text = String(data: data, encoding: .utf8) }
  }
  @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
