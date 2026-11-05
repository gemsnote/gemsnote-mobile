import XCTest

final class PickerUITests: XCTestCase {
  func testSourceAndArchiveRoundTrips() throws {
    continueAfterFailure = false
    let run = ProcessInfo.processInfo.environment["FILE_PICKER_RUN"]!
    let files = XCUIApplication(bundleIdentifier: "com.github.gemsnote.PickerFiles")
    files.launch()
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")
    app.launch()
    func tap(_ label: String) {
      let translated = ["Save": "保存", "Cancel": "取消"][label] ?? label
      let element = app.buttons.matching(NSPredicate(format:
        "label IN %@", [label, translated])).firstMatch
      XCTAssertTrue(element.waitForExistence(timeout: 20), app.debugDescription)
      element.tap()
    }
    func status(_ text: String) {
      XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 20), app.debugDescription)
    }
    func cancelPicker() {
      let cancel = app.buttons.matching(NSPredicate(format:
        "label IN {'Cancel', '取消'}")).firstMatch
      if cancel.waitForExistence(timeout: 2) {
        cancel.tap()
      } else {
        // iOS 26's export sheet has no Cancel button; dismiss its grabber.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        top.press(forDuration: 0.1, thenDragTo: bottom)
      }
    }
    for kind in ["md", "html", "gemsnote"] {
      tap("export \(kind)")
      let onDevice = app.staticTexts.matching(NSPredicate(format:
        "label IN {'On My iPhone', '我的iPhone'}")).firstMatch
      if onDevice.waitForExistence(timeout: 3) { onDevice.tap() }
      let folder = app.staticTexts["PickerFiles"]
      if folder.waitForExistence(timeout: 3) { folder.tap() }
      tap("Save")
      status("PASS export \(kind)")
      tap("import \(kind)")
      let file = app.cells.matching(NSPredicate(format:
        "label CONTAINS %@", "gemsnote-\(run)-\(kind)")).firstMatch
      XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
      XCTAssertTrue(file.isEnabled, app.debugDescription)
      file.tap()
      status("PASS import \(kind)")
    }
    tap("export md")
    cancelPicker()
    status("CANCEL export md")
    tap("import md")
    cancelPicker()
    status("CANCEL import md")
  }
}
