import AppKit
import APMXCore
import SwiftUI

struct PermissionOnboardingContent: View {
    @ObservedObject var capture: PassiveInputCaptureModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Label(
                capture.permissionState.title,
                systemImage: capture.permissionState.symbolName
            )
            .font(.headline)
            .foregroundStyle(permissionColor)
            .accessibilityLabel(
                "Input Monitoring permission: \(capture.permissionState.title)"
            )

            Text("APMX observes only physical key downs, mouse-button downs, and reduced scroll gestures or bursts.")

            Text("Individual inputs, typed content, pointer location, app/window identity, and clipboard data are never recorded. Privacy-safe session summaries remain locally for 48 hours; hourly action and monitoring totals remain for 60 days.")
                .foregroundStyle(.secondary)

            if capture.permissionState == .relaunchRequired {
                Text("macOS accepted access, but this copy of APMX must relaunch before monitoring can begin.")
                    .foregroundStyle(.secondary)
            } else if capture.permissionState == .invalidCodeSignature {
                Text("This build has no stable Apple code identity. Launch a development- or distribution-signed copy before granting access.")
                    .foregroundStyle(.secondary)
            } else if capture.permissionState == .denied || capture.permissionState == .revoked {
                Text("APMX remains usable. Allow it in System Settings whenever you want metrics to resume.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(compact ? .caption : .body)
    }

    private var permissionColor: Color {
        capture.permissionState == .granted ? .green : .orange
    }
}

struct PermissionActions: View {
    enum Layout {
        case horizontal
        case vertical
    }

    @ObservedObject var capture: PassiveInputCaptureModel
    var layout: Layout = .horizontal

