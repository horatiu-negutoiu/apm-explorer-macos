import AppKit
import APMXCore
import CoreGraphics
import Foundation

struct InputActivitySnapshot: Equatable, Sendable {
    var keyDownCount: UInt64 = 0
    var mouseButtonDownCount: UInt64 = 0
    var scrollWheelCount: UInt64 = 0
    var tapDisabledCount: UInt64 = 0
    var tapReenabledCount: UInt64 = 0
    var droppedSignalCount: UInt64 = 0
}

@MainActor
final class CaptureDiagnosticsModel: ObservableObject {
    @Published private(set) var activity = InputActivitySnapshot()
    @Published private(set) var openSession: ActivitySession?

    func update(
        activity: InputActivitySnapshot,
        openSession: ActivitySession?
    ) {
        self.activity = activity
        self.openSession = openSession
    }
}

/// Thread-safe aggregate diagnostics. It never retains individual signals or
/// their timestamps.
final class InputActivityAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = InputActivitySnapshot()

    func record(_ activity: ReducedActivity) {
        lock.lock()
        defer { lock.unlock() }

        switch activity.countedAction {
        case .keyDown:
            snapshot.keyDownCount &+= 1
        case .mouseButtonDown:
            snapshot.mouseButtonDownCount &+= 1
        case .scroll:
            snapshot.scrollWheelCount &+= 1
        case nil:
            break
        }
    }

    func recordTapDisabled(reenabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.tapDisabledCount &+= 1
        if reenabled {
            snapshot.tapReenabledCount &+= 1
        }
    }

    func recordDroppedSignal() {
        lock.lock()
        defer { lock.unlock() }
        snapshot.droppedSignalCount &+= 1
    }

    func currentSnapshot() -> InputActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = InputActivitySnapshot()
    }
}

struct BoundedActivitySignalBuffer {
    private var storage: [RawActivitySignal?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(capacity, 1))
    }

    mutating func append(_ signal: RawActivitySignal) -> Bool {
        guard count < storage.count else { return false }
        let index = (head + count) % storage.count
        storage[index] = signal
        count += 1
        return true
    }

    mutating func removeFirst() -> RawActivitySignal? {
        guard count > 0 else { return nil }
        let signal = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return signal
    }
}

/// A bounded mailbox backed by one serial executor. The event-tap callback only
/// creates a privacy-safe value and calls `enqueue`; reduction and session work
/// always happen later on `queue`.
final class ActivitySignalIngestionExecutor: @unchecked Sendable {
    private struct MonitoringAnchor {
        var wallTime: WallClockInstant
        var monotonicTime: MonotonicInstant
    }

    private let queue = DispatchQueue(
        label: "ca.horatiu.apmx.activity-ingestion",
        qos: .userInitiated
    )
    private let bufferLock = NSLock()
    private let startsDraining: Bool
    private let accumulator: InputActivityAccumulator
    private let repository: (any ActivitySessionRepository)?
    private let wallClock: any WallClock
    private let monotonicClock: any MonotonicClock
    private var buffer: BoundedActivitySignalBuffer
    private var drainScheduled = false
    private var acceptingSignals = true
    private var captureAllowsSignals = true
    private var deletionInProgress = false

    // Accessed only on `queue`.
    private var reducer: ActivityReducer
    private var sessionEngine: SessionEngine
    private var deadlineWorkItem: DispatchWorkItem?
    private var persistenceTail: Task<Void, Never>?
    private var repositoryFailureObservation: Task<Void, Never>?
    private var stateChangeHandler: (@Sendable () -> Void)?
    private var persistenceFailureHandler: (@Sendable (String) -> Void)?
    private var pendingPersistenceFailure: String?
    private var persistenceFailureReported = false
    private var monitoringAnchor: MonitoringAnchor?
    private var activityStateGeneration: UInt64 = 0
    private var deletionActive = false
    private var monitoringRequestedAfterDeletion = false

    init(
        capacity: Int = 512,
        accumulator: InputActivityAccumulator,
        sessionEngine: SessionEngine = SessionEngine(),
        repository: (any ActivitySessionRepository)? = nil,
        wallClock: any WallClock = SystemWallClock(),
        monotonicClock: any MonotonicClock = SystemMonotonicClock(),
        startsDraining: Bool = true
    ) {
        self.startsDraining = startsDraining
        self.accumulator = accumulator
        self.repository = repository
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.reducer = ActivityReducer()
        self.sessionEngine = sessionEngine
        self.buffer = BoundedActivitySignalBuffer(capacity: capacity)
        if let reportingRepository = repository
            as? any ActivitySessionRepositoryFailureReporting
        {
            let failures = reportingRepository.persistenceFailures
            repositoryFailureObservation = Task { [weak self] in
                for await failure in failures {
                    guard !Task.isCancelled else { return }
                    self?.reportPersistenceFailure(String(describing: failure))
                }
            }
        }
    }

