import XCTest

final class OpenUITests: XCTestCase {
  func testAttachmentsReachDocumentReceiver() throws {
    continueAfterFailure = false
    let run = ProcessInfo.processInfo.environment["ATTACHMENT_OPEN_RUN"]!
    let receiver = XCUIApplication(bundleIdentifier: "com.github.gemsnote.OpenReceiver")
    receiver.launch()
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")

    for kind in ["binary", "empty"] {
      app.launch()
      let button = app.buttons["Open \(kind)"]
      XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
      button.tap()

      // UIDocumentInteraction may expose the declared document app directly
      // inside Quick Look (for example “Copy to OpenReceiver”).
      let direct = app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@", "OpenReceiver")
      ).firstMatch
      XCTAssertTrue(direct.waitForExistence(timeout: 20), app.debugDescription)
      direct.tap()

      let receipt = receiver.staticTexts["open-receipt"]
      XCTAssertTrue(receipt.waitForExistence(timeout: 20), receiver.debugDescription)
      let name = kind == "binary" ? "_open-\(run)-附件_.bin" : "open-\(run)-empty.bin"
      expectation(for: NSPredicate(format: "label CONTAINS %@", name), evaluatedWith: receipt)
      waitForExpectations(timeout: 20)
      let value = try JSONSerialization.jsonObject(with: Data(receipt.label.utf8)) as! [String: String]
      XCTAssertNil(value["error"], receipt.label)
      XCTAssertEqual(value["name"], name)
      XCTAssertEqual(Data(base64Encoded: value["bytes"]!), kind == "binary" ? Data([0, 1, 127, 128, 255]) : Data())
    }
  }
}
