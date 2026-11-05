import XCTest
final class OutboundUITests: XCTestCase {
  func testTextAndFilesReachReceiver() throws {
    continueAfterFailure = false
    let run = ProcessInfo.processInfo.environment["OUTBOUND_SHARE_RUN"]!
    let host = XCUIApplication(bundleIdentifier: "com.github.gemsnote.ReceiverHost")
    host.launch()
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")
    app.launch()
    for kind in ["md", "html", "binary", "empty"] {
      let share = app.buttons["Share \(kind)"]
      XCTAssertTrue(share.waitForExistence(timeout: 20), app.debugDescription)
      share.tap()
      let receiver = app.staticTexts["ReceiverHost"]
      XCTAssertTrue(receiver.waitForExistence(timeout: 20), app.debugDescription)
      receiver.tap()
      let receipt = app.staticTexts["share-receipt"]
      XCTAssertTrue(receipt.waitForExistence(timeout: 20), app.debugDescription)
      expectation(for: NSPredicate(format: "label != 'Loading'"), evaluatedWith: receipt)
      waitForExpectations(timeout: 20)
      let value = try JSONSerialization.jsonObject(with: Data(receipt.label.utf8)) as! [String: String]
      XCTAssertNil(value["error"], receipt.label)
      if kind == "md" || kind == "html" {
        let body = kind == "md" ? "# 原文 📝\n\n**不截断**" : "<p>原文 &amp; emoji 📝</p>"
        XCTAssertEqual(value, ["text": "share-\(run)-\(kind)\n\n\(body)"])
      } else {
        let name = kind == "binary" ? "share-\(run)-附件_.bin" : "share-\(run)-empty.bin"
        XCTAssertEqual(value["name"], name)
        XCTAssertEqual(Data(base64Encoded: value["bytes"]!), kind == "binary" ? Data([0, 1, 127, 128, 255]) : Data())
      }
      app.buttons["Close receiver"].tap()
      XCTAssertTrue(app.staticTexts["Returned \(kind)"].waitForExistence(timeout: 20), app.debugDescription)
    }
    app.buttons["Share md"].tap()
    let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', '关闭', 'Cancel', '取消'}")).firstMatch
    if close.waitForExistence(timeout: 3) { close.tap() }
    else {
      let sheet = app.otherElements["ActivityListView"].firstMatch
      XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
      // This compact system panel dismisses by tapping its backdrop.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
      expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)
      waitForExpectations(timeout: 10)
    }
    XCTAssertTrue(app.staticTexts["Returned md"].waitForExistence(timeout: 20), app.debugDescription)
  }
}
