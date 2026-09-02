import AppKit
import SwiftUI

enum PrivacyDisclosure {
    static let title = "Your data stays on your Mac."
    static let message = "APM Explorer stores all user and application data "
        + "locally on your Mac. It does not transmit, upload, or otherwise "
        + "send that data online."
}

struct PrivacyView: View {
    static let contentWidth: CGFloat = 440
    static let contentHeight: CGFloat = 230

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(PrivacyDisclosure.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(PrivacyDisclosure.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(
            width: Self.contentWidth,
            height: Self.contentHeight
        )
        .accessibilityIdentifier("privacy.window")
        .background(PrivacyWindowAccessor())
    }
}

struct PrivacyCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Privacy") {
                PrivacyWindowPresenter.show(using: openWindow)
            }
            .accessibilityLabel("Privacy")
            .accessibilityHint("Opens APM Explorer's privacy information")
        }
    }
}

@MainActor
enum PrivacyWindowPresenter {
    private static weak var privacyWindow: NSWindow?

    static func show(using openWindow: OpenWindowAction) {
        openWindow(id: "privacy")
        bringToFront()
    }

    static func register(_ window: NSWindow) {
        privacyWindow = window
        bringToFront()
    }

    static func bringToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        privacyWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct PrivacyWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> PrivacyWindowObservingView {
        PrivacyWindowObservingView()
    }

    func updateNSView(_ nsView: PrivacyWindowObservingView, context: Context) {}
}

@MainActor
private final class PrivacyWindowObservingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        PrivacyWindowPresenter.register(window)
    }
}
