import XCTest

@MainActor
final class APMExplorerUITests: XCTestCase {
    func testMenuBarAgentLaunches() {
        let application = XCUIApplication()
        defer { application.terminate() }

        application.launch()

        let isRunning = application.wait(for: .runningBackground, timeout: 5)
            || application.wait(for: .runningForeground, timeout: 1)
        XCTAssertTrue(isRunning)
    }
}
