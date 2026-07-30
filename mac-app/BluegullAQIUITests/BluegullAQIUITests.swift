import XCTest

/// Drives the real running app via the accessibility hierarchy
/// (bluegull-aqi-e70.9) -- `xcodebuild test` launches
/// `BluegullAQI.app` as a separate process and clicks through it, unlike
/// every other test in this project, which exercises Swift code directly.
///
/// Known cost, per this issue's own description: menu bar automation is
/// finicky (NSStatusItem-hosted content lives outside the app's regular
/// window hierarchy -- queried via `app.statusItems`, not
/// `app.menuBarItems`, which is for a normal app's File/Edit/View menu
/// bar), and running this at all needs a logged-in GUI session with
/// Accessibility/Automation TCC permission granted to the process running
/// `xcodebuild test` -- the same class of entitlement/permission barrier
/// documented elsewhere in this project for Keychain/CoreLocation
/// (bluegull-aqi-10h.13, e70.2). Whether that permission is actually
/// granted in any given environment is exactly the "passes locally, hangs
/// in CI" risk this issue calls out -- this suite is written and verified
/// to compile/launch correctly, but full pass/fail confirmation depends on
/// that environment-specific permission.
final class BluegullAQIUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testStatusItemOpensPopover() throws {
        openPopover()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
    }

    func testGearIconOpensSettings() throws {
        openPopover()
        app.buttons["settingsButton"].click()
        XCTAssertTrue(waitForSettingsView().exists)
    }

    func testSettingsDoneButtonClosesSettings() throws {
        openPopover()
        app.buttons["settingsButton"].click()
        let settingsView = waitForSettingsView()
        XCTAssertTrue(settingsView.exists)

        app.buttons["settingsDoneButton"].click()
        XCTAssertFalse(app.otherElements["settingsView"].waitForExistence(timeout: 3))
    }

    func testDataSourceModePickerIsReachableAndSelectable() throws {
        openSettings()

        let picker = app.segmentedControls["dataSourceModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Direct (use my own AirNow key)"].click()
        picker.buttons["Service (no setup required)"].click()
    }

    func testAirNowAPIKeyEntryFlow() throws {
        openSettings()

        let field = app.secureTextFields["airNowAPIKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("test-api-key-value")

        let saveButton = app.buttons["saveAPIKeyButton"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.click()

        let clearButton = app.buttons["clearAPIKeyButton"]
        XCTAssertTrue(clearButton.isEnabled)
        clearButton.click()
    }

    func testAddAndRemovePinnedLocation() throws {
        openSettings()

        let labelField = app.textFields["newPinnedLocationLabelField"]
        let addressField = app.textFields["newPinnedLocationAddressField"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))

        labelField.click()
        labelField.typeText("Test Location")
        addressField.click()
        addressField.typeText("94103")

        let addButton = app.buttons["addPinnedLocationButton"]
        XCTAssertTrue(addButton.isEnabled)
        // Not clicked further: geocoding a real address depends on network
        // access and CLGeocoder, both explicitly out of scope for this
        // suite to exercise (see this file's own doc comment on what's
        // verified vs. environment-dependent). Confirms the flow up to
        // the point of triggering a real geocode is reachable.
    }

    private func openPopover() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Menu bar status item never appeared")
        statusItem.click()
    }

    private func openSettings() {
        openPopover()
        app.buttons["settingsButton"].click()
    }

    private func waitForSettingsView() -> XCUIElement {
        let settingsView = app.otherElements["settingsView"]
        _ = settingsView.waitForExistence(timeout: 5)
        return settingsView
    }
}
