import XCTest

final class Clauto_EditorUITests: XCTestCase {
    @MainActor
    func testCreateProjectPersistsBriefWithoutAccounts() async throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-ui-\(UUID())")
        let suite = "clauto-ui-\(UUID())"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["CLAUTO_PROJECTS_ROOT"] = root.path
        app.launchEnvironment["CLAUTO_DEFAULTS_SUITE"] = suite
        defer {
            app.terminate()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        XCTAssertTrue(app.buttons["New Project"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["New Project"].firstMatch.click()
        let name = app.textFields["projectName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Synthetic pizza")
        app.buttons["createProject"].click()
        let about = app.textViews["briefAbout"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click(); about.typeText("Synthetic footage only.")
        let saved = NSPredicate { _, _ in
            guard let project = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first,
                  let text = try? String(contentsOf: project.appendingPathComponent("brief.md"), encoding: .utf8) else { return false }
            return text.contains("Synthetic footage only.")
        }
        let expectation = expectation(for: saved, evaluatedWith: nil)
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertFalse(app.buttons["Save Request"].isEnabled)
    }
}
