import XCTest

/// Runs against the installed debug app and the simulator's Safari.
/// No login credentials or production account are required.
final class SharingUITests: XCTestCase {
  private func chooseLanguage(_ language: String, app: XCUIApplication) {
    app.activate()
    let menu = app.buttons.matching(NSPredicate(format:
      "label IN {'应用语言', 'App language'}")).firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 20), app.debugDescription)
    menu.tap()
    let labels: [String: String] = [
      "en": "label == 'English'",
      "zh": "label IN {'简体中文', '简体中文 (Chinese)'}",
      "system": "label IN {'跟随系统', 'Follow system'}",
    ]
    let option = app.descendants(matching: .any)
      .matching(NSPredicate(format: labels[language]!)).firstMatch
    XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
    option.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: option)
    waitForExpectations(timeout: 10)
  }

  func testLanguageChangesReachShareExtension() throws {
    continueAfterFailure = false
    let original = ProcessInfo.processInfo.environment["GEMSNOTE_RESTORE_LANGUAGE"] ?? ""
    XCTAssertTrue(["system", "zh", "en"].contains(original))
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")
    app.launch()
    defer { chooseLanguage(original, app: app) }
    let source = XCUIApplication(bundleIdentifier: "com.github.gemsnote.SharingFixture")
    for language in ["en", "zh", "en"] {
      chooseLanguage(language, app: app)
      // Relaunch the main process, then open a separately hosted extension.
      app.terminate()
      app.launch()
      let expectedMenu = language == "zh" ? "应用语言" : "App language"
      XCTAssertTrue(app.buttons[expectedMenu].waitForExistence(timeout: 20))
      let id = UUID().uuidString.lowercased()
      print("SHARE_LANGUAGE_ID=\(id)")
      source.launchArguments = ["-fixture-id", id, "-invalid-file", "NO"]
      source.launch()
      let share = source.buttons["Share image and file"]
      XCTAssertTrue(share.waitForExistence(timeout: 20))
      share.tap()
      let gemsnote = source.staticTexts.matching(NSPredicate(format: "label IN {'Gemsnote', '珠玑笔记'}")).firstMatch
      XCTAssertTrue(gemsnote.waitForExistence(timeout: 20), source.debugDescription)
      gemsnote.tap()
      let save = source.buttons[language == "zh" ? "保存" : "Save"]
      let cancel = source.buttons[language == "zh" ? "取消" : "Cancel"]
      XCTAssertTrue(save.waitForExistence(timeout: 20), source.debugDescription)
      XCTAssertTrue(cancel.exists)
      expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
      waitForExpectations(timeout: 20)
      let hint = language == "zh"
        ? "保存后，请打开 Gemsnote 选择账号和笔记本完成导入"
        : "After saving, open Gemsnote and choose an account and notebook to import."
      XCTAssertTrue(source.staticTexts[hint].exists, source.debugDescription)
      cancel.tap()
      expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
      waitForExpectations(timeout: 20)
      source.terminate()
    }
  }

  func testImageAndFileBatch() throws {
    continueAfterFailure = false
    let id = UUID().uuidString.lowercased()
    print("SHARE_BATCH_ID=\(id)")
    let source = XCUIApplication(bundleIdentifier: "com.github.gemsnote.SharingFixture")
    source.launchArguments = ["-fixture-id", id, "-invalid-file", "NO"]
    source.launch()
    let share = source.buttons["Share image and file"]
    XCTAssertTrue(share.waitForExistence(timeout: 20))
    share.tap()
    let gemsnote = source.staticTexts.matching(NSPredicate(format: "label IN {'Gemsnote', '珠玑笔记'}")).firstMatch
    XCTAssertTrue(gemsnote.waitForExistence(timeout: 20), source.debugDescription)
    gemsnote.tap()
    let save = source.buttons.matching(NSPredicate(format: "label IN {'保存', 'Save'}")).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 20), source.debugDescription)
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
    waitForExpectations(timeout: 20)
    let preview = XCTAttachment(screenshot: source.screenshot())
    preview.lifetime = .keepAlways
    add(preview)
    save.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
    waitForExpectations(timeout: 20)
    XCTAssertFalse(source.alerts.firstMatch.exists, source.debugDescription)
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
  }

  func testInvalidFileRejectsEntireBatch() throws {
    continueAfterFailure = false
    let id = UUID().uuidString.lowercased()
    print("SHARE_INVALID_ID=\(id)")
    let source = XCUIApplication(bundleIdentifier: "com.github.gemsnote.SharingFixture")
    source.launchArguments = ["-fixture-id", id, "-invalid-file", "YES"]
    source.launch()
    let share = source.buttons["Share image and file"]
    XCTAssertTrue(share.waitForExistence(timeout: 20))
    share.tap()
    let gemsnote = source.staticTexts.matching(NSPredicate(format: "label IN {'Gemsnote', '珠玑笔记'}")).firstMatch
    XCTAssertTrue(gemsnote.waitForExistence(timeout: 20), source.debugDescription)
    gemsnote.tap()
    let alert = source.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 20), source.debugDescription)
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format:
      "label IN {'未保存分享', 'Share not saved'}")).firstMatch.exists)
    alert.buttons.firstMatch.tap()
    let save = source.buttons.matching(NSPredicate(format: "label IN {'保存', 'Save'}")).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 20), source.debugDescription)
    XCTAssertFalse(save.isEnabled)
    let cancel = source.buttons.matching(NSPredicate(format: "label IN {'取消', 'Cancel'}")).firstMatch
    XCTAssertTrue(cancel.isEnabled)
    cancel.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
    waitForExpectations(timeout: 20)
  }

  func testSafariShareToGemsnote() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.github.gemsnote")
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.launch()
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30))
    let address = safari.textFields["TabBarItemTitle"]
    XCTAssertTrue(address.waitForExistence(timeout: 20))
    address.tap()
    let url = "http://127.0.0.1:8765/#gemsnote-ui-\(UUID().uuidString.lowercased())"
    print("SHARE_FIXTURE_URL=\(url)")
    let input = safari.searchFields.firstMatch.exists
      ? safari.searchFields.firstMatch : safari.textFields.firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.typeText(url + "\n")
    let more = safari.buttons.matching(NSPredicate(format: "label == '更多' OR label == 'More'")).firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 30))
    more.tap()
    let share = safari.buttons.matching(NSPredicate(format: "label IN {'分享', '共享', 'Share'}")).firstMatch
    if !share.waitForExistence(timeout: 5) { more.tap() }
    XCTAssertTrue(share.waitForExistence(timeout: 10), safari.debugDescription)
    share.tap()
    let gemsnote = safari.staticTexts.matching(NSPredicate(format: "label IN {'Gemsnote', '珠玑笔记'}")).firstMatch
    XCTAssertTrue(gemsnote.waitForExistence(timeout: 20), safari.debugDescription)
    gemsnote.tap()
    let cancel = safari.buttons.matching(NSPredicate(format: "label IN {'取消', 'Cancel'}")).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 20), safari.debugDescription)
    cancel.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
    waitForExpectations(timeout: 20)
    // Cancellation must not persist a record. Reopen and save the same URL;
    // the host verifier requires exactly one record after this second attempt.
    if !gemsnote.waitForExistence(timeout: 3) {
      XCTAssertTrue(more.waitForExistence(timeout: 10))
      more.tap()
      XCTAssertTrue(share.waitForExistence(timeout: 10))
      share.tap()
    }
    XCTAssertTrue(gemsnote.waitForExistence(timeout: 20))
    gemsnote.tap()
    let save = safari.buttons.matching(NSPredicate(format: "label IN {'保存', 'Save'}")).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 20), safari.debugDescription)
    let enabled = NSPredicate(format: "enabled == true")
    expectation(for: enabled, evaluatedWith: save)
    waitForExpectations(timeout: 20)
    save.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
    waitForExpectations(timeout: 20)
    XCTAssertFalse(safari.alerts.firstMatch.exists, safari.debugDescription)
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
