import XCTest

final class HomeFlowUITests: XCTestCase {
    func testHomeOpensNewProjectSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetState"]
        app.launch()

        let newProject = app.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 5))
        newProject.tap()

        XCTAssertTrue(app.staticTexts["New Watchface"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Create"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    func testCreateProjectAndOpenEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetState"]
        app.launch()

        app.buttons["New Project"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 3))
        app.buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["Untitled"].waitForExistence(timeout: 5))
        let addWidget = app.buttons["Add Widget"]
        XCTAssertTrue(addWidget.waitForExistence(timeout: 3))
        addWidget.tap()
        XCTAssertTrue(app.buttons["Digital Number"].waitForExistence(timeout: 3))
        app.buttons["Digital Number"].tap()
        XCTAssertTrue(app.staticTexts["Untitled"].exists)

        let export = app.buttons["mobile-export-button"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()
        let build = app.buttons["Build Compiled .bin"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        build.tap()
        XCTAssertTrue(app.buttons["Share Compiled .bin"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Install to Band"].exists)
        app.buttons["Install to Band"].tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 5))
    }
}
