import AppKit
import APMXCore
import SwiftUI

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var capture: PassiveInputCaptureModel?
    weak var settings: AppSettingsModel?
    private var startupOnboarding: StartupOnboardingWindowController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let capture, let settings else { return }
        startupOnboarding = StartupOnboardingWindowController(capture: capture, settings: settings)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let capture else { return .terminateNow }
        terminationPending = true
        startupOnboarding?.close()
        Task {
            await capture.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct APMExplorerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    private let dependencies: AppDependencies
    @StateObject private var capture: PassiveInputCaptureModel
    @StateObject private var settings: AppSettingsModel

    init() {
        let dependencies = AppDependencies.live()
        self.dependencies = dependencies
        let capture = PassiveInputCaptureModel(
            timeout: .oneMinute,
            activityRepository: dependencies.activityRepository,
            activityRepositoryError: dependencies.activityRepositoryError
        )
        _capture = StateObject(wrappedValue: capture)
        let settings = AppSettingsModel(
            repository: dependencies.settingsRepository,
            launchService: SMAppServiceLaunchAtLoginService(),
            capture: capture
        )
        _settings = StateObject(wrappedValue: settings)
        appDelegate.capture = capture
        appDelegate.settings = settings
        dependencies.logger.record(.applicationLaunched)
    }

    var body: some Scene {
        MenuBarExtra("APM Explorer", image: "MenuBarIcon") {
            StatusMenuContent(capture: capture, logger: dependencies.logger)
        }
        .menuBarExtraStyle(.window)
        .commands {
            PrivacyCommands()
        }

        Window("Analytics", id: "analytics") {
            AnalyticsView(capture: capture)
        }
        .defaultSize(
            width: AnalyticsView.contentWidth,
            height: AnalyticsView.contentHeight
        )
        .windowResizability(.contentSize)
        .commands {
            PrivacyCommands()
        }

        Window("Privacy", id: "privacy") {
            PrivacyView()
        }
        .defaultSize(
            width: PrivacyView.contentWidth,
            height: PrivacyView.contentHeight
        )
        .windowResizability(.contentSize)
        .commands {
            PrivacyCommands()
        }

        Window("About / FAQ", id: "about-faq") {
            AboutFAQView()
        }
        .defaultSize(
            width: AboutFAQView.contentWidth,
            height: AboutFAQView.contentHeight
        )
        .windowResizability(.contentSize)
        .commands {
            PrivacyCommands()
        }

        Settings {
            SettingsView(capture: capture, settings: settings)
        }
        .commands {
            PrivacyCommands()
        }
    }

}