    var body: some View {
        if layout == .vertical {
            VStack(alignment: .leading, spacing: 8) {
                actions
            }
        } else {
            HStack {
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Allow Input Monitoring") {
            capture.requestAccess()
        }
        .disabled(!capture.permissionState.canRequestSystemPrompt)
        .accessibilityHint("Displays the macOS permission request once")
        .accessibilityIdentifier("permission.allow")

        Button("Open System Settings") {
            capture.openInputMonitoringSettings()
        }
        .accessibilityHint("Opens Privacy and Security Input Monitoring")
        .accessibilityIdentifier("permission.openSettings")

        Button("Check Again") {
            capture.refresh()
        }
        .accessibilityHint("Checks permission without displaying a system prompt")
        .accessibilityIdentifier("permission.checkAgain")

        if capture.permissionState == .relaunchRequired {
            Button("Relaunch APMX") {
                capture.relaunch()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("permission.relaunch")
        }
    }
}

enum ActivityStripFill: Equatable {
    case unavailable
    case unmonitored
    case monitoredZero
    case activity(Double)
    case maximum
}

struct ActivityStripCellPresentation: Equatable, Identifiable {
    let hourStart: WallClockInstant
    let hour: Int
    let actionCount: Int64?
    let actionsPerMinute: Double?
    let coverage: MonitoringCoverage
    let intensity: Double
    let isCurrentHour: Bool
    let fill: ActivityStripFill
    let accessibilityLabel: String

    var id: WallClockInstant { hourStart }
    var helpText: String { accessibilityLabel }
}

struct ActivityStripPresentation: Equatable {
    let cells: [ActivityStripCellPresentation]

    init(
        hours: [RollingHourlyAnalyticsCell]?,
        now: WallClockInstant,
        timeZone: TimeZone
    ) {
        let analyticsCells = hours ?? (try? HourlyAnalytics.rollingHours(
            from: [],
            now: now,
            timeZone: timeZone
        )) ?? []
        cells = analyticsCells.enumerated().map { index, analytics in
            let actionCount = analytics.actionCount
            let actionsPerMinute = analytics.actionsPerMinute
            let coverage = analytics.coverage
            let intensity = analytics.intensity
            let isCurrentHour = index == analyticsCells.count - 1
            return ActivityStripCellPresentation(
                hourStart: analytics.hourStart,
                hour: analytics.hour,
                actionCount: actionCount,
                actionsPerMinute: actionsPerMinute,
                coverage: coverage,
                intensity: intensity,
                isCurrentHour: isCurrentHour,
                fill: Self.fill(
                    actionCount: actionCount,
                    coverage: coverage,
                    intensity: intensity
                ),
                accessibilityLabel: Self.accessibilityLabel(
                    hourStart: analytics.hourStart,
                    hour: analytics.hour,
                    actionCount: actionCount,
                    actionsPerMinute: actionsPerMinute,
                    coverage: coverage,
                    isCurrentHour: isCurrentHour,
                    timeZone: timeZone
                )
            )
        }
    }

    private static func fill(
        actionCount: Int64?,
        coverage: MonitoringCoverage,
        intensity: Double
    ) -> ActivityStripFill {
        switch coverage {
        case .unavailable:
            return .unavailable
        case .zero:
            return .unmonitored
        case .partial, .complete:
            guard let actionCount, actionCount > 0 else {
                return .monitoredZero
            }
            if intensity >= 1 { return .maximum }
            return .activity(intensity)
        }
    }

    private static func accessibilityLabel(
        hourStart: WallClockInstant,
        hour: Int,
        actionCount: Int64?,
        actionsPerMinute: Double?,
        coverage: MonitoringCoverage,
        isCurrentHour: Bool,
        timeZone: TimeZone
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy")
        let dateDescription = dateFormatter.string(
            from: hourStart.date.addingTimeInterval(30 * 60)
        )
        let hourDescription = String(format: "Local hour %02d:00 to %02d:59", hour, hour)
        let activityDescription: String
        if let actionCount, let actionsPerMinute {
            activityDescription = "\(actionCount.formatted()) actions, \(formatAPM(actionsPerMinute)) hourly APM"
        } else {
            activityDescription = "action count unavailable, hourly APM unavailable"
        }
        let coverageDescription = switch coverage {
        case .unavailable: "coverage unavailable"
        case .zero: "not monitored"
        case .partial: "partial monitoring coverage"
        case .complete: "complete monitoring coverage"
        }
        let currentDescription = isCurrentHour ? ", current hour" : ""
        return "\(dateDescription), \(hourDescription), \(activityDescription), "
            + "\(coverageDescription)\(currentDescription)"
    }

    private static func formatAPM(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(value == value.rounded() ? 0 : 2))
        )
    }
}

struct ActivityStripRowLayout: Layout {
    let spacing: CGFloat

    static func cellSide(
        availableWidth: CGFloat,
        cellCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        guard cellCount > 0 else { return 0 }
        let totalSpacing = CGFloat(cellCount - 1) * spacing
        return max(0, (availableWidth - totalSpacing) / CGFloat(cellCount))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let fallbackSide = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let availableWidth = proposal.width
            ?? (fallbackSide * CGFloat(subviews.count))
            + (spacing * CGFloat(subviews.count - 1))
        let side = Self.cellSide(
            availableWidth: availableWidth,
            cellCount: subviews.count,
            spacing: spacing
        )
        return CGSize(width: availableWidth, height: side)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let side = Self.cellSide(
            availableWidth: bounds.width,
            cellCount: subviews.count,
            spacing: spacing
        )
        var x = bounds.minX
        let y = bounds.midY - (side / 2)
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: side, height: side)
            )
            x += side + spacing
        }
    }
}

private struct ActivityStripView: View {
    let presentation: ActivityStripPresentation

