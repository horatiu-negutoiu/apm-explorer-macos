import APMXCore
import Foundation
import SwiftUI

enum AnalyticsLoadState: Equatable {
    case loading
    case loaded
    case persistenceUnavailable
    case storageError(String)
}

struct AnalyticsCellID: Hashable {
    let day: LocalCalendarDay
    let hour: Int
}

enum AnalyticsCellFill: Equatable {
    case unavailable
    case unmonitored
    case monitoredZero
    case activity(Double)
}

struct AnalyticsCellPresentation: Equatable, Identifiable {
    let id: AnalyticsCellID
    let actionCount: Int64?
    let actionsPerMinute: Double?
    let coverage: MonitoringCoverage
    let intensity: Double
    let fill: AnalyticsCellFill
    let isCurrentHour: Bool
    let dateLabel: String
    let hourLabel: String
    let activityLabel: String
    let coverageLabel: String
    let accessibilityLabel: String
    let accessibilityValue: String

    var helpText: String {
        "\(accessibilityLabel), \(accessibilityValue)"
    }
}

struct AnalyticsDayPresentation: Equatable, Identifiable {
    let day: LocalCalendarDay
    let shortDateLabel: String
    let fullDateLabel: String
    let cells: [AnalyticsCellPresentation]

    var id: LocalCalendarDay { day }
}

struct AnalyticsHistoryPresentation: Equatable {
    let days: [AnalyticsDayPresentation]
    let hasPositiveActivity: Bool

    init(
        days: [HourlyAnalyticsDay],
        now: WallClockInstant,
        timeZone: TimeZone
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentComponents = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: now.date
        )
        let currentDay = LocalCalendarDay(
            year: currentComponents.year!,
            month: currentComponents.month!,
            day: currentComponents.day!
        )
        let currentHour = currentComponents.hour!

        let shortFormatter = DateFormatter()
        shortFormatter.calendar = calendar
        shortFormatter.timeZone = timeZone
        shortFormatter.setLocalizedDateFormatFromTemplate("MMM d")
        let fullFormatter = DateFormatter()
        fullFormatter.calendar = calendar
        fullFormatter.timeZone = timeZone
        fullFormatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy")

        self.days = days.reversed().map { analyticsDay in
            let date = calendar.date(from: DateComponents(
                year: analyticsDay.day.year,
                month: analyticsDay.day.month,
                day: analyticsDay.day.day
            ))!
            let shortDate = shortFormatter.string(from: date)
            let fullDate = fullFormatter.string(from: date)
            let cells = analyticsDay.hours.map { cell in
                let hourRange = String(
                    format: "Local hour %02d:00 to %02d:59",
                    cell.hour,
                    cell.hour
                )
                let activity = Self.activityLabel(
                    actionCount: cell.actionCount,
                    actionsPerMinute: cell.actionsPerMinute
                )
                let coverage = Self.coverageLabel(cell.coverage)
                return AnalyticsCellPresentation(
                    id: AnalyticsCellID(day: analyticsDay.day, hour: cell.hour),
                    actionCount: cell.actionCount,
                    actionsPerMinute: cell.actionsPerMinute,
                    coverage: cell.coverage,
                    intensity: cell.intensity,
                    fill: Self.fill(cell),
                    isCurrentHour: analyticsDay.day == currentDay
                        && cell.hour == currentHour,
                    dateLabel: fullDate,
                    hourLabel: hourRange,
                    activityLabel: activity,
                    coverageLabel: coverage,
                    accessibilityLabel: "\(fullDate), \(hourRange)",
                    accessibilityValue: "\(activity), \(coverage)"
                )
            }
            return AnalyticsDayPresentation(
                day: analyticsDay.day,
                shortDateLabel: shortDate,
                fullDateLabel: fullDate,
                cells: cells
            )
        }
        hasPositiveActivity = days.lazy
            .flatMap(\.hours)
            .contains { ($0.actionCount ?? 0) > 0 }
    }

    func cell(id: AnalyticsCellID?) -> AnalyticsCellPresentation? {
        guard let id else { return nil }
        return days.first(where: { $0.day == id.day })?
            .cells.first(where: { $0.id == id })
    }

    private static func fill(_ cell: HourlyAnalyticsCell) -> AnalyticsCellFill {
        switch cell.coverage {
        case .unavailable:
            .unavailable
        case .zero:
            .unmonitored
        case .partial, .complete:
            if (cell.actionCount ?? 0) == 0 {
                .monitoredZero
            } else {
                .activity(cell.intensity)
            }
        }
    }

    private static func activityLabel(
        actionCount: Int64?,
        actionsPerMinute: Double?
    ) -> String {
        guard let actionCount, let actionsPerMinute else {
            return "Action count unavailable, hourly APM unavailable"
        }
        let actionWord = actionCount == 1 ? "action" : "actions"
        return "\(actionCount.formatted()) \(actionWord), \(formatAPM(actionsPerMinute)) hourly APM"
    }

    private static func coverageLabel(_ coverage: MonitoringCoverage) -> String {
        switch coverage {
        case .unavailable: "Coverage unavailable"
        case .zero: "Not monitored"
        case .partial: "Partial monitoring coverage"
        case .complete: "Complete monitoring coverage"
        }
    }

    private static func formatAPM(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(value == value.rounded() ? 0 : 2))
        )
    }
}

