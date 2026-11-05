import Foundation
import Darwin
import ImageIO

enum NativeLanguage {
  static var preferences: UserDefaults {
    if let group = Bundle.main.object(forInfoDictionaryKey: "GemsnoteAppGroup") as? String,
      !group.isEmpty, !group.contains("$("), let defaults = UserDefaults(suiteName: group) {
      return defaults
    }
    return .standard
  }

  static func set(_ language: String) throws {
    guard ["system", "zh", "en"].contains(language) else {
      throw SharedTextStore.Failure("语言设置无效")
    }
    preferences.set(language, forKey: "gemsnote.language")
  }

  static func isChinese(preference: String, languages: [String]) -> Bool {
    preference == "zh" || (preference == "system" &&
      (languages.first ?? "en").lowercased().hasPrefix("zh"))
  }

  static var chinese: Bool {
    isChinese(preference: preferences.string(forKey: "gemsnote.language") ?? "system",
              languages: Locale.preferredLanguages)
  }

  static func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }

  static func error(_ message: String) -> String {
    if chinese { return message }
    return errors[message] ?? message
  }

  private static let errors = [
    "语言设置无效": "Invalid language preference",
    "分享文本无效或超过 256 KiB": "Invalid shared text or text exceeds 256 KiB",
    "分享资源信息无效或超过 32 MiB": "Invalid shared resource or resource exceeds 32 MiB",
    "分享资源类型缺失": "Missing resource type",
    "无法访问分享收件箱，请检查 App Group 签名配置": "Cannot access the share inbox. Check App Group signing.",
    "一次最多分享 8 项，资源总大小不能超过 32 MiB": "Share up to 8 items with at most 32 MiB of files",
    "新分享不能预先绑定账号": "A new share cannot already belong to an account",
    "分享资源不完整": "The shared file is incomplete",
    "此分享已保存，不能覆盖其内容": "This share is already saved and cannot be overwritten",
    "此分享原件不一致": "The original shared file has changed",
    "收件箱已满，请先在 Gemsnote 处理待导入分享": "Inbox full. Import or discard pending shares in Gemsnote first.",
    "分享资源不存在或不属于当前账号": "Shared file missing or owned by another account",
    "分享目标账号无效": "Invalid destination account",
    "待导入分享不存在": "Pending share not found",
    "此分享已绑定其他账号，请切换到该账号处理": "This share belongs to another account. Switch to that account to continue.",
    "分享收件箱过大，未更改已有数据": "Share inbox too large. Existing data has been preserved.",
    "分享收件箱数据无效，未更改已有数据": "Invalid share inbox. Existing data has been preserved.",
    "缺少分享标识": "Missing share ID",
    "缺少分享目标账号": "Missing destination account",
    "一次最多分享 8 项": "Share up to 8 items at a time",
    "读取分享超时，请取消后重试": "Reading the share timed out. Cancel and try again.",
    "无法读取分享文件": "Cannot read the shared file",
    "文件为空或超过 32 MiB": "File is empty or exceeds 32 MiB",
    "无法读取此分享类型": "Cannot read this type of share",
    "分享内容无效、文本超过 256 KiB 或资源总大小超过 32 MiB":
      "Invalid share, text exceeds 256 KiB, or files exceed 32 MiB in total",
    "分享内容为空、格式不支持或超过 256 KiB":
      "The share is empty, unsupported, or exceeds 256 KiB",
  ]
}

/// Read inside the provider callback while its temporary URL is still valid.
/// Bound the actual read, not only the file's initial size: a provider may still
/// be writing, and earlier items already consume part of the batch budget.
func readSharedResource(_ url: URL, remainingBytes: Int) throws -> Data {
  guard url.isFileURL, remainingBytes > 0, remainingBytes <= 32 * 1024 * 1024 else {
    throw SharedTextStore.Failure("分享资源信息无效或超过 32 MiB")
  }
  let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
  guard descriptor >= 0 else { throw SharedTextStore.Failure("无法读取分享文件") }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  defer { try? handle.close() }
  var info = stat()
  guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
    info.st_size > 0, info.st_size <= remainingBytes else {
    throw SharedTextStore.Failure("分享资源信息无效或超过 32 MiB")
  }
  var bytes = Data()
  while let chunk = try handle.read(upToCount: min(64 * 1024, remainingBytes - bytes.count + 1)),
    !chunk.isEmpty {
    guard chunk.count <= remainingBytes - bytes.count else {
      throw SharedTextStore.Failure("分享资源信息无效或超过 32 MiB")
    }
    bytes.append(chunk)
  }
  guard bytes.count == info.st_size else {
    throw SharedTextStore.Failure("分享资源不完整")
  }
  return bytes
}