    deinit {
        repositoryFailureObservation?.cancel()
    }

    @discardableResult
    func enqueue(_ signal: RawActivitySignal) -> Bool {
        bufferLock.lock()
        guard acceptingSignals else {
            bufferLock.unlock()
            return false
        }

        guard buffer.append(signal) else {
            bufferLock.unlock()
            accumulator.recordDroppedSignal()
            return false
        }

        let shouldSchedule = startsDraining && !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        bufferLock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.drain()
            }
        }
        return true
    }

    func updateTimeout(_ timeout: SessionTimeout) {
        queue.sync {
            if let transition = sessionEngine.updateTimeout(timeout) {
                persist([transition])
                notifyStateChanged()
            }
            scheduleDeadline()
        }
    }

    func setStateChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        queue.sync { stateChangeHandler = handler }
    }

    func setPersistenceFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        let pendingMessage = queue.sync { () -> String? in
            persistenceFailureHandler = handler
            guard !persistenceFailureReported, let pendingPersistenceFailure else {
                return nil
            }
            persistenceFailureReported = true
            self.pendingPersistenceFailure = nil
            return pendingPersistenceFailure
        }
        if let pendingMessage {
            DispatchQueue.global(qos: .userInitiated).async {
                handler(pendingMessage)
            }
        }
    }

    func resume() {
        queue.sync {
            reducer = ActivityReducer()
            activityStateGeneration &+= 1
        }
        bufferLock.lock()
        captureAllowsSignals = true
        acceptingSignals = !deletionInProgress
        bufferLock.unlock()
    }

    func beginMonitoring() {
        queue.sync {
            guard !deletionActive else {
                monitoringRequestedAfterDeletion = true
                return
            }
            guard monitoringAnchor == nil else { return }
            let wallNow = wallClock.now()
            monitoringAnchor = MonitoringAnchor(
                wallTime: wallNow,
                monotonicTime: monotonicClock.now()
            )
            persist([], hourlyUpdates: [
                .markingCoverageAvailable(at: wallNow)
            ])
        }
    }

    func performMaintenance() {
        queue.sync {
            scheduleMaintenance(at: wallClock.now())
        }
    }

    func endMonitoring() {
        queue.sync {
            if deletionActive {
                monitoringRequestedAfterDeletion = false
                return
            }
            endMonitoringOnQueue()
        }
    }

    func handleMonitoringInterruption(recovered: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.deletionActive {
                self.monitoringRequestedAfterDeletion = recovered
                return
            }
            self.endMonitoringOnQueue()
            if recovered {
                let wallNow = self.wallClock.now()
                self.monitoringAnchor = MonitoringAnchor(
                    wallTime: wallNow,
                    monotonicTime: self.monotonicClock.now()
                )
                self.persist([], hourlyUpdates: [
                    .markingCoverageAvailable(at: wallNow)
                ])
            }
        }
    }

    func suspend(reason: SessionEndReason) {
        bufferLock.lock()
        captureAllowsSignals = false
        acceptingSignals = false
        bufferLock.unlock()

        queue.sync {
            activityStateGeneration &+= 1
            monitoringRequestedAfterDeletion = false
            // Signals accepted before the lifecycle boundary are evidence that
            // occurred while the system was active. Reduce them before closing
            // so shutdown never discards more than the repository's coalescing
            // window.
            drain()
            let coverageUpdates = monitoringUpdates(
                observedWallTime: wallClock.now(),
                monotonicTime: monotonicClock.now(),
                countedAction: false
            )
            monitoringAnchor = nil
            if let transition = sessionEngine.close(reason: reason) {
                persist([transition], hourlyUpdates: coverageUpdates)
                notifyStateChanged()
            } else {
                persist([], hourlyUpdates: coverageUpdates)
            }
            deadlineWorkItem?.cancel()
            deadlineWorkItem = nil
            reducer = ActivityReducer()
        }
    }

    func flushPersistence() async throws {
        let persistenceToAwait = queue.sync { persistenceTail }
        await persistenceToAwait?.value
        try await repository?.flush()
    }

    func hourlyVisualizationSnapshot(
        at now: WallClockInstant,
        timeZone: TimeZone
    ) async throws -> HourlyVisualizationSnapshot? {
        guard let repository else { return nil }
        let interval = try HourlyAnalytics.sourceInterval(
            containing: now,
            timeZone: timeZone,
            dayCount: HourlyAnalytics.historyDayCount
        )
        let persistenceToAwait = queue.sync { persistenceTail }
        await persistenceToAwait?.value
        let points = try await repository.hourlyActivity(
            overlapping: interval.start,
            through: interval.end
        )
        return try HourlyVisualizationSnapshot(
            rollingHours: HourlyAnalytics.rollingHours(
                from: points,
                now: now,
                timeZone: timeZone
            ),
            analyticsDays: HourlyAnalytics.history(
                from: points,
                now: now,
                timeZone: timeZone,
                dayCount: HourlyAnalytics.historyDayCount
            ),
            displayedAt: now
        )
    }

    func flush() {
        if !startsDraining {
            queue.sync { drain() }
        } else {
            queue.sync {}
        }
    }

    func currentOpenSession() -> ActivitySession? {
        queue.sync { sessionEngine.openSession }
    }

    func recoverPersistedSession() async throws {
        guard let repository else { return }
        let wallNow = wallClock.now()
        let recovered = try await repository.recoverOpenSession(at: wallNow)
        guard let recovered else { return }
        let monotonicNow = monotonicClock.now()
        queue.sync {
            _ = sessionEngine.restoreOpenSession(
                recovered,
                atWallTime: wallNow,
                atMonotonicTime: monotonicNow
            )
            scheduleDeadline()
            notifyStateChanged()
        }
    }

    func expireSessionIfNeeded() {
        queue.sync {
            if let transition = sessionEngine.expireIfNeeded() {
                persist([transition])
                notifyStateChanged()
            }
            scheduleDeadline()
        }
    }

    func deleteActivityData() async throws {
        pauseSignalAcceptanceForDeletion()

        let state = queue.sync { () -> (Task<Void, Never>?, Bool, UInt64) in
            drain()
            let wasMonitoring = monitoringAnchor != nil
            monitoringAnchor = nil
            deletionActive = true
            monitoringRequestedAfterDeletion = false
            if let transition = sessionEngine.close(reason: .recovery) {
                persist([transition])
                notifyStateChanged()
            }
            deadlineWorkItem?.cancel()
            deadlineWorkItem = nil
            return (persistenceTail, wasMonitoring, activityStateGeneration)
        }
        await state.0?.value
        do {
            try await repository?.deleteAllActivitySummaries()
        } catch {
            restoreAfterActivityDeletion(
                monitoring: state.1,
                stateGeneration: state.2
            )
            throw error
        }
        restoreAfterActivityDeletion(
            monitoring: state.1,
            stateGeneration: state.2
        )
    }

    private func restoreAfterActivityDeletion(
        monitoring wasMonitoring: Bool,
        stateGeneration: UInt64
    ) {
        queue.sync {
            reducer = ActivityReducer()
            let shouldMonitor = activityStateGeneration == stateGeneration
                ? wasMonitoring
                : monitoringRequestedAfterDeletion
            deletionActive = false
            monitoringRequestedAfterDeletion = false
            if shouldMonitor {
                monitoringAnchor = MonitoringAnchor(
                    wallTime: wallClock.now(),
                    monotonicTime: monotonicClock.now()
                )
            }
        }
        bufferLock.lock()
        deletionInProgress = false
        acceptingSignals = captureAllowsSignals
        bufferLock.unlock()
    }

    private func pauseSignalAcceptanceForDeletion() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        deletionInProgress = true
        acceptingSignals = false
    }

    private func drain() {
        while let signal = takeNextSignal() {
            guard let activity = reducer.reduce(signal) else { continue }
            let transitions = sessionEngine.ingest(activity)
            guard !transitions.isEmpty else { continue }
            accumulator.record(activity)
            let hourlyUpdates = monitoringUpdates(
                observedWallTime: activity.evidenceAt,
                monotonicTime: activity.monotonicTime,
                countedAction: activity.countedAction != nil
            )
            persist(transitions, hourlyUpdates: hourlyUpdates)
            if !transitions.isEmpty {
                notifyStateChanged()
            }
            scheduleDeadline()
        }
    }

    private func persist(
        _ transitions: [SessionTransition],
        hourlyUpdates: [HourlyActivityUpdate] = []
    ) {
        guard let repository, !transitions.isEmpty || !hourlyUpdates.isEmpty else { return }
        let sessions = transitions.map(\.session)
        let previous = persistenceTail
        persistenceTail = Task { [weak self] in
            await previous?.value
            do {
                if sessions.isEmpty {
                    try await repository.applyHourlyUpdates(hourlyUpdates)
                } else {
                    try await repository.save(sessions, applying: hourlyUpdates)
                }
            } catch {
                self?.reportPersistenceFailure(String(describing: error))
            }
        }
    }

    private func endMonitoringOnQueue() {
        let updates = monitoringUpdates(
            observedWallTime: wallClock.now(),
            monotonicTime: monotonicClock.now(),
            countedAction: false
        )
        monitoringAnchor = nil
        persist([], hourlyUpdates: updates)
    }

    private func scheduleMaintenance(at now: WallClockInstant) {
        guard let repository else { return }
        let previous = persistenceTail
        persistenceTail = Task { [weak self] in
            await previous?.value
            do {
                _ = try await repository.performDailyMaintenanceIfNeeded(at: now)
            } catch {
                self?.reportPersistenceFailure(String(describing: error))
            }
        }
    }

    private func monitoringUpdates(
        observedWallTime: WallClockInstant,
        monotonicTime: MonotonicInstant,
        countedAction: Bool
    ) -> [HourlyActivityUpdate] {
        guard let anchor = monitoringAnchor else {
            return HourlyActivityUpdate.aggregating(
                monitoringFrom: nil,
                through: nil,
                countedActionAt: countedAction ? observedWallTime : nil
            )
        }

        let elapsed: Int64
        if monotonicTime >= anchor.monotonicTime {
            let (value, overflow) = monotonicTime.uptimeMilliseconds
                .subtractingReportingOverflow(anchor.monotonicTime.uptimeMilliseconds)
            elapsed = overflow ? .max : value
        } else {
            elapsed = 0
        }
        let (endValue, overflow) = anchor.wallTime.epochMilliseconds
            .addingReportingOverflow(elapsed)
        let normalizedEnd = WallClockInstant(
            epochMilliseconds: overflow ? .max : endValue
        )
        monitoringAnchor = MonitoringAnchor(
            wallTime: normalizedEnd,
            monotonicTime: monotonicTime
        )
        return HourlyActivityUpdate.aggregating(
            monitoringFrom: anchor.wallTime,
            through: normalizedEnd,
            countedActionAt: countedAction ? normalizedEnd : nil
        )
    }

    private func notifyStateChanged() {
        stateChangeHandler?()
    }

    private func reportPersistenceFailure(_ message: String) {
        queue.async { [weak self] in
            guard let self, !self.persistenceFailureReported else { return }
            guard let handler = self.persistenceFailureHandler else {
                self.pendingPersistenceFailure = message
                return
            }
            self.persistenceFailureReported = true
            self.pendingPersistenceFailure = nil
            DispatchQueue.global(qos: .userInitiated).async {
                handler(message)
            }
        }
    }

    private func scheduleDeadline() {
        deadlineWorkItem?.cancel()
        deadlineWorkItem = nil
        guard startsDraining else { return }
        guard let deadline = sessionEngine.nextDeadline else { return }
        let uptimeMilliseconds = Int64(
            (ProcessInfo.processInfo.systemUptime * 1_000).rounded(.towardZero)
        )
        let delay = max(deadline.uptimeMilliseconds - uptimeMilliseconds, 1)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let transition = self.sessionEngine.expireIfNeeded() {
                self.persist([transition])
                self.notifyStateChanged()
            } else {
                self.scheduleDeadline()
            }
        }
        deadlineWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(Int(clamping: delay)),
            execute: workItem
        )
    }

    private func takeNextSignal() -> RawActivitySignal? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let signal = buffer.removeFirst() else {
            drainScheduled = false
            return nil
        }
        return signal
    }
}

