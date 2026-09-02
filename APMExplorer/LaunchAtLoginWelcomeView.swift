import AppKit
import Combine
import SwiftUI

@MainActor
final class StartupOnboardingWindowController: NSObject, NSWindowDelegate {
    private(set) var permissionWelcome: PermissionWelcomeWindowController?
    private(set) var launchAtLoginWindow: NSWindow?
    private let settings: AppSettingsModel
    private var permissionObservation: AnyCancellable?
    private var hasFinishedPermissionStep = false
    private var isClosing = false

    init(capture: PassiveInputCaptureModel, settings: AppSettingsModel) {
        self.settings = settings
        super.init()
        // Wait for a real check: the cached initial state can say revoked
        // even when access is still granted on an ordinary launch.
        permissionObservation = capture.$initialPermissionState
            .compactMap { $0 }
            .first()
            .flatMap { _ in capture.$permissionState }
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.settings.recordInputMonitoringPermission(state)
                if state == .granted, self.hasFinishedPermissionStep {
                    self.showLaunchAtLoginIfNeeded()
                }
            }
        permissionWelcome = PermissionWelcomeWindowController(capture: capture) { [weak self] in
            self?.hasFinishedPermissionStep = true
            self?.showLaunchAtLoginIfNeeded()
        }
    }

    // Termination closes windows without treating it as a setup choice.
    func close() {
        isClosing = true
        permissionObservation?.cancel()
        permissionWelcome?.close()
        launchAtLoginWindow?.close()
    }

    func enableLaunchAtLogin() {
        settings.setLaunchAtLogin(true)
        if settings.launchAtLoginIsOn {
            launchAtLoginWindow?.close()
        }
    }

    func refreshLaunchAtLogin() {
        guard launchAtLoginWindow?.isVisible == true else { return }
        settings.refreshLaunchAtLoginState()
        if settings.launchAtLoginIsOn {
            launchAtLoginWindow?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        settings.completeLaunchAtLoginOnboarding()
    }

    private func showLaunchAtLoginIfNeeded() {
        guard !isClosing, launchAtLoginWindow?.isVisible != true,
              !settings.hasCompletedLaunchAtLoginOnboarding else { return }
        settings.refreshLaunchAtLoginState()
        guard !settings.launchAtLoginIsOn else {
            settings.completeLaunchAtLoginOnboarding()
            return
        }

        let view = LaunchAtLoginWelcomeView(
            settings: settings,
            enable: { [weak self] in self?.enableLaunchAtLogin() },
            refresh: { [weak self] in self?.refreshLaunchAtLogin() },
            dismiss: { [weak self] in self?.launchAtLoginWindow?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Start at Login"
        window.identifier = NSUserInterfaceItemIdentifier("launchAtLogin.welcome")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        launchAtLoginWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct LaunchAtLoginWelcomeView: View {
    @ObservedObject var settings: AppSettingsModel
    let enable: () -> Void
    let refresh: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("APM Explorer", image: "MenuBarIcon")
                .font(.headline)
                .accessibilityHidden(true)

            Text("Start automatically at login?")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Let APM Explorer open in the menu bar when you log in to your Mac, so you don’t have to remember to open it. Activity analytics still requires Input Monitoring access.")
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("System status", value: settings.launchAtLoginState.detail)

            if settings.launchAtLoginState == .requiresApproval {
                Text("Allow APM Explorer in System Settings → General → Login Items. Status updates when you return.")
                    .foregroundStyle(.secondary)
            } else if settings.launchAtLoginState == .unavailable {
                Text("macOS couldn’t find the login item. You can try enabling it now, or set it up later in APM Explorer Settings.")
                    .foregroundStyle(.secondary)
            }

            if let error = settings.launchAtLoginError {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("You can change this anytime in Settings → Startup.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Skips this step. You can enable launch at login later in Settings.")
                if settings.launchAtLoginState == .requiresApproval {
                    Button("Open Login Items Settings") { settings.openLoginItemsSettings() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Enable", action: enable)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Registers APM Explorer to start automatically when you log in to your Mac")
                }
            }
        }
        .padding(32)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("launchAtLogin.welcome.content")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }
}