/// NSItemProvider may return a temporary file URL even for plain text.
/// Read it while the provider callback is alive, never treating a remote URL as a file.
func readSharedText(_ value: Any) throws -> String {
  let bytes: Data
  if let url = value as? URL {
    guard url.isFileURL else { throw SharedTextStore.Failure("无法读取分享文件") }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      bytes = try readSharedResource(url, remainingBytes: 256 * 1024)
    } catch {
      throw SharedTextStore.Failure("分享文本无效或超过 256 KiB")
    }
  } else if let data = value as? Data {
    bytes = data
  } else if let string = value as? String {
    guard string.utf8.count <= 256 * 1024 else {
      throw SharedTextStore.Failure("分享文本无效或超过 256 KiB")
    }
    bytes = Data(string.utf8)
  } else {
    throw SharedTextStore.Failure("无法读取此分享类型")
  }
  guard bytes.count <= 256 * 1024, var text = String(data: bytes, encoding: .utf8) else {
    throw SharedTextStore.Failure("分享文本无效或超过 256 KiB")
  }
  if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
  let blanks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
  guard !text.trimmingCharacters(in: blanks).isEmpty, !text.contains("\0") else {
    throw SharedTextStore.Failure("分享文本无效或超过 256 KiB")
  }
  return text
}

