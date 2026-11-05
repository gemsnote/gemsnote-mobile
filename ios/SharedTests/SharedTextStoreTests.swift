import Foundation
import CoreGraphics
import ImageIO
import Darwin

// Runs against the same Foundation storage source used in both iOS targets.
// No iOS SDK or third-party test framework is required for these storage tests.
@main
struct SharedTextStoreTests {
  static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SharedTextStore.Failure("FAIL: \(message)") }
  }

  static func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw SharedTextStore.Failure("FAIL: expected rejection: \(message)")
  }

  static func record(_ number: Int, text: String = "分享正文") -> SharedTextRecord {
    SharedTextRecord(id: String(format: "%024x", number), title: "标题", text: text)
  }

  static func imageBytes(type: String, width: Int = 1) throws -> Data {
    guard let context = CGContext(data: nil, width: width, height: 1,
      bitsPerComponent: 8, bytesPerRow: 4 * width,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let image = context.makeImage() else { throw SharedTextStore.Failure("image fixture") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
      throw SharedTextStore.Failure("image destination fixture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw SharedTextStore.Failure("image encoding fixture") }
    return output as Data
  }

  static func main() throws {
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "enqueue" {
      let directory = URL(fileURLWithPath: CommandLine.arguments[2])
      try SharedTextStore(directory: directory).enqueue(record(Int(CommandLine.arguments[3])!))
      return
    }
    try check(NativeLanguage.isChinese(preference: "system", languages: ["zh-Hant-TW"]),
      "system Chinese variants")
    try check(!NativeLanguage.isChinese(preference: "system", languages: ["fr", "zh"]),
      "other system languages use English")
    try check(NativeLanguage.isChinese(preference: "zh", languages: ["en"]),
      "explicit Chinese")
    try check(!NativeLanguage.isChinese(preference: "en", languages: ["zh"]),
      "explicit English")
    print("PASS native language selection")
    try check(sharedResourceKind(imageBytes(type: "public.png")) == "image",
      "PNG shares use the image import path")
    try check(sharedResourceKind(imageBytes(type: "public.jpeg")) == "image",
      "JPEG shares use the image import path")
    try check(sharedResourceKind(imageBytes(type: "public.png", width: 4097)) == "attachment",
      "large dimensions preserve the original as an attachment")
    try check(sharedResourceKind(Data([255, 216, 255])) == "attachment",
      "invalid image bytes are not passed to inline import")
    for bytes in [Data("GIF89a".utf8), Data("ftypheic".utf8), Data("%PDF".utf8)] {
      try check(sharedResourceKind(bytes) == "attachment",
        "unsupported inline formats preserve original attachment")
    }
    var largeImage = Data([255, 216, 255])
    largeImage.append(Data(repeating: 0, count: 8 * 1024 * 1024))
    try check(sharedResourceKind(largeImage) == "attachment",
      "large images remain importable as original attachments")
    print("PASS shared resource classification")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let providerFile = root.appendingPathComponent("provider.bin")
    let providerBytes = Data((0..<(128 * 1024 + 7)).map { UInt8($0 % 251) })
    try providerBytes.write(to: providerFile)
    try check(readSharedResource(providerFile, remainingBytes: providerBytes.count) == providerBytes,
      "bounded multi-chunk read retains exact original at the budget boundary")
    try rejects("remaining batch budget, not just per-file limit") {
      _ = try readSharedResource(providerFile, remainingBytes: providerBytes.count - 1)
    }
    try rejects("exhausted batch budget") {
      _ = try readSharedResource(providerFile, remainingBytes: 0)
    }
    try rejects("cannot raise the shared resource limit") {
      _ = try readSharedResource(providerFile, remainingBytes: 32 * 1024 * 1024 + 1)
    }
    try rejects("directory is not a shared file") {
      _ = try readSharedResource(root, remainingBytes: 32 * 1024 * 1024)
    }
    try rejects("missing provider file") {
      _ = try readSharedResource(root.appendingPathComponent("missing"), remainingBytes: 1024)
    }
    try rejects("network URL is never fetched") {
      _ = try readSharedResource(URL(string: "https://example.invalid/file")!, remainingBytes: 1024)
    }
    try Data().write(to: providerFile)
    try rejects("empty provider file") {
      _ = try readSharedResource(providerFile, remainingBytes: 1024)
    }
    let fifo = root.appendingPathComponent("provider-pipe")
    try check(mkfifo(fifo.path, 0o600) == 0, "create non-regular provider fixture")
    try rejects("non-regular provider cannot block waiting for data") {
      _ = try readSharedResource(fifo, remainingBytes: 1024)
    }
    print("PASS bounded provider reads and remaining batch capacity")
    let plainFile = root.appendingPathComponent("shared.txt")
    let plain = "\u{FEFF}正文\nsecond line"
    try Data(plain.utf8).write(to: plainFile)
    for value: Any in [plain, Data(plain.utf8), plainFile] {
      try check(readSharedText(value) == "正文\nsecond line", "text representation preserves body and removes UTF-8 BOM")
    }
    let exactText = String(repeating: "a", count: 256 * 1024)
    try Data(exactText.utf8).write(to: plainFile)
    try check(readSharedText(plainFile) == exactText, "text file exact byte limit")
    try Data((exactText + "b").utf8).write(to: plainFile)
    try rejects("text file byte limit") { _ = try readSharedText(plainFile) }
    try rejects("in-memory text byte limit") { _ = try readSharedText(exactText + "b") }
    try rejects("text URL must be local") { _ = try readSharedText(URL(string: "https://example.invalid/text")!) }
    for value: Any in [Data([0xff, 0xfe]), "\u{FEFF} \n", "a\0b", 12] {
      try rejects("invalid text representation") { _ = try readSharedText(value) }
    }
    print("PASS strict text String/Data/file representations and UTF-8 byte limits")

    let directory = root.appendingPathComponent("basic")
    let store = SharedTextStore(directory: directory)
    try check(store.peek() == nil, "empty inbox")
    let first = record(1)
    try store.enqueue(first)
    try store.enqueue(first)
    try check(SharedTextStore(directory: directory).peek() == first, "durable, non-consuming peek")
    try rejects("same ID changed content") { try store.enqueue(record(1, text: "changed")) }
    try rejects("empty claim") { try store.claim(id: first.id, accountKey: "") }
    try rejects("missing claim") { try store.claim(id: record(2).id, accountKey: "A") }
    try store.claim(id: first.id, accountKey: "server-A/user")
    try store.claim(id: first.id, accountKey: "server-A/user")
    try rejects("cross-account claim") { try store.claim(id: first.id, accountKey: "server-B/user") }
    try store.enqueue(first)
    try check(store.peek()?.accountKey == "server-A/user", "enqueue retry preserves claimed account")
    try store.acknowledge(id: record(2).id)
    try check(store.peek()?.id == first.id, "unknown acknowledgement does not remove other entries")
    try store.acknowledge(id: first.id)
    try store.acknowledge(id: first.id)
    try check(store.peek() == nil, "idempotent acknowledgement; only one retry record")
    print("PASS persistence, claim isolation, idempotence")

    let payload = Data([1, 2, 3, 4])
    var image = record(10, text: "photo.png")
    image.resourceKind = "image"
    image.resourceName = "photo.png"
    image.resourceSize = payload.count
    try store.enqueueBatch([(first, nil), (image, payload)])
    try store.acknowledge(id: first.id)
    try check(store.peek() == image, "batch preserves FIFO metadata")
    try rejects("unclaimed original") { _ = try store.readResource(id: image.id, accountKey: "A") }
    try store.claim(id: image.id, accountKey: "A")
    try check(store.readResource(id: image.id, accountKey: "A") == payload, "durable original")
    try rejects("other account original") { _ = try store.readResource(id: image.id, accountKey: "B") }
    try store.enqueueBatch([(image, payload)])
    try rejects("different original retry") {
      try store.enqueueBatch([(image, Data([4, 3, 2, 1]))])
    }
    try store.acknowledge(id: image.id)
    try check(!FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(image.id + ".resource").path), "ack cleans original")
    try rejects("bad batch leaves no prefix") {
      try store.enqueueBatch([(first, nil), (image, Data([1]))])
    }
    try check(store.peek() == nil, "failed batch is invisible")
    var unsafe = image
    unsafe.resourceName = "../photo.png"
    try rejects("unsafe filename") { try store.enqueueBatch([(unsafe, payload)]) }
    for index in 1...7 { try store.enqueue(record(index)) }
    try rejects("capacity rejects whole batch") {
      try store.enqueueBatch([(image, payload), (record(11), nil)])
    }
    for index in 1...7 { try store.acknowledge(id: record(index).id) }
    try check(store.peek() == nil, "capacity failure left no partial entries")
    print("PASS resource persistence, account isolation, atomic batch, cleanup")

    for text in ["", " \n", "\u{FEFF}\u{85}\u{A0}", "nul\0", String(repeating: "中", count: 90_000)] {
      try rejects("invalid content") { try store.enqueue(record(1, text: text)) }
    }
    try rejects("invalid ID") {
      try store.enqueue(SharedTextRecord(id: "invalid", title: "", text: "text"))
    }
    try rejects("oversized title") {
      try store.enqueue(SharedTextRecord(id: first.id, title: String(repeating: "x", count: 201), text: "text"))
    }
    try rejects("pre-bound account") {
      try store.enqueue(SharedTextRecord(id: first.id, title: "", text: "text", accountKey: "A"))
    }
    let combiningTitle = "a" + String(repeating: "\u{301}", count: 5000)
    try check(combiningTitle.count == 1, "combining character fixture")
    try rejects("one grapheme cannot bypass title byte limit") {
      try store.enqueue(SharedTextRecord(id: first.id, title: combiningTitle, text: "text"))
    }
    // Max-size control characters expand sixfold in JSON, still fit the disk bound.
    let escaped = String(repeating: "\u{1}", count: 256 * 1024)
    for index in 1...8 { try store.enqueue(record(index, text: escaped)) }
    try rejects("inbox full") { try store.enqueue(record(9)) }
    for index in 1...8 {
      try check(store.peek()?.id == record(index).id, "FIFO order")
      try store.acknowledge(id: record(index).id)
    }
    print("PASS input/byte limits, bounded queue, FIFO")

    let damaged = Data("not-json".utf8)
    let file = directory.appendingPathComponent("queue.json")
    try damaged.write(to: file)
    try rejects("corrupt peek") { _ = try store.peek() }
    try rejects("corrupt enqueue") { try store.enqueue(first) }
    try rejects("corrupt acknowledge") { try store.acknowledge(id: first.id) }
    try check(Data(contentsOf: file) == damaged, "corruption never silently replaces queued data")
    try JSONEncoder().encode([first, first]).write(to: file)
    try rejects("duplicate IDs on disk") { _ = try store.peek() }
    try Data(repeating: 0, count: 16 * 1024 * 1024 + 1).write(to: file)
    try rejects("oversized disk data") { _ = try store.peek() }
    print("PASS corrupt and oversized storage protection")

    // Independent OS processes exercise the app/extension locking boundary.
    let parallelDirectory = root.appendingPathComponent("parallel")
    let children = try (1...8).map { index -> Process in
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["enqueue", parallelDirectory.path, String(index)]
      try child.run()
      return child
    }
    for child in children {
      child.waitUntilExit()
      try check(child.terminationStatus == 0, "child enqueue")
    }
    let parallel = SharedTextStore(directory: parallelDirectory)
    var ids = Set<String>()
    while let entry = try parallel.peek() {
      ids.insert(entry.id)
      try parallel.acknowledge(id: entry.id)
    }
    try check(ids == Set((1...8).map { record($0).id }), "no lost concurrent writes")
    print("PASS cross-process concurrent writes; all storage tests passed")
  }
}
