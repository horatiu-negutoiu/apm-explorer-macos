import Foundation

/// Deterministic owner of all activity-session transitions.
///
/// Boundary rule: evidence with a monotonic timestamp strictly before the lease
/// deadline extends the current session. Evidence exactly at or after the
/// deadline closes the old session and starts a new one.
public final class SessionEngine {
  public private(set) var openSession: ActivitySession?
  public private(set) var completedSessions: [ActivitySession] = []
  public private(set) var timeout: SessionTimeout

  public var nextDeadline: MonotonicInstant? {
    openState?.deadline
  }

  private struct OpenState {
    var session: ActivitySession
    var lastEvidenceMonotonic: MonotonicInstant
    var deadline: MonotonicInstant
  }

  private struct TimelineAnchor {
    let wallTime: WallClockInstant
    let monotonicTime: MonotonicInstant
  }

  private let wallClock: any WallClock
  private let monotonicClock: any MonotonicClock
  private let makeSessionID: () -> UUID
  private var openState: OpenState? {
    didSet { openSession = openState?.session }
  }
  private var timelineAnchor: TimelineAnchor?

  public init(
    timeout: SessionTimeout = .oneMinute,
    wallClock: any WallClock = SystemWallClock(),
    monotonicClock: any MonotonicClock = SystemMonotonicClock()
  ) {
    self.timeout = timeout
    self.wallClock = wallClock
    self.monotonicClock = monotonicClock
    self.makeSessionID = UUID.init
  }

  init(
    timeout: SessionTimeout,
    wallClock: any WallClock,
    monotonicClock: any MonotonicClock,
    makeSessionID: @escaping () -> UUID
  ) {
    self.timeout = timeout
    self.wallClock = wallClock
    self.monotonicClock = monotonicClock
    self.makeSessionID = makeSessionID
  }

  /// Records evidence at the injected clocks' current timestamps.
  @discardableResult
  public func recordActivity(
    countedAction: CountedActionKind?
  ) -> [SessionTransition] {
    ingest(
      ReducedActivity(
        evidenceAt: wallClock.now(),
        monotonicTime: monotonicClock.now(),
        countedAction: countedAction
      )
    )
  }

  /// Restores a still-valid session loaded from durable storage after process
  /// launch. The remaining wall-clock lease is projected onto the current
  /// process's monotonic clock so subsequent expiry cannot be affected by a
  /// wall-clock adjustment.
  @discardableResult
  public func restoreOpenSession(
    _ session: ActivitySession,
    atWallTime now: WallClockInstant,
    atMonotonicTime monotonicNow: MonotonicInstant
  ) -> Bool {
    guard openState == nil, session.isOpen, now < session.leaseEndsAt else {
      return false
    }
    let (remainingValue, overflow) = session.leaseEndsAt.epochMilliseconds
      .subtractingReportingOverflow(now.epochMilliseconds)
    // A wall-clock rollback between launches must not grant more than the
    // timeout that was stored with the session. Live deadlines remain purely
    // monotonic after this one-time projection.
    let remaining = min(
      max(overflow ? session.timeout.milliseconds : remainingValue, 0),
      session.timeout.milliseconds
    )
    let deadline = monotonicNow.advanced(byMilliseconds: remaining)
    let lastEvidenceMonotonic = deadline.advanced(
      byMilliseconds: -session.timeout.milliseconds
    )
    timeout = session.timeout
    timelineAnchor = TimelineAnchor(
      wallTime: session.lastActivityAt,
      monotonicTime: lastEvidenceMonotonic
    )
    openState = OpenState(
      session: session,
      lastEvidenceMonotonic: lastEvidenceMonotonic,
      deadline: deadline
    )
    return true
  }

  /// Records pre-timestamped evidence from an ingestion pipeline.
  /// Out-of-order monotonic evidence is ignored.
  @discardableResult
  public func ingest(_ activity: ReducedActivity) -> [SessionTransition] {
    guard var state = openState else {
      guard isOnOrAfterTimelineAnchor(activity.monotonicTime) else { return [] }
      let transition = startSession(with: activity)
      return [transition]
    }

    guard activity.monotonicTime >= state.lastEvidenceMonotonic else { return [] }

    if activity.monotonicTime < state.deadline {
      state.session.lastActivityAt = normalizedWallTime(
        observed: activity.evidenceAt,
        monotonic: activity.monotonicTime,
        relativeTo: TimelineAnchor(
          wallTime: state.session.lastActivityAt,
          monotonicTime: state.lastEvidenceMonotonic
        )
      )
      state.lastEvidenceMonotonic = activity.monotonicTime
      state.deadline = activity.monotonicTime.advanced(
        byMilliseconds: state.session.timeout.milliseconds
      )
      if activity.countedAction != nil {
        state.session.actionCount = state.session.actionCount.addingClamped(1)
      }
      openState = state
      return [.updated(state.session)]
    }

    let ended = endOpenSession(
      atWallTime: state.session.leaseEndsAt,
      atMonotonicTime: state.deadline,
      reason: .inactivityTimeout
    )
    let started = startSession(with: activity)
    return [.ended(ended), started]
  }

