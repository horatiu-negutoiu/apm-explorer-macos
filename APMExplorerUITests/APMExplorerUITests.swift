import XCTest
import Security

@MainActor
final class APMExplorerUITests: XCTestCase {
    func testLoginStartupOfferFollowsActivitySetupAndCanBeSkipped() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-settings.hasCompletedLaunchAtLoginOnboarding", "NO"]
        defer { application.terminate() }
        application.launch()

        let welcome = application.windows["Welcome to APM Explorer"]
        let loginWelcome = application.windows["Start at Login"]
        if welcome.waitForExistence(timeout: 5) {
            XCTAssertFalse(loginWelcome.exists)
            welcome.buttons["Not Now"].click()
        }

        guard loginWelcome.waitForExistence(timeout: 5) else {
            // Login items belong to the real signed installation. Confirm
            // that an absent offer is the expected already-enabled case.
            application.menuBars.statusItems.firstMatch.click()
            let settingsButton = application.buttons["Settings…"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
            settingsButton.click()
            let loginToggle = application.checkBoxes["Launch APM Explorer at login"]
            if loginToggle.waitForExistence(timeout: 5), loginToggle.value as? String == "1" {
                throw XCTSkip("Launch at login is already enabled for this installation")
            }
            XCTFail("Expected the login startup offer after activity setup")
            return
        }
        XCTAssertTrue(
            loginWelcome.buttons["Enable"].exists
                || loginWelcome.buttons["Open Login Items Settings"].exists
        )
        let screenshot = XCTAttachment(screenshot: loginWelcome.screenshot())
        screenshot.name = "Start at Login onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        loginWelcome.buttons["Not Now"].click()
        XCTAssertFalse(loginWelcome.exists)
        application.activate()
        XCTAssertFalse(loginWelcome.waitForExistence(timeout: 2))
    }

    func testPrivacyWindowDisplaysClickablePolicyURL() {
        let application = XCUIApplication()
        application.launchArguments = ["-settings.hasCompletedLaunchAtLoginOnboarding", "YES"]
        defer { application.terminate() }
        application.launch()

        let welcome = application.windows["Welcome to APM Explorer"]
        if welcome.waitForExistence(timeout: 5) {
            welcome.buttons["Not Now"].click()
        }

        application.menuBars.statusItems.firstMatch.click()
        let privacyMenuItem = application.buttons["privacy.menuItem"]
        XCTAssertTrue(privacyMenuItem.waitForExistence(timeout: 5))
        privacyMenuItem.click()

        let privacyWindow = application.windows["Privacy"]
        XCTAssertTrue(privacyWindow.waitForExistence(timeout: 5))
        let policyLink = privacyWindow.links.firstMatch
        XCTAssertTrue(policyLink.waitForExistence(timeout: 5))
        XCTAssertEqual(policyLink.label, "https://apmx.horatiu.ca/privacy/")
        XCTAssertTrue(policyLink.isHittable)
    }

    func testStartupWelcomeAndDismissalSurvivesActivation() throws {
        // Normal test builds sign the app and runner together. An unsigned
        // build must always show help; signed, authorized launches may omit it.
        var code: SecCode?
        var information: CFDictionary?
        SecCodeCopySelf([], &code)
        if let code {
            var staticCode: SecStaticCode?
            SecCodeCopyStaticCode(code, [], &staticCode)
            if let staticCode {
                SecCodeCopySigningInformation(
                    staticCode,
                    SecCSFlags(rawValue: kSecCSSigningInformation),
                    &information
                )
            }
        }
        let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String]
        let application = XCUIApplication()
        application.launchArguments = ["-settings.hasCompletedLaunchAtLoginOnboarding", "YES"]
        defer { application.terminate() }
        application.launch()

        let welcome = application.windows["Welcome to APM Explorer"]
        let welcomeAppeared = welcome.waitForExistence(timeout: 5)
        if team != nil && !welcomeAppeared {
            throw XCTSkip("Already authorized signed launches have no startup welcome")
        }
        XCTAssertTrue(welcomeAppeared)
        if team == nil {
            XCTAssertTrue(welcome.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Unsigned build", "Unsigned build")
            ).firstMatch.exists)
            XCTAssertFalse(welcome.buttons["Enable Input Monitoring"].exists)
        }
        welcome.buttons["Not Now"].click()
        XCTAssertFalse(welcome.exists)

        application.activate()
        XCTAssertFalse(welcome.waitForExistence(timeout: 2))
        XCTAssertTrue(application.menuBars.statusItems.firstMatch.exists)
    }

    func testMenuBarAgentLaunches() {
        let application = XCUIApplication()
        defer { application.terminate() }

        application.launch()

        let isRunning = application.wait(for: .runningBackground, timeout: 5)
            || application.wait(for: .runningForeground, timeout: 1)
        XCTAssertTrue(isRunning)
    }
}
