/// The only input categories allowed across the platform/domain boundary.
/// No case can carry keys, text, modifiers, coordinates, deltas, application
/// identity, or other user content.
public enum RawActivityKind: String, Codable, CaseIterable, Sendable {
  case keyDown
  case mouseButtonDown
  case scroll
}

/// Privacy-safe key-down metadata used to discard operating-system repeats.
public enum RawKeyDownPhase: String, Codable, CaseIterable, Sendable {
  case physical
  case autoRepeat
}

/// Privacy-safe scroll metadata used to distinguish direct input from momentum.
public enum RawScrollPhase: String, Codable, CaseIterable, Sendable {
  case directBegan
  case directChanged
  case directEnded
  case phaseLess
  case momentum
}

/// A signal already stripped of input payload data by a platform adapter.
public struct RawActivitySignal: Equatable, Codable, Sendable {
  public let kind: RawActivityKind
  public let keyDownPhase: RawKeyDownPhase?
  public let scrollPhase: RawScrollPhase?
  public let wallTime: WallClockInstant
  public let monotonicTime: MonotonicInstant

  public init(
    kind: RawActivityKind,
    keyDownPhase: RawKeyDownPhase? = nil,
    scrollPhase: RawScrollPhase? = nil,
    wallTime: WallClockInstant,
    monotonicTime: MonotonicInstant
  ) {
    self.kind = kind
    self.keyDownPhase = kind == .keyDown ? (keyDownPhase ?? .physical) : nil
    self.scrollPhase = kind == .scroll ? (scrollPhase ?? .phaseLess) : nil
    self.wallTime = wallTime
    self.monotonicTime = monotonicTime
  }
}

public enum CountedActionKind: String, Codable, CaseIterable, Sendable {
  case keyDown
  case mouseButtonDown
  case scroll
}

/// Activity evidence refreshes the lease. `countedAction` independently controls
/// the APM numerator, allowing direct scroll updates to refresh a lease without
/// counting an action for every update.
public struct ReducedActivity: Equatable, Codable, Sendable {
  public let evidenceAt: WallClockInstant
  public let monotonicTime: MonotonicInstant
  public let countedAction: CountedActionKind?

  public init(
    evidenceAt: WallClockInstant,
    monotonicTime: MonotonicInstant,
    countedAction: CountedActionKind?
  ) {
    self.evidenceAt = evidenceAt
    self.monotonicTime = monotonicTime
    self.countedAction = countedAction
  }
}
