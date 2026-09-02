import Foundation

public protocol WallClock: Sendable {
  func now() -> WallClockInstant
}

public protocol MonotonicClock: Sendable {
  func now() -> MonotonicInstant
}

public struct SystemWallClock: WallClock {
  public init() {}

  public func now() -> WallClockInstant {
    WallClockInstant(date: Date())
  }
}

public struct SystemMonotonicClock: MonotonicClock {
  public init() {}

  public func now() -> MonotonicInstant {
    let milliseconds = ProcessInfo.processInfo.systemUptime * 1_000
    let clamped: Int64
    if milliseconds >= Double(Int64.max) {
      clamped = .max
    } else {
      clamped = Int64(milliseconds.rounded(.towardZero))
    }
    return MonotonicInstant(uptimeMilliseconds: clamped)
  }
}
