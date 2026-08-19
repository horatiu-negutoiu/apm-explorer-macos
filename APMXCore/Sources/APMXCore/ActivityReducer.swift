/// Stateful, privacy-safe reduction of high-volume platform activity signals.
///
/// All gesture boundaries use monotonic timestamps. The reducer
/// retains timestamps and small enum state only; raw input payloads cannot be
/// represented by its input or output types.
public struct ActivityReducer: Sendable {
  private static let phaseLessScrollQuietGapMilliseconds: Int64 = 250

  private var lastObservedTime: MonotonicInstant?
  private var directScrollGestureIsActive = false
  private var lastPhaseLessScrollTime: MonotonicInstant?

  public init() {}

  /// Returns activity evidence when the signal survives reduction.
  /// Out-of-order monotonic signals are discarded.
  public mutating func reduce(_ signal: RawActivitySignal) -> ReducedActivity? {
    if let lastObservedTime, signal.monotonicTime < lastObservedTime {
      return nil
    }
    lastObservedTime = signal.monotonicTime

    switch signal.kind {
    case .keyDown:
      guard signal.keyDownPhase == .physical else { return nil }
      return reduced(signal, countedAction: .keyDown)

    case .mouseButtonDown:
      return reduced(signal, countedAction: .mouseButtonDown)

    case .scroll:
      return reduceScroll(signal)
    }
  }

  private mutating func reduceScroll(
    _ signal: RawActivitySignal
  ) -> ReducedActivity? {
    switch signal.scrollPhase ?? .phaseLess {
    case .momentum:
      directScrollGestureIsActive = false
      lastPhaseLessScrollTime = nil
      return nil

    case .directBegan:
      let startsGesture = !directScrollGestureIsActive
      directScrollGestureIsActive = true
      lastPhaseLessScrollTime = nil
      return reduced(signal, countedAction: startsGesture ? .scroll : nil)

    case .directChanged:
      directScrollGestureIsActive = true
      lastPhaseLessScrollTime = nil
      return reduced(signal, countedAction: nil)

    case .directEnded:
      directScrollGestureIsActive = false
      lastPhaseLessScrollTime = nil
      return reduced(signal, countedAction: nil)

    case .phaseLess:
      directScrollGestureIsActive = false
      let startsBurst: Bool
      if let lastPhaseLessScrollTime,
         let gap = signal.monotonicTime.elapsed(since: lastPhaseLessScrollTime) {
        startsBurst = gap >= Self.phaseLessScrollQuietGapMilliseconds
      } else {
        startsBurst = true
      }
      lastPhaseLessScrollTime = signal.monotonicTime
      return reduced(signal, countedAction: startsBurst ? .scroll : nil)
    }
  }

  private func reduced(
    _ signal: RawActivitySignal,
    countedAction: CountedActionKind?
  ) -> ReducedActivity {
    ReducedActivity(
      evidenceAt: signal.wallTime,
      monotonicTime: signal.monotonicTime,
      countedAction: countedAction
    )
  }
}