private extension SessionTransition {
    var session: ActivitySession {
        switch self {
        case .started(let session), .updated(let session), .ended(let session):
            session
        }
    }
}

/// The sole Core Graphics-to-domain boundary. Only event category,
/// `keyboardEventAutorepeat`, and scroll phase fields are inspected.
struct PrivacySafeInputSignalFactory: Sendable {
    static let observedEventTypes: [CGEventType] = [
        .keyDown,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .scrollWheel,
    ]

    private let wallClock: any WallClock
    private let monotonicClock: any MonotonicClock

    init(
        wallClock: any WallClock = SystemWallClock(),
        monotonicClock: any MonotonicClock = SystemMonotonicClock()
    ) {
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
    }

    func signal(for type: CGEventType, event: CGEvent) -> RawActivitySignal? {
        let kind: RawActivityKind
        var keyDownPhase: RawKeyDownPhase?
        var scrollPhase: RawScrollPhase?

        switch type {
        case .keyDown:
            // This is the only keyboard field read by the adapter.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return nil
            }
            kind = .keyDown
            keyDownPhase = .physical

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseButtonDown

        case .scrollWheel:
            kind = .scroll
            scrollPhase = privacySafeScrollPhase(event)

        default:
            return nil
        }

        return RawActivitySignal(
            kind: kind,
            keyDownPhase: keyDownPhase,
            scrollPhase: scrollPhase,
            wallTime: wallClock.now(),
            monotonicTime: monotonicClock.now()
        )
    }

    private func privacySafeScrollPhase(_ event: CGEvent) -> RawScrollPhase {
        guard event.getIntegerValueField(
            .scrollWheelEventMomentumPhase
        ) == 0 else {
            return .momentum
        }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase & 1 != 0 || phase & 128 != 0 { return .directBegan }
        if phase & 2 != 0 { return .directChanged }
        if phase & 4 != 0 || phase & 8 != 0 { return .directEnded }
        return .phaseLess
    }
}

