/// The result of calculating actions per minute for an open session.
///
/// Durations shorter than one second are intentionally `undefined`. This gives
/// presentation code a stable state to render instead of exposing a division
/// by a very small duration as a misleading initial spike.
public enum APMResult: Equatable, Sendable {
  case undefined
  case value(Double)

  public var actionsPerMinute: Double? {
    guard case .value(let value) = self else { return nil }
    return value
  }
}

/// A pure actions-per-minute calculation for the currently open session.
public enum APMCalculator {
  /// Calculates `actionCount / activeDurationMinutes` without presentation
  /// rounding.
  ///
  /// The effective end is `min(now, lastActivityAt + timeout)`. A duration of
  /// exactly one second is defined; shorter, zero, and rolled-back durations
  /// are `undefined`. Closed or absent sessions are also `undefined`.
  public static func calculate(
    for session: ActivitySession?,
    now: WallClockInstant
  ) -> APMResult {
    guard let session, session.isOpen else { return .undefined }

    let effectiveEnd = min(now, session.leaseEndsAt)
    guard
      let duration = positiveDistance(
        from: session.startedAt,
        to: effectiveEnd
      ), duration >= 1_000
    else {
      return .undefined
    }

    let actionsPerMinute = Double(session.actionCount) * 60_000 / Double(duration)
    return .value(actionsPerMinute)
  }
}

private func positiveDistance(
  from start: WallClockInstant,
  to end: WallClockInstant
) -> Int64? {
  guard end > start else { return nil }
  let (distance, overflow) = end.epochMilliseconds.subtractingReportingOverflow(
    start.epochMilliseconds
  )
  return overflow ? .max : distance
}