    var body: some View {
        ActivityStripRowLayout(spacing: 2) {
            ForEach(presentation.cells) { cell in
                ActivityStripCell(cell: cell)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.strip")
        .accessibilityLabel("Last 12 hours of activity")
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct ActivityStripCell: View {
    let cell: ActivityStripCellPresentation

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(0.55), lineWidth: 0.75)
            }
            .overlay(alignment: .bottom) {
                if cell.isCurrentHour {
                    Capsule()
                        .fill(currentIndicatorColor)
                        .frame(width: 5, height: 2)
                        .padding(.bottom, 1)
                }
            }
            .overlay {
                if cell.isCurrentHour {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(currentIndicatorColor, lineWidth: 1.5)
                }
            }
            .help(cell.helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cell.accessibilityLabel)
            .accessibilityIdentifier("activity.hour.\(cell.hourStart.epochMilliseconds)")
    }

    private var fillColor: Color {
        switch cell.fill {
        case .unavailable:
            Color.clear
        case .unmonitored:
            Color.secondary.opacity(0.28)
        case .monitoredZero:
            Color.black
        case .activity(let intensity):
            Color.green.opacity(0.3 + (0.7 * min(max(intensity, 0), 1)))
        case .maximum:
            Color.white
        }
    }

    private var currentIndicatorColor: Color {
        switch cell.fill {
        case .maximum:
            Color.black
        case .monitoredZero:
            Color.white
        case .unavailable, .unmonitored, .activity:
            Color.primary
        }
    }
}

struct RecordingStatusPresentation: Equatable {
    let title: String

    init(
        permission: InputMonitoringPermissionState,
        capture: PassiveCaptureState,
        persistence: ActivityPersistenceState
    ) {
        if persistence != .available {
            title = persistence.title
        } else if permission != .granted {
            title = permission.title
        } else {
            title = switch capture {
            case .listening: "Allowed · Listening"
            case .waitingForPermission: "Waiting for Input Monitoring permission"
            case .suspended: "Recording suspended"
            case .unavailable: "Event tap unavailable"
            }
        }
    }
}

struct StatusMenuContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var capture: PassiveInputCaptureModel
    let logger: any ApplicationLogging

    private var stripPresentation: ActivityStripPresentation {
        let snapshot = capture.hourlyVisualizationSnapshot
        return ActivityStripPresentation(
            hours: snapshot?.rollingHours,
            now: snapshot?.displayedAt ?? SystemWallClock().now(),
            timeZone: .autoupdatingCurrent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metricsHeader
            Divider()
                .padding(.horizontal, 12)
            actions
        }
        .frame(width: 270)
    }