enum SystemSettingsLink {
    static let inputMonitoring = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
    static let privacyAndSecurity = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
    )!
}

protocol SystemSettingsOpening {
    @MainActor @discardableResult
    func open(_ url: URL) -> Bool
}

struct AppKitSystemSettingsOpener: SystemSettingsOpening {
    @MainActor
    func open(_ url: URL) -> Bool {
        guard let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            return NSWorkspace.shared.open(url)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        // A menu-bar app can remain the active process while its popover is
        // disappearing. Deactivate first so System Settings can own focus.
        NSApplication.shared.deactivate()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: settingsURL,
            configuration: configuration
        ) { application, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                bringSystemSettingsToFront(application)
            }
        }

        // Opening an already-loaded settings extension is asynchronous. A
        // second activation after the pane transition keeps its window above
        // the app that was frontmost when the status menu was clicked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            activateRunningSystemSettings()
        }
        return true
    }

    @MainActor
    private func activateRunningSystemSettings() {
        for bundleIdentifier in ["com.apple.systempreferences", "com.apple.SystemSettings"] {
            if let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first {
                bringSystemSettingsToFront(application)
                return
            }
        }
    }

    @MainActor
    private func bringSystemSettingsToFront(_ application: NSRunningApplication?) {
        guard let application else { return }
        application.unhide()
        application.activate(options: [.activateAllWindows])
    }
}

