import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let textView = UITextView()
  private var saveButton: UIBarButtonItem!
  private var cancelButton: UIBarButtonItem!
  private let recordID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
  private var ready = false
  private var saving = false
  private var titleText = ""
  private var loadGeneration = 0
  private var pendingError: String?
  private var entries: [(SharedTextRecord, Data?)] = []
  private let storageQueue = DispatchQueue(label: "com.github.gemsnote.share-extension")

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let bar = UINavigationBar()
    let item = UINavigationItem(title: NativeLanguage.text("保存到 Gemsnote", "Save to Gemsnote"))
    saveButton = UIBarButtonItem(title: NativeLanguage.text("保存", "Save"),
      style: .done, target: self, action: #selector(didSelectPost))
    cancelButton = UIBarButtonItem(title: NativeLanguage.text("取消", "Cancel"),
      style: .plain, target: self, action: #selector(didSelectCancel))
    item.rightBarButtonItem = saveButton
    item.leftBarButtonItem = cancelButton
    bar.items = [item]
    let hint = UILabel()
    hint.text = NativeLanguage.text("保存后，请打开 Gemsnote 选择账号和笔记本完成导入",
      "After saving, open Gemsnote and choose an account and notebook to import.")
    hint.numberOfLines = 0
    hint.font = .preferredFont(forTextStyle: .footnote)
    hint.adjustsFontForContentSizeCategory = true
    hint.textColor = .secondaryLabel
    textView.isEditable = false
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    for child in [bar, hint, textView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: safe.topAnchor),
      bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
      hint.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
      hint.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      hint.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
      textView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
      textView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
      textView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
      textView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
    ])
    validateContent()
    loadInput()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let message = pendingError {
      pendingError = nil
      showError(message)
    }
  }

  @objc private func didSelectCancel() {
    guard !saving else { return }
    loadGeneration += 1
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }

  private func validateContent() {
    saveButton.isEnabled = isContentValid()
    cancelButton.isEnabled = !saving
    isModalInPresentation = saving
  }

  private func isContentValid() -> Bool {
    ready && !saving && !entries.isEmpty
  }

  @objc private func didSelectPost() {
    guard isContentValid() else { return }
    saving = true
    textView.isEditable = false
    validateContent()
    let batch = entries
    storageQueue.async { [weak self] in
      do {
        try SharedTextStore.appGroup().enqueueBatch(batch)
        DispatchQueue.main.async {
          self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
      } catch {
        DispatchQueue.main.async {
          guard let self else { return }
          self.saving = false
          self.textView.isEditable = false
          self.validateContent()
          self.showError(error.localizedDescription)
        }
      }
    }
  }

  private func loadInput() {
    loadGeneration += 1
    let generation = loadGeneration
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    titleText = String((items.first?.attributedTitle?.string ?? "").prefix(200))
    guard items.count <= 8, providers.count <= 8 else {
      showError("一次最多分享 8 项")
      return
    }
    guard !providers.isEmpty else {
      accept(items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n\n"), generation: generation)
      return
    }
    loadProvider(providers, index: 0, generation: generation)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self, self.loadGeneration == generation, !self.ready else { return }
      self.loadGeneration += 1
      self.entries = []
      self.showError("读取分享超时，请取消后重试")
    }
  }

  private func loadProvider(_ providers: [NSItemProvider], index: Int, generation: Int) {
    guard loadGeneration == generation else { return }
    guard index < providers.count else {
      ready = true
      textView.text = entries.map { $0.0.text }.joined(separator: "\n\n")
      validateContent()
      return
    }
    let provider = providers[index]
    let remainingBytes = 32 * 1024 * 1024 - entries.reduce(0, { $0 + ($1.1?.count ?? 0) })
    let fileType = provider.registeredTypeIdentifiers.first {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: .png) || type.conforms(to: .jpeg)
    } ?? provider.registeredTypeIdentifiers.first {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: .image)
    } ?? provider.registeredTypeIdentifiers.first {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
    }
    if let fileType {
      provider.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] url, error in
        do {
          if let error { throw error }
          guard let url else { throw SharedTextStore.Failure("无法读取分享文件") }
          // Provider URLs expire when this callback returns; copy bytes here.
          let bytes = try readSharedResource(url, remainingBytes: remainingBytes)
          let name = url.lastPathComponent
          let kind = sharedResourceKind(bytes)
          DispatchQueue.main.async {
            self?.append(text: name, bytes: bytes, name: name, kind: kind,
                         providers: providers, index: index, generation: generation)
          }
        } catch {
          let message = error.localizedDescription
          DispatchQueue.main.async { self?.fail(message, generation: generation) }
        }
      }
      return
    }
    let type: String
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      type = UTType.fileURL.identifier
    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      type = UTType.url.identifier
    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      type = UTType.plainText.identifier
    } else {
      fail("无法读取此分享类型", generation: generation)
      return
    }
    provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] value, error in
      if type == UTType.fileURL.identifier, let url = value as? URL, url.isFileURL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
          if let error { throw error }
          if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ||
            ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) {
            let text = try readSharedText(url)
            DispatchQueue.main.async {
              self?.append(text: text, providers: providers, index: index, generation: generation)
            }
            return
          }
          let bytes = try readSharedResource(url, remainingBytes: remainingBytes)
          let name = url.lastPathComponent
          let kind = sharedResourceKind(bytes)
          DispatchQueue.main.async {
            self?.append(text: name, bytes: bytes, name: name, kind: kind,
                         providers: providers, index: index, generation: generation)
          }
        } catch {
          let message = error.localizedDescription
          DispatchQueue.main.async { self?.fail(message, generation: generation) }
        }
        return
      }
      var text: String?
      if type == UTType.url.identifier {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty {
          text = url.absoluteString
        }
      } else if let value {
        do {
          text = try readSharedText(value)
        } catch {
          let message = error.localizedDescription
          DispatchQueue.main.async { self?.fail(message, generation: generation) }
          return
        }
      }
      let loaded = text
      DispatchQueue.main.async {
        guard let self, self.loadGeneration == generation else { return }
        if let error {
          self.fail(NativeLanguage.text("读取分享失败：", "Unable to read share: ") +
                    error.localizedDescription, generation: generation)
        } else {
          self.append(text: loaded, providers: providers, index: index, generation: generation)
        }
      }
    }
  }

  private func fail(_ message: String, generation: Int) {
    guard loadGeneration == generation else { return }
    loadGeneration += 1
    entries = []
    ready = false
    validateContent()
    showError(message)
  }

  private func append(text: String?, bytes: Data? = nil, name: String? = nil,
                      kind: String? = nil, providers: [NSItemProvider], index: Int, generation: Int) {
    guard loadGeneration == generation else { return }
    let record = SharedTextRecord(
      id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)),
      title: titleText, text: text ?? "", resourceKind: kind, resourceName: name, resourceSize: bytes?.count)
    guard (try? record.validate()) != nil,
      entries.reduce(0, { $0 + ($1.1?.count ?? 0) }) + (bytes?.count ?? 0) <= 32 * 1024 * 1024 else {
      fail("分享内容无效、文本超过 256 KiB 或资源总大小超过 32 MiB", generation: generation)
      return
    }
    entries.append((record, bytes))
    loadProvider(providers, index: index + 1, generation: generation)
  }

  private func accept(_ text: String?, generation: Int) {
    guard loadGeneration == generation else { return }
    loadGeneration += 1
    guard let text,
      (try? SharedTextRecord(id: recordID, title: titleText, text: text).validate()) != nil
    else {
      showError("分享内容为空、格式不支持或超过 256 KiB")
      return
    }
    textView.text = text
    entries = [(SharedTextRecord(id: recordID, title: titleText, text: text), nil)]
    textView.isEditable = false
    ready = true
    validateContent()
  }

  private func showError(_ message: String) {
    guard viewIfLoaded?.window != nil else {
      pendingError = message
      return
    }
    let alert = UIAlertController(title: NativeLanguage.text("未保存分享", "Share not saved"),
      message: NativeLanguage.error(message), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: NativeLanguage.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }
}