    private var metricsHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Last 12 hours")
                    .font(.headline)
            }
            ActivityStripView(presentation: stripPresentation)
            Label(
                recordingStatus,
                systemImage: capture.metricsAreAvailable
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(capture.metricsAreAvailable ? .green : .orange)
            .font(.caption)
            .accessibilityLabel("Recording status: \(recordingStatus)")
        }
        .padding(12)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if capture.permissionState != .granted {
                if capture.permissionState.canRequestSystemPrompt {
                    statusButton("Allow Input Monitoring") { capture.requestAccess() }
                }
                statusButton("Open Input Monitoring Settings") {
                    dismissThenOpenInputMonitoringSettings()
                }
                statusButton("Check Permission Again") { capture.refresh() }
                if capture.permissionState == .relaunchRequired {
                    statusButton("Relaunch APMX") { capture.relaunch() }
                }
                Divider()
            }

            statusButton("Analytics", systemImage: "chart.xyaxis.line") {
                dismiss()
                DispatchQueue.main.async {
                    openWindow(id: "analytics")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            if #available(macOS 14.0, *) {
                AppSettingsMenuButton {
                    logger.record(.settingsRequested)
                    dismiss()
                }
                .keyboardShortcut(",", modifiers: .command)
            } else {
                statusButton("Settings", systemImage: "gearshape") {
                    logger.record(.settingsRequested)
                    dismiss()
                    DispatchQueue.main.async {
                        AppSettingsWindowPresenter.showLegacySettings()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            statusButton("Privacy", systemImage: "hand.raised") {
                dismiss()
                DispatchQueue.main.async {
                    PrivacyWindowPresenter.show(using: openWindow)
                }
            }
            .accessibilityIdentifier("privacy.menuItem")
            .accessibilityHint("Opens APM Explorer's privacy information")
            statusButton("About / FAQ", systemImage: "questionmark.circle") {
                dismiss()
                DispatchQueue.main.async {
                    AboutFAQWindowPresenter.show(using: openWindow)
                }
            }
            .accessibilityIdentifier("aboutFAQ.menuItem")
            .accessibilityHint("Opens APM Explorer's About / FAQ information")
            statusButton("Support this project", systemImage: "heart.fill") {
                dismiss()
                DispatchQueue.main.async {
                    openURL(URL(string: "https://buymeacoffee.com/horatiu.negutoiu")!)
                }
            }
            statusButton("Quit APMX", systemImage: "power") {
                logger.record(.quitRequested)
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }

    private func statusButton(
        _ title: String,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            statusRow(title, systemImage: systemImage)
        }
        .buttonStyle(StatusMenuRowButtonStyle())
    }

    private func statusRow(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 16)
            }
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func dismissThenOpenInputMonitoringSettings() {
        dismiss()
        DispatchQueue.main.async {
            capture.openInputMonitoringSettings()
        }
    }

    private var recordingStatus: String {
        RecordingStatusPresentation(
            permission: capture.permissionState,
            capture: capture.captureState,
            persistence: capture.persistenceState
        ).title
    }
}

@available(macOS 14.0, *)
private struct AppSettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings
    let prepareToOpen: () -> Void

    var body: some View {
        Button {
            prepareToOpen()
            DispatchQueue.main.async {
                openSettings()
                AppSettingsWindowPresenter.bringSettingsToFront()
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .frame(width: 16)
                Text("Settings")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMenuRowButtonStyle())
    }
}

@MainActor
private enum AppSettingsWindowPresenter {
    private static weak var settingsWindow: NSWindow?

    static func showLegacySettings() {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        application.sendAction(
            Selector(("showPreferencesWindow:")),
            to: nil,
            from: nil
        )
        bringSettingsToFront()
    }

    static func register(_ window: NSWindow) {
        settingsWindow = window
        activateAndFocusSettingsWindow()
    }

    static func bringSettingsToFront() {
        activateAndFocusSettingsWindow()
    }

    private static func activateAndFocusSettingsWindow() {
        let application = NSApplication.shared
        if #available(macOS 14.0, *) {
            application.activate()
        } else {
            application.activate(ignoringOtherApps: true)
        }
        guard let settingsWindow else { return }
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowObservingView {
        SettingsWindowObservingView()
    }

    func updateNSView(_ nsView: SettingsWindowObservingView, context: Context) {}
}

@MainActor
private final class SettingsWindowObservingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindowIfAvailable()
    }

    func registerWindowIfAvailable() {
        guard let window else { return }
        AppSettingsWindowPresenter.register(window)
    }
}

private struct StatusMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatusMenuRow(configuration: configuration)
    }

    private struct StatusMenuRow: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
            .padding(.horizontal, 8)
            .frame(height: 28)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background(
                isHighlighted ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .onHover { isHovering = $0 }
        }

        private var isHighlighted: Bool {
            isHovering || configuration.isPressed
        }
    }
}

struct SettingsView: View {
    @ObservedObject var capture: PassiveInputCaptureModel
    @ObservedObject var settings: AppSettingsModel
    @ObservedObject private var diagnostics: CaptureDiagnosticsModel
    @State private var confirmsActivityDeletion = false