private final class EventTapContext: @unchecked Sendable {
    let accumulator: InputActivityAccumulator
    let ingestion: ActivitySignalIngestionExecutor
    let signalFactory: PrivacySafeInputSignalFactory
    var tap: CFMachPort?

    init(
        accumulator: InputActivityAccumulator,
        ingestion: ActivitySignalIngestionExecutor,
        signalFactory: PrivacySafeInputSignalFactory
    ) {
        self.accumulator = accumulator
        self.ingestion = ingestion
        self.signalFactory = signalFactory
    }
}

@discardableResult
func handlePassiveEventTapControlEvent(
    _ type: CGEventType,
    accumulator: InputActivityAccumulator,
    reenable: () -> Bool
) -> Bool {
    guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
        return false
    }
    accumulator.recordTapDisabled(reenabled: reenable())
    return true
}

private let passiveEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<EventTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    var monitoringRecovered = false
    if handlePassiveEventTapControlEvent(
        type,
        accumulator: context.accumulator,
        reenable: {
            guard let tap = context.tap else { return false }
            CGEvent.tapEnable(tap: tap, enable: true)
            monitoringRecovered = CGEvent.tapIsEnabled(tap: tap)
            return monitoringRecovered
        }
    ) {
        context.ingestion.handleMonitoringInterruption(
            recovered: monitoringRecovered
        )
        return nil
    }

    if let signal = context.signalFactory.signal(for: type, event: event) {
        _ = context.ingestion.enqueue(signal)
    }
    return Unmanaged.passUnretained(event)
}

/// Owns the Mach port and its dedicated Core Foundation run loop.
private final class EventTapRunLoopState: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var creationSucceeded = false

    func run(context: EventTapContext) {
        let currentRunLoop = CFRunLoopGetCurrent()
        let mask = PrivacySafeInputSignalFactory.observedEventTypes.reduce(CGEventMask()) {
            result, type in
            result | (CGEventMask(1) << type.rawValue)
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: passiveEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            started.signal()
            finished.signal()
            return
        }

        lock.lock()
        runLoop = currentRunLoop
        tap = eventTap
        source = runLoopSource
        context.tap = eventTap
        creationSucceeded = true
        lock.unlock()

        CFRunLoopAddSource(currentRunLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        started.signal()
        CFRunLoopRun()
        context.tap = nil
        finished.signal()
    }

    func waitUntilStarted() { started.wait() }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func reenable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func stop() {
        lock.lock()
        guard let runLoop else {
            lock.unlock()
            return
        }
        let eventTap = tap
        let runLoopSource = source
        self.runLoop = nil
        tap = nil
        source = nil
        lock.unlock()

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
            }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        finished.wait()
    }
}

