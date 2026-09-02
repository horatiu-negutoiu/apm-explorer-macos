import AppKit
import SwiftUI

enum AboutFAQContent {
    static let title = "About / FAQ"
    static let message = "APM Explorer is a private, personal activity tracker "
        + "built to help you understand your activity over time - without "
        + "compromising your privacy."
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "Unknown"
    static let author = "Horatiu Negutoiu"
    static let authorWebsiteURL = URL(string: "https://horatiu.ca")!
    static let appWebsiteURL = URL(string: "https://apmx.horatiu.ca")!
    static let aboutFAQURL = appWebsiteURL.appendingPathComponent("about-faq")
}

struct AboutFAQView: View {
    static let contentWidth: CGFloat = 440
    static let contentHeight: CGFloat = 360

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(AboutFAQContent.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(AboutFAQContent.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Text("App Version: \(AboutFAQContent.appVersion)")

                Text("Author: \(AboutFAQContent.author)")

                HStack(spacing: 4) {
                    Text("Web:")
                    Link(
                        AboutFAQContent.authorWebsiteURL.absoluteString,
                        destination: AboutFAQContent.authorWebsiteURL
                    )
                }

                HStack(spacing: 4) {
                    Text("App website:")
                    Link(
                        AboutFAQContent.appWebsiteURL.absoluteString,
                        destination: AboutFAQContent.appWebsiteURL
                    )
                }
            }

            Button(AboutFAQContent.title) {
                openURL(AboutFAQContent.aboutFAQURL)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the About / FAQ page on the APM Explorer website")
        }
        .padding(32)
        .frame(
            width: Self.contentWidth,
            height: Self.contentHeight
        )
        .accessibilityIdentifier("aboutFAQ.window")
        .background(AboutFAQWindowAccessor())
    }
}

@MainActor
enum AboutFAQWindowPresenter {
    private static weak var aboutFAQWindow: NSWindow?

    static func show(using openWindow: OpenWindowAction) {
        openWindow(id: "about-faq")
        bringToFront()
    }

    static func register(_ window: NSWindow) {
        aboutFAQWindow = window
        bringToFront()
    }

    static func bringToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        aboutFAQWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutFAQWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> AboutFAQWindowObservingView {
        AboutFAQWindowObservingView()
    }

    func updateNSView(_ nsView: AboutFAQWindowObservingView, context: Context) {}
}

@MainActor
private final class AboutFAQWindowObservingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AboutFAQWindowPresenter.register(window)
    }
}