    init(capture: PassiveInputCaptureModel, settings: AppSettingsModel) {
        _capture = ObservedObject(wrappedValue: capture)
        _settings = ObservedObject(wrappedValue: settings)
        _diagnostics = ObservedObject(wrappedValue: capture.diagnostics)
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch APM Explorer at login", isOn: Binding(
                    get: { settings.launchAtLoginIsOn },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                .accessibilityHint("Registers or unregisters APM Explorer as a macOS login item")

                LabeledContent("System status", value: settings.launchAtLoginState.detail)

                if settings.launchAtLoginState == .requiresApproval {
                    Button("Open Login Items Settings") {
                        settings.openLoginItemsSettings()
                    }
                    Text("macOS requires approval before APM Explorer can launch automatically.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Refresh Login Item Status") {
                    settings.refreshLaunchAtLoginState()
                }
                .accessibilityHint("Reads the current login-item status from macOS")
            }

            Section("Input Monitoring") {
                PermissionOnboardingContent(capture: capture)

                LabeledContent("Event tap") {
                    Text(capture.captureState.title)
                }

                PermissionActions(capture: capture)

                if capture.settingsOpenFailed {
                    Text("System Settings could not be opened. Open Privacy & Security → Input Monitoring manually.")
                        .foregroundStyle(.red)
                }

                if capture.relaunchFailed {
                    Text("APMX could not relaunch automatically. Quit and open it again.")
                        .foregroundStyle(.red)
                }

                Text("Checks never display a prompt. Allow Input Monitoring can display the macOS prompt only for a previously undetermined installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Aggregate activity counters") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    counterRow("Physical key down", diagnostics.activity.keyDownCount)
                    counterRow("Mouse button down", diagnostics.activity.mouseButtonDownCount)
                    counterRow("Scroll gesture or burst", diagnostics.activity.scrollWheelCount)
                }

                Text("Activity is reduced before counting. Key repeats and scroll momentum are ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Event-tap recovery") {
                metric("Disable notifications", diagnostics.activity.tapDisabledCount)
                metric("Successful re-enables", diagnostics.activity.tapReenabledCount)
                metric("Dropped signals", diagnostics.activity.droppedSignalCount)
            }

            Section("Privacy and data") {
                if capture.persistenceState != .available {
                    Label(capture.persistenceState.title, systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red)
                    Text(capture.persistenceError ?? "The activity database is unavailable. Recording is paused and the existing database has been preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Resolve the storage or access problem, then relaunch APM Explorer to retry. No local activity data is deleted automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("APM Explorer observes only physical key downs, mouse-button downs, and reduced scroll gestures or bursts. It stores privacy-safe session summaries plus UTC hour boundaries with aggregate action counts and monitoring duration. It never stores keys, typed content, pointer locations, app or window identity, clipboard data, or individual input events.")

                Text("Activity data remains only on this Mac. Session summaries are retained for 48 hours and hourly aggregates for 60 days. Preferences contain only the login-item state—never activity payloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Delete Activity Data", role: .destructive) {
                    confirmsActivityDeletion = true
                }
                .disabled(settings.isDeletingActivityData)
                .accessibilityHint("Permanently deletes local metrics and session history but keeps preferences")

                if settings.isDeletingActivityData {
                    ProgressView("Deleting activity data…")
                }
                if let error = settings.deletionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 820)
        .background(SettingsWindowAccessor())
        .confirmationDialog(
            "Delete all activity data?",
            isPresented: $confirmsActivityDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Activity Data", role: .destructive) {
                settings.deleteActivityData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears counters and session history. Your preferences will be kept.")
        }
    }

    @ViewBuilder
    private func counterRow(_ title: String, _ count: UInt64) -> some View {
        GridRow {
            Text(title)
            metricValue(count)
        }
    }

    @ViewBuilder
    private func metric(_ title: String, _ count: UInt64) -> some View {
        LabeledContent(title) {
            metricValue(count)
        }
    }

    private func metricValue(_ count: UInt64) -> some View {
        Text(capture.metricsAreAvailable ? count.formatted() : "Unavailable")
            .monospacedDigit()
            .frame(minWidth: 80, alignment: .trailing)
    }

}

#Preview {
    let capture = PassiveInputCaptureModel(startsAutomatically: false)
    SettingsView(
        capture: capture,
        settings: AppSettingsModel(
            repository: PreviewSettingsRepository(),
            launchService: PreviewLaunchAtLoginService(),
            capture: capture
        )
    )
}

private final class PreviewSettingsRepository: AppSettingsPersisting, @unchecked Sendable {
    func load() -> AppSettings { .defaults }
    func save(_ settings: AppSettings) {}
}

@MainActor
private final class PreviewLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState = .off
    func setEnabled(_ enabled: Bool) { state = enabled ? .on : .off }
    func openSystemSettings() {}
}