private final class CoreGraphicsPassiveEventTap {
    private let state: EventTapRunLoopState
    private let thread: Thread

    var isEnabled: Bool { state.isEnabled }

    @discardableResult
    func reenable() -> Bool { state.reenable() }

    init?(
        accumulator: InputActivityAccumulator,
        ingestion: ActivitySignalIngestionExecutor,
        signalFactory: PrivacySafeInputSignalFactory = PrivacySafeInputSignalFactory()
    ) {
        let state = EventTapRunLoopState()
        let context = EventTapContext(
            accumulator: accumulator,
            ingestion: ingestion,
            signalFactory: signalFactory
        )
        let thread = Thread { state.run(context: context) }
        thread.name = "APMX Core Graphics event tap"
        thread.qualityOfService = .userInteractive
        self.state = state
        self.thread = thread
        thread.start()
        state.waitUntilStarted()
        guard state.creationSucceeded else { return nil }
    }

    deinit { stop() }
    func stop() { state.stop() }
}

enum PassiveCaptureState: Equatable {
    case listening
    case waitingForPermission
    case suspended
    case unavailable

    var title: String {
        switch self {
        case .listening: "Listening"
        case .waitingForPermission: "Waiting for permission"
        case .suspended: "Suspended"
        case .unavailable: "Event tap unavailable"
        }
    }
}

enum ActivityPersistenceState: Equatable {
    case available
    case unavailable
    case failed

    var title: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Persistence unavailable"
        case .failed: "Persistence failed"
        }
    }
}

struct HourlyVisualizationSnapshot: Equatable, Sendable {
    let rollingHours: [RollingHourlyAnalyticsCell]
    let analyticsDays: [HourlyAnalyticsDay]
    let displayedAt: WallClockInstant
}

@MainActor
final class PassiveInputCaptureModel: ObservableObject {
    static let defaultPermissionCheckInterval: TimeInterval = 15
    static let defaultRecoveryCheckInterval: TimeInterval = 0.5
    static let defaultRapidRecoveryCheckLimit = 12
    static let defaultHourlyVisualizationRefreshInterval: TimeInterval = 5 * 60

    @Published private(set) var permissionState: InputMonitoringPermissionState
    @Published private(set) var captureState: PassiveCaptureState = .waitingForPermission
    let diagnostics = CaptureDiagnosticsModel()
    @Published private(set) var hourlyVisualizationSnapshot: HourlyVisualizationSnapshot?
    @Published private(set) var persistenceState: ActivityPersistenceState
    @Published private(set) var persistenceError: String?
    @Published private(set) var settingsOpenFailed = false
    @Published private(set) var relaunchFailed = false

    var metricsAreAvailable: Bool {
        permissionState == .granted
            && captureState == .listening
            && persistenceState == .available
    }

    private let permissionService: InputMonitoringPermissionService
    private let settingsOpener: any SystemSettingsOpening
    private let accumulator: InputActivityAccumulator
    private let ingestion: ActivitySignalIngestionExecutor
    private let pollingNanoseconds: UInt64
    private let recoveryPollingNanoseconds: UInt64
    private let hourlyVisualizationRefreshNanoseconds: UInt64
    private let rapidRecoveryCheckLimit: Int
    private var eventTap: CoreGraphicsPassiveEventTap?
    private var pollingTask: Task<Void, Never>?
    private var hourlyVisualizationRefreshTask: Task<Void, Never>?
    private var lifecycleTokens: [NSObjectProtocol] = []
    private var lifecycleSuspended = false
    private var ingestionIsActive = false
    private var recoveryAttempt = 0
    private var nextRecoveryAttempt: ContinuousClock.Instant?