/// Match Flutter's inline-image formats. Preserve other originals (including
/// HEIC/GIF/PDF) as attachments instead of creating an unimportable image item.
func sharedResourceKind(_ bytes: Data) -> String {
  let png = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
  let jpeg = bytes.starts(with: [255, 216, 255])
  guard (png || jpeg), bytes.count <= 8 * 1024 * 1024,
    let source = CGImageSourceCreateWithData(bytes as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = properties[kCGImagePropertyPixelWidth] as? Int,
    let height = properties[kCGImagePropertyPixelHeight] as? Int,
    width > 0, height > 0, width <= 4096, height <= 4096 else { return "attachment" }
  return "image"
}

struct SharedTextRecord: Codable, Equatable {
  let id: String
  let title: String
  let text: String
  var accountKey: String = ""
  var resourceKind: String? = nil
  var resourceName: String? = nil
  var resourceSize: Int? = nil

  var dictionary: [String: Any] {
    ["id": id, "title": title, "text": text, "accountKey": accountKey,
     "resourceKind": resourceKind ?? "", "resourceName": resourceName ?? "",
     "resourceSize": resourceSize ?? 0]
  }

  func validate() throws {
    guard id.utf8.count == 24,
      id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      title.utf8.count <= 8192, title.count <= 200, accountKey.utf8.count <= 8192,
      !text.trimmingCharacters(in: .whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty,
      !text.contains("\0"), text.utf8.count <= 256 * 1024
    else { throw SharedTextStore.Failure("分享文本无效或超过 256 KiB") }
    if let kind = resourceKind {
      guard ["image", "attachment"].contains(kind), let name = resourceName,
        !name.isEmpty, name.utf16.count <= 255, name != ".", name != "..",
        !name.unicodeScalars.contains(where: {
          $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\"
        }), let size = resourceSize, size > 0, size <= 32 * 1024 * 1024
      else { throw SharedTextStore.Failure("分享资源信息无效或超过 32 MiB") }
    } else if resourceName != nil || resourceSize != nil {
      throw SharedTextStore.Failure("分享资源类型缺失")
    }
  }
}

/// Shared by the containing app and extension. Every read/modify/write holds a
/// separate lock file: atomically replacing the JSON file must not replace the lock.
final class SharedTextStore {
  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { NativeLanguage.error(message) }
  }

  private let directory: URL
  private var queueURL: URL { directory.appendingPathComponent("queue.json") }
  init(directory: URL) { self.directory = directory }

  static func appGroup() throws -> SharedTextStore {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "GemsnoteAppGroup") as? String,
      !group.isEmpty, !group.contains("$("),
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { throw Failure("无法访问分享收件箱，请检查 App Group 签名配置") }
    return SharedTextStore(directory: container.appendingPathComponent("SharedTextInbox"))
  }

  func peek() throws -> SharedTextRecord? { try locked { try read().first } }

  func enqueue(_ record: SharedTextRecord) throws {
    try enqueueBatch([(record, nil)])
  }

  /// Publish all entries together only after every private original is durable.
  func enqueueBatch(_ entries: [(SharedTextRecord, Data?)]) throws {
    guard !entries.isEmpty, entries.count <= 8,
      Set(entries.map { $0.0.id }).count == entries.count,
      entries.reduce(0, { $0 + ($1.1?.count ?? 0) }) <= 32 * 1024 * 1024
    else { throw Failure("一次最多分享 8 项，资源总大小不能超过 32 MiB") }
    for (record, bytes) in entries {
      try record.validate()
      guard record.accountKey.isEmpty else { throw Failure("新分享不能预先绑定账号") }
      guard record.resourceSize == bytes?.count else { throw Failure("分享资源不完整") }
    }
    try locked {
      var records = try read()
      var additions: [(SharedTextRecord, Data?)] = []
      for (record, bytes) in entries {
        if var existing = records.first(where: { $0.id == record.id }) {
          existing.accountKey = ""
          guard existing == record else { throw Failure("此分享已保存，不能覆盖其内容") }
          if let bytes {
            guard try Data(contentsOf: resourceURL(record.id)) == bytes else {
              throw Failure("此分享原件不一致")
            }
          }
        } else {
          additions.append((record, bytes))
        }
      }
      guard records.count + additions.count <= 8 else {
        throw Failure("收件箱已满，请先在 Gemsnote 处理待导入分享")
      }
      do {
        for (record, bytes) in additions {
          if let bytes {
            #if os(iOS)
            try bytes.write(to: resourceURL(record.id),
              options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: resourceURL(record.id), options: .atomic)
            #endif
          }
          records.append(record)
        }
        try write(records)
      } catch {
        for (record, _) in additions { try? FileManager.default.removeItem(at: resourceURL(record.id)) }
        throw error
      }
    }
  }

  private func resourceURL(_ id: String) -> URL {
    directory.appendingPathComponent(id + ".resource")
  }

  func readResource(id: String, accountKey: String) throws -> Data {
    try locked {
      guard !accountKey.isEmpty,
        let record = try read().first(where: { $0.id == id }),
        record.accountKey == accountKey, let size = record.resourceSize else {
        throw Failure("分享资源不存在或不属于当前账号")
      }
      let url = resourceURL(record.id)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.size] as? NSNumber)?.intValue == size else {
        throw Failure("分享资源不完整")
      }
      let bytes = try Data(contentsOf: url)
      guard bytes.count == size else { throw Failure("分享资源不完整") }
      return bytes
    }
  }

  func claim(id: String, accountKey: String) throws {
    guard !accountKey.isEmpty, accountKey.utf8.count <= 8192 else {
      throw Failure("分享目标账号无效")
    }
    try locked {
      var records = try read()
      guard let index = records.firstIndex(where: { $0.id == id }) else {
        throw Failure("待导入分享不存在")
      }
      guard records[index].accountKey.isEmpty || records[index].accountKey == accountKey else {
        throw Failure("此分享已绑定其他账号，请切换到该账号处理")
      }
      records[index].accountKey = accountKey
      try write(records)
    }
  }

  func acknowledge(id: String) throws {
    try locked {
      var records = try read()
      let removed = records.first { $0.id == id }
      records.removeAll { $0.id == id }
      try write(records)
      if let removed { try? FileManager.default.removeItem(at: resourceURL(removed.id)) }
    }
  }

  private func read() throws -> [SharedTextRecord] {
    guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
    let size = try FileManager.default.attributesOfItem(atPath: queueURL.path)[.size] as? NSNumber
    // JSON escaping can expand each input byte sixfold.
    guard let size, size.intValue <= 16 * 1024 * 1024 else {
      throw Failure("分享收件箱过大，未更改已有数据")
    }
    let records = try JSONDecoder().decode([SharedTextRecord].self, from: Data(contentsOf: queueURL))
    guard records.count <= 8, Set(records.map(\.id)).count == records.count else {
      throw Failure("分享收件箱数据无效，未更改已有数据")
    }
    try records.forEach { try $0.validate() }
    return records
  }

  private func write(_ records: [SharedTextRecord]) throws {
    let data = try JSONEncoder().encode(records)
    #if os(iOS)
    try data.write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: queueURL, options: .atomic)
    #endif
  }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.appendingPathComponent("queue.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
