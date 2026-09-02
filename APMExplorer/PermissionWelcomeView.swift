import AppKit
import Combine
import SwiftUI

@MainActor
final class PermissionWelcomeWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var initialCheckObservation: AnyCancellable?
    private let onCompletion: () -> Void

    init(capture: PassiveInputCaptureModel, onCompletion: @escaping () -> Void = {}) {
        self.onCompletion = onCompletion
        super.init()
        // Subscribe outside the menu's lazy SwiftUI hierarchy. The published
        // snapshot also handles a check that finished before app launch did.
        initialCheckObservation = capture.$initialPermissionState
            .compactMap { $0 }
            .first()
            .sink { [weak self] state in
                guard state != .granted, capture.permissionState != .granted else {
                    self?.onCompletion()
                    return
                }
                self?.show(capture: capture)
            }
    }

    func close() {
        initialCheckObservation?.cancel()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onCompletion()
    }

    private func show(capture: PassiveInputCaptureModel) {
        let view = PermissionWelcomeView(capture: capture) { [weak self] in
            self?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to APM Explorer"
        window.identifier = NSUserInterfaceItemIdentifier("permission.welcome")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct PermissionWelcomeView: View {
    @ObservedObject var capture: PassiveInputCaptureModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("APM Explorer", image: "MenuBarIcon")
                .font(.headline)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            if capture.permissionState != .invalidCodeSignature && capture.permissionState != .granted {
                Text("In System Settings, go to Privacy & Security → Input Monitoring and enable APM Explorer. Status updates automatically when you return.")
                    .foregroundStyle(.secondary)
            }

            Label(
                RecordingStatusPresentation(
                    permission: capture.permissionState,
                    capture: capture.captureState,
                    persistence: capture.persistenceState
                ).title,
                systemImage: capture.metricsAreAvailable ? "checkmark.circle.fill" : capture.permissionState.symbolName
            )
            .accessibilityIdentifier("permission.welcome.status")

            Text("Activity is collected only while monitoring is running. Earlier activity cannot be recovered.")
                .font(.callout)
                .foregroundStyle(.secondary)

            DisclosureGroup("What APM Explorer observes and stores") {
                PermissionOnboardingContent(capture: capture)
                    .padding(.top, 8)
            }

            if capture.settingsOpenFailed {
                Text("System Settings could not be opened. Open Privacy & Security → Input Monitoring manually.")
                    .foregroundStyle(.red)
            }
            if capture.relaunchFailed {
                Text("APMX could not relaunch automatically. Quit and open it again.")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if capture.permissionState == .granted {
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Closes this welcome window. Setup remains available in the menu bar and Settings.")
                    primaryAction
                }
            }
        }
        .padding(32)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("permission.welcome.content")
    }

    private var title: String {
        switch capture.permissionState {
        case .notDetermined: "Welcome to APM Explorer!"
        case .denied, .revoked: "Enable activity analytics"
        case .relaunchRequired: "Relaunch to start monitoring"
        case .invalidCodeSignature: "A signed build is required"
        case .granted: "Input Monitoring is enabled"
        }
    }

    private var message: String {
        switch capture.permissionState {
        case .notDetermined:
            "Thanks for using APM Explorer! Enable Input Monitoring to turn your keyboard, mouse clicks, and scrolling activity into analytics. What you type is never recorded, and your data stays on your Mac."
        case .denied, .revoked:
            "APM Explorer needs Input Monitoring to collect activity for analytics. Enable access in System Settings whenever you’re ready. What you type is never recorded, and your data stays on your Mac."
        case .relaunchRequired:
            "macOS accepted access, but this copy of APMX must relaunch before monitoring can begin."
        case .invalidCodeSignature:
            "This build has no stable Apple code identity. Launch a development- or distribution-signed copy before granting access."
        case .granted:
            "Permission is ready. Recording starts automatically when capture and local storage are available. You can view your activity from the menu bar."
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch capture.permissionState {
        case .notDetermined:
            Button("Enable Input Monitoring") { capture.requestAccess() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Displays the macOS Input Monitoring permission request")
        case .denied, .revoked:
            Button("Open Input Monitoring Settings") { capture.openInputMonitoringSettings() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens Privacy and Security Input Monitoring")
        case .relaunchRequired:
            Button("Relaunch APMX") { capture.relaunch() }
                .keyboardShortcut(.defaultAction)
        case .invalidCodeSignature, .granted:
            EmptyView()
        }
    }
}