    init(
        permissionService: InputMonitoringPermissionService? = nil,
        settingsOpener: any SystemSettingsOpening = AppKitSystemSettingsOpener(),
        accumulator: InputActivityAccumulator = InputActivityAccumulator(),
        ingestion: ActivitySignalIngestionExecutor? = nil,
        timeout: SessionTimeout = .oneMinute,
        activityRepository: (any ActivitySessionRepository)? = nil,
        activityRepositoryError: String? = nil,
        pollingInterval: TimeInterval = defaultPermissionCheckInterval,
        recoveryCheckInterval: TimeInterval = defaultRecoveryCheckInterval,
        hourlyVisualizationRefreshInterval: TimeInterval =
            defaultHourlyVisualizationRefreshInterval,
        rapidRecoveryCheckLimit: Int = defaultRapidRecoveryCheckLimit,
        startsAutomatically: Bool = true
    ) {
        let permissionService = permissionService ?? InputMonitoringPermissionService()
        self.permissionService = permissionService
        permissionState = permissionService.state
        self.settingsOpener = settingsOpener
        self.accumulator = accumulator
        persistenceState = activityRepository == nil ? .unavailable : .available
        persistenceError = activityRepositoryError
        self.ingestion = ingestion ?? ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            sessionEngine: SessionEngine(timeout: timeout),
            repository: activityRepository
        )
        pollingNanoseconds = UInt64(max(pollingInterval, 0.1) * 1_000_000_000)
        recoveryPollingNanoseconds = UInt64(
            max(recoveryCheckInterval, 0.01) * 1_000_000_000
        )
        hourlyVisualizationRefreshNanoseconds = UInt64(
            max(hourlyVisualizationRefreshInterval, 0.01) * 1_000_000_000
        )
        self.rapidRecoveryCheckLimit = max(rapidRecoveryCheckLimit, 0)
        self.ingestion.setStateChangeHandler { [weak self] in
            Task { @MainActor in
                self?.ingestionStateDidChange()
            }
        }
        self.ingestion.setPersistenceFailureHandler { [weak self] message in
            Task { @MainActor in
                self?.persistenceDidFail(message)
            }
        }