struct AnalyticsView: View {
    static let contentWidth: CGFloat = 720
    static let contentHeight: CGFloat = 560

    @ObservedObject var capture: PassiveInputCaptureModel
    @State private var selectedCell: AnalyticsCellID?
    @State private var hoveredCell: AnalyticsCellID?
    @FocusState private var focusedCell: AnalyticsCellID?

    private var presentation: AnalyticsHistoryPresentation {
        let snapshot = capture.hourlyVisualizationSnapshot
        return AnalyticsHistoryPresentation(
            days: snapshot?.analyticsDays ?? [],
            now: snapshot?.displayedAt ?? SystemWallClock().now(),
            timeZone: .autoupdatingCurrent
        )
    }

    private var loadState: AnalyticsLoadState {
        switch capture.persistenceState {
        case .unavailable:
            .persistenceUnavailable
        case .failed:
            .storageError(
                capture.persistenceError
                    ?? "The activity database reported an unknown error."
            )
        case .available:
            capture.hourlyVisualizationSnapshot == nil ? .loading : .loaded
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(
            minWidth: Self.contentWidth,
            idealWidth: Self.contentWidth,
            maxWidth: Self.contentWidth,
            minHeight: Self.contentHeight,
            idealHeight: Self.contentHeight,
            maxHeight: Self.contentHeight
        )
        .accessibilityIdentifier("analytics.window")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hourly activity")
                    .font(.title2.bold())
                Text("The last 14 local calendar days, newest to oldest")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if loadState == .loaded {
                Text("Updates every 5 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Analytics updates every 5 minutes")
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            AnalyticsStateView(
                systemImage: "chart.dots.scatter",
                title: "Loading analytics…",
                message: "Reading privacy-safe hourly totals stored on this Mac.",
                showsProgress: true
            )
        case .persistenceUnavailable:
            AnalyticsStateView(
                systemImage: "externaldrive.badge.exclamationmark",
                title: "Analytics storage is unavailable",
                message: "APM Explorer could not open its local activity database. Relaunch the app after resolving storage access."
            )
        case .storageError(let message):
            AnalyticsStateView(
                systemImage: "exclamationmark.triangle",
                title: "Analytics could not be loaded",
                message: "The local activity database reported an error. \(message)"
            )
        case .loaded:
            analyticsContent
        }
    }

    private var analyticsContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if capture.permissionState != .granted {
                    statusBanner(
                        systemImage: "hand.raised.fill",
                        message: "Input Monitoring is \(capture.permissionState.title.lowercased()). Existing history remains visible, but new monitored activity may be unavailable."
                    )
                } else if !presentation.hasPositiveActivity {
                    statusBanner(
                        systemImage: "moon.zzz",
                        message: "No actions were counted in this period. Monitored zeroes and unavailable coverage remain visible below."
                    )
                }

                heatmap
                AnalyticsLegend()
                detail
            }
            .padding(20)
        }
    }

    private func statusBanner(systemImage: String, message: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: AnalyticsGridLayout.spacing) {
            AnalyticsHourAxis()
            ForEach(Array(presentation.days.enumerated()), id: \.element.id) { index, day in
                dayRow(day, index: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("14-day hourly activity graph, days top to bottom and hours left to right")
    }

    private func dayRow(
        _ day: AnalyticsDayPresentation,
        index: Int
    ) -> some View {
        HStack(spacing: AnalyticsGridLayout.spacing) {
            Text(day.shortDateLabel)
                .font(.system(size: 9))
                .lineLimit(1)
                .frame(
                    width: AnalyticsGridLayout.dayLabelWidth,
                    height: AnalyticsGridLayout.cellHeight,
                    alignment: .trailing
                )
                .accessibilityHidden(true)

            ForEach(day.cells) { cell in
                Button {
                    selectedCell = cell.id
                    focusedCell = cell.id
                } label: {
                    AnalyticsHeatmapCell(cell: cell)
                }
                .buttonStyle(.plain)
                .focused($focusedCell, equals: cell.id)
                .onHover { isHovering in
                    if isHovering {
                        hoveredCell = cell.id
                    } else if hoveredCell == cell.id {
                        hoveredCell = nil
                    }
                }
                .onMoveCommand { direction in
                    moveFocus(from: cell.id, direction: direction)
                }
                .help(cell.helpText)
                .accessibilityLabel(cell.accessibilityLabel)
                .accessibilityValue(cell.accessibilityValue)
                .accessibilityHint(
                    "Press to keep these details visible. Use left and right for hours, or up and down for days."
                )
                .accessibilityIdentifier(
                    "analytics.cell.\(day.day.year)-\(day.day.month)-\(day.day.day).\(cell.id.hour)"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.fullDateLabel)
        .accessibilitySortPriority(Double(presentation.days.count - index))
    }

    private var detail: some View {
        let cell = presentation.cell(id: hoveredCell ?? selectedCell)
        return GroupBox("Hour details") {
            if let cell {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cell.dateLabel).font(.headline)
                        Text(cell.hourLabel).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(cell.activityLabel).monospacedDigit()
                        Text(cell.coverageLabel)
                            .foregroundStyle(cell.coverage == .partial ? .orange : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Hover over a cell or select it with the mouse, Tab, or arrow keys.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("analytics.details")
    }

    private func moveFocus(from id: AnalyticsCellID, direction: MoveCommandDirection) {
        guard
            let dayIndex = presentation.days.firstIndex(where: { $0.day == id.day })
        else { return }
        var nextDay = dayIndex
        var nextHour = id.hour
        switch direction {
        case .left: nextHour -= 1
        case .right: nextHour += 1
        case .up: nextDay -= 1
        case .down: nextDay += 1
        @unknown default: return
        }
        guard presentation.days.indices.contains(nextDay), (0..<24).contains(nextHour) else {
            return
        }
        let next = AnalyticsCellID(
            day: presentation.days[nextDay].day,
            hour: nextHour
        )
        focusedCell = next
        selectedCell = next
    }

}

private enum AnalyticsGridLayout {
    static let dayLabelWidth: CGFloat = 58
    static let cellWidth: CGFloat = 22
    static let cellHeight: CGFloat = 18
    static let spacing: CGFloat = 3
}

private struct AnalyticsHourAxis: View {
    var body: some View {
        HStack(spacing: AnalyticsGridLayout.spacing) {
            Text("Hour")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(
                    width: AnalyticsGridLayout.dayLabelWidth,
                    height: AnalyticsGridLayout.cellHeight,
                    alignment: .trailing
                )
            ForEach(0..<24, id: \.self) { hour in
                Text(hour.isMultiple(of: 3) ? String(format: "%02d", hour) : "")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(
                        width: AnalyticsGridLayout.cellWidth,
                        height: AnalyticsGridLayout.cellHeight,
                        alignment: .center
                    )
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct AnalyticsHeatmapCell: View {
    let cell: AnalyticsCellPresentation

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fillColor)
            .frame(
                width: AnalyticsGridLayout.cellWidth,
                height: AnalyticsGridLayout.cellHeight
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(borderColor, style: borderStyle)
            }
            .overlay {
                if cell.isCurrentHour {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
    }

    private var fillColor: Color {
        switch cell.fill {
        case .unavailable:
            Color.clear
        case .unmonitored:
            Color.secondary.opacity(0.22)
        case .monitoredZero:
            Color.green.opacity(0.12)
        case .activity(let intensity):
            Color.green.opacity(0.2 + 0.8 * min(max(intensity, 0), 1))
        }
    }

    private var borderColor: Color {
        cell.coverage == .partial ? .orange : Color.primary.opacity(0.22)
    }

    private var borderStyle: StrokeStyle {
        cell.coverage == .partial
            ? StrokeStyle(lineWidth: 1.25, dash: [2, 1])
            : StrokeStyle(lineWidth: 0.6)
    }
}

private struct AnalyticsLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Less")
            legendItem("0 actions", fill: .monitoredZero)
            legendItem("Low", fill: .activity(0.25))
            legendItem("High", fill: .activity(1))
            Text("More")
            Divider().frame(height: 16)
            legendItem("Not monitored", fill: .unmonitored)
            legendItem("No data", fill: .unavailable)
            legendItem("Partial", fill: .activity(0.5), coverage: .partial)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color legend. Zero, low, and high activity; not monitored; no data; and partial coverage.")
    }

    private func legendItem(
        _ title: String,
        fill: AnalyticsCellFill,
        coverage: MonitoringCoverage = .complete
    ) -> some View {
        HStack(spacing: 4) {
            AnalyticsHeatmapCell(cell: AnalyticsCellPresentation(
                id: AnalyticsCellID(day: .init(year: 2001, month: 1, day: 1), hour: 0),
                actionCount: nil,
                actionsPerMinute: nil,
                coverage: coverage,
                intensity: 0,
                fill: fill,
                isCurrentHour: false,
                dateLabel: "",
                hourLabel: "",
                activityLabel: "",
                coverageLabel: "",
                accessibilityLabel: "",
                accessibilityValue: ""
            ))
            Text(title)
        }
    }
}

private struct AnalyticsStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var showsProgress = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityIdentifier("analytics.state")
    }
}
