import Foundation

@main
struct SeedImport {
  static func main() throws {
    guard CommandLine.arguments.count == 4,
      CommandLine.arguments[2].range(of: "^[0-9a-f]{22}$", options: .regularExpression) != nil else {
      throw SharedTextStore.Failure("Usage: seed-import <group-directory> <run-id> <png-file>")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("SharedTextInbox")
    let store = SharedTextStore(directory: directory)
    guard try store.peek() == nil else {
      throw SharedTextStore.Failure("Use an empty test inbox; existing shares will not be modified")
    }
    let prefix = CommandLine.arguments[2]
    let png = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let binary = Data([0, 1, 2, 127, 128, 255])
    try store.enqueueBatch([
      (SharedTextRecord(id: prefix + "00", title: "Native text", text: "离线分享 \(prefix)"), nil),
      (SharedTextRecord(id: prefix + "01", title: "Native image", text: "image.png",
        resourceKind: "image", resourceName: "image.png", resourceSize: png.count), png),
      (SharedTextRecord(id: prefix + "02", title: "Native file", text: "fixture.bin",
        resourceKind: "attachment", resourceName: "fixture.bin", resourceSize: binary.count), binary),
    ])
    print("Seeded three uniquely identified native import fixtures")
  }
}