        if startsAutomatically {
            Task { [weak self] in self?.start() }
        }
    }

    deinit {
        pollingTask?.cancel()
        hourlyVisualizationRefreshTask?.cancel()
    }

    func start() {
        guard pollingTask == nil else { return }
        installLifecycleObservers()
        pollingTask = Task { [weak self, pollingNanoseconds] in
            guard let self else { return }
            do {
                try await self.ingestion.recoverPersistedSession()
            } catch {
                self.persistenceDidFail(String(describing: error))
            }
            self.refresh()
            self.startHourlyVisualizationRefreshTask()
            var rapidRecoveryChecks = 0
            while !Task.isCancelled {
                let needsRapidRecovery = self.permissionState != .granted
                    || self.captureState == .unavailable
                let canRapidlyRecover = needsRapidRecovery
                    && rapidRecoveryChecks < self.rapidRecoveryCheckLimit
                let delay = canRapidlyRecover
                    ? self.recoveryPollingNanoseconds
                    : pollingNanoseconds
                if canRapidlyRecover {
                    rapidRecoveryChecks += 1
                } else if !needsRapidRecovery {
                    rapidRecoveryChecks = 0
                }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func requestAccess() {
        permissionState = permissionService.requestAccess()
        reconcileCaptureWithPermission()
    }

    func refresh() {
        ingestion.expireSessionIfNeeded()
        ingestion.performMaintenance()
        publishInMemoryState()
        guard !lifecycleSuspended else {
            captureState = .suspended
            return
        }

        permissionState = permissionService.check()
        reconcileCaptureWithPermission()
    }

    private func reconcileCaptureWithPermission() {
        guard permissionState == .granted else {
            captureState = .waitingForPermission
            stopTapAndIngestion(reason: .recovery)
            return
        }
        guard persistenceState == .available else {
            stopTapAndIngestion(reason: .recovery)
            captureState = .suspended
            return
        }
        startIngestionIfNeeded()

        if let eventTap, eventTap.isEnabled {
            ingestion.beginMonitoring()
            captureState = .listening
            recoveryAttempt = 0
            nextRecoveryAttempt = nil
            return
        }

        guard recoveryIsDue else {
            ingestion.endMonitoring()
            captureState = .unavailable
            return
        }

        ingestion.endMonitoring()
        if let eventTap, eventTap.reenable() {
            ingestion.beginMonitoring()
            captureState = .listening
            recoveryAttempt = 0
            nextRecoveryAttempt = nil
            return
        }

        eventTap?.stop()
        eventTap = nil
        if ingestionIsActive {
            ingestion.suspend(reason: .recovery)
            ingestionIsActive = false
        }
        startIngestionIfNeeded()
        eventTap = CoreGraphicsPassiveEventTap(
            accumulator: accumulator,
            ingestion: ingestion
        )
        if eventTap?.isEnabled == true {
            ingestion.beginMonitoring()
            captureState = .listening
            recoveryAttempt = 0
            nextRecoveryAttempt = nil
        } else {
            captureState = .unavailable
            scheduleRecovery()
        }
    }

    func suspend(reason: SessionEndReason) {
        guard !lifecycleSuspended else { return }
        lifecycleSuspended = true
        stopTapAndIngestion(reason: reason)
        captureState = .suspended
        publishInMemoryState()
    }

    func refreshHourlyVisualization(
        now: WallClockInstant = SystemWallClock().now(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) async {
        guard persistenceState == .available else {
            hourlyVisualizationSnapshot = nil
            return
        }
        do {
            hourlyVisualizationSnapshot = try await ingestion
                .hourlyVisualizationSnapshot(at: now, timeZone: timeZone)
        } catch {
            persistenceDidFail(String(describing: error))
        }
    }

    func flushPendingPersistence() async {
        do {
            try await ingestion.flushPersistence()
        } catch {
            persistenceDidFail(String(describing: error))
        }
    }

    func prepareForTermination() async {
        suspend(reason: .shutdown)
        await flushPendingPersistence()
    }

    func resume() {
        guard lifecycleSuspended else { return }
        lifecycleSuspended = false
        recoveryAttempt = 0
        nextRecoveryAttempt = nil
        refresh()
    }

    func resetCounters() {
        accumulator.reset()
        publishInMemoryState()
    }

    func updateTimeout(_ timeout: SessionTimeout) {
        ingestion.updateTimeout(timeout)
        publishInMemoryState()
    }

    func deleteActivityData() async throws {
        do {
            try await ingestion.deleteActivityData()
        } catch {
            persistenceDidFail(String(describing: error))
            throw error
        }
        accumulator.reset()
        publishInMemoryState()
        hourlyVisualizationSnapshot = nil
        await refreshHourlyVisualization()
    }

    func openInputMonitoringSettings() {
        if settingsOpener.open(SystemSettingsLink.inputMonitoring) {
            settingsOpenFailed = false
        } else {
            settingsOpenFailed = !settingsOpener.open(SystemSettingsLink.privacyAndSecurity)
        }
    }

    func openPrivacyAndSecurityFallback() {
        settingsOpenFailed = !settingsOpener.open(SystemSettingsLink.privacyAndSecurity)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                if error == nil {
                    NSApplication.shared.terminate(nil)
                } else {
                    self?.relaunchFailed = true
                }
            }
        }
    }

    private var recoveryIsDue: Bool {
        guard let nextRecoveryAttempt else { return true }
        return ContinuousClock.now >= nextRecoveryAttempt
    }

    private func scheduleRecovery() {
        let exponent = min(recoveryAttempt, 5)
        let delayMilliseconds = min(250 * (1 << exponent), 8_000)
        recoveryAttempt += 1
        nextRecoveryAttempt = ContinuousClock.now.advanced(
            by: .milliseconds(delayMilliseconds)
        )
    }

    private func startIngestionIfNeeded() {
        guard !ingestionIsActive else { return }
        ingestion.resume()
        ingestionIsActive = true
    }

    private func stopTapAndIngestion(reason: SessionEndReason) {
        // Reject new callback traffic and close any recovered or live session
        // before waiting for the event-tap run loop to tear down. This keeps
        // the durable end boundary at the lifecycle transition rather than
        // after tap cleanup.
        ingestion.suspend(reason: reason)
        ingestionIsActive = false
        eventTap?.stop()
        eventTap = nil
    }

    private func publishInMemoryState() {
        diagnostics.update(
            activity: accumulator.currentSnapshot(),
            openSession: ingestion.currentOpenSession()
        )
    }

    private func ingestionStateDidChange() {
        diagnostics.update(
            activity: accumulator.currentSnapshot(),
            openSession: ingestion.currentOpenSession()
        )
    }

    private func startHourlyVisualizationRefreshTask() {
        guard hourlyVisualizationRefreshTask == nil else { return }
        hourlyVisualizationRefreshTask = Task { [weak self, hourlyVisualizationRefreshNanoseconds] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshHourlyVisualization()
                do {
                    try await Task.sleep(
                        nanoseconds: hourlyVisualizationRefreshNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func persistenceDidFail(_ message: String? = nil) {
        persistenceState = .failed
        if let message { persistenceError = message }
        stopTapAndIngestion(reason: .recovery)
        captureState = .suspended
        hourlyVisualizationSnapshot = nil
        hourlyVisualizationRefreshTask?.cancel()
        hourlyVisualizationRefreshTask = nil
    }

    private func installLifecycleObservers() {
        guard lifecycleTokens.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspend(reason: .sleep)
                Task { await self?.flushPendingPersistence() }
            }
        })
        lifecycleTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspend(reason: .sessionInactive)
                Task { await self?.flushPendingPersistence() }
            }
        })
        lifecycleTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        lifecycleTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        lifecycleTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        lifecycleTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(reason: .shutdown) }
        })
    }
}