  /// Ends an expired lease once. Calling this repeatedly after expiry is a no-op.
  @discardableResult
  public func expireIfNeeded() -> SessionTransition? {
    guard let state = openState else { return nil }
    let now = monotonicClock.now()
    guard now >= state.deadline else { return nil }
    let ended = endOpenSession(
      atWallTime: state.session.leaseEndsAt,
      atMonotonicTime: state.deadline,
      reason: .inactivityTimeout
    )
    return .ended(ended)
  }

  /// Closes an open session early for a lifecycle or recovery boundary.
  /// `.inactivityTimeout` remains governed by `expireIfNeeded()`.
  @discardableResult
  public func close(reason: SessionEndReason) -> SessionTransition? {
    guard reason != .inactivityTimeout, let state = openState else { return nil }
    let observedMonotonicNow = monotonicClock.now()
    if observedMonotonicNow >= state.deadline {
      let ended = endOpenSession(
        atWallTime: state.session.leaseEndsAt,
        atMonotonicTime: state.deadline,
        reason: .inactivityTimeout
      )
      return .ended(ended)
    }

    let monotonicNow = max(observedMonotonicNow, state.lastEvidenceMonotonic)
    let wallNow = normalizedWallTime(
      observed: wallClock.now(),
      monotonic: monotonicNow,
      relativeTo: TimelineAnchor(
        wallTime: state.session.lastActivityAt,
        monotonicTime: state.lastEvidenceMonotonic
      )
    )
    let ended = endOpenSession(
      atWallTime: wallNow,
      atMonotonicTime: monotonicNow,
      reason: reason
    )
    return .ended(ended)
  }

  /// Applies a new timeout to the open session as well as future sessions.
  /// If the shortened lease is already due, this closes it immediately at the
  /// recomputed deadline.
  @discardableResult
  public func updateTimeout(_ newTimeout: SessionTimeout) -> SessionTransition? {
    if let expired = expireIfNeeded() {
      timeout = newTimeout
      return expired
    }

    timeout = newTimeout
    guard var state = openState else { return nil }
    state.session.timeout = newTimeout
    state.deadline = state.lastEvidenceMonotonic.advanced(
      byMilliseconds: newTimeout.milliseconds
    )

    if monotonicClock.now() >= state.deadline {
      openState = state
      let ended = endOpenSession(
        atWallTime: state.session.leaseEndsAt,
        atMonotonicTime: state.deadline,
        reason: .inactivityTimeout
      )
      return .ended(ended)
    }

    openState = state
    return .updated(state.session)
  }

  private func startSession(with activity: ReducedActivity) -> SessionTransition {
    let start = normalizedWallTime(
      observed: activity.evidenceAt,
      monotonic: activity.monotonicTime,
      relativeTo: timelineAnchor
    )
    let session = ActivitySession(
      id: makeSessionID(),
      startedAt: start,
      countedAction: activity.countedAction,
      timeout: timeout
    )
    openState = OpenState(
      session: session,
      lastEvidenceMonotonic: activity.monotonicTime,
      deadline: activity.monotonicTime.advanced(
        byMilliseconds: timeout.milliseconds
      )
    )
    return .started(session)
  }

  private func endOpenSession(
    atWallTime wallTime: WallClockInstant,
    atMonotonicTime monotonicTime: MonotonicInstant,
    reason: SessionEndReason
  ) -> ActivitySession {
    precondition(openState != nil, "Cannot end a session that is not open")
    var session = openState!.session
    session.endedAt = max(wallTime, session.startedAt)
    session.endReason = reason
    completedSessions.append(session)
    timelineAnchor = TimelineAnchor(
      wallTime: session.endedAt!,
      monotonicTime: monotonicTime
    )
    openState = nil
    return session
  }

  private func normalizedWallTime(
    observed: WallClockInstant,
    monotonic: MonotonicInstant,
    relativeTo anchor: TimelineAnchor?
  ) -> WallClockInstant {
    guard
      let anchor,
      let elapsed = monotonic.elapsed(since: anchor.monotonicTime)
    else {
      return observed
    }
    return anchor.wallTime.advanced(byMilliseconds: elapsed)
  }

  private func isOnOrAfterTimelineAnchor(_ instant: MonotonicInstant) -> Bool {
    guard let timelineAnchor else { return true }
    return instant >= timelineAnchor.monotonicTime
  }
}
