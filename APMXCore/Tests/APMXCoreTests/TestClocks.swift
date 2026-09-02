import APMXCore
import Foundation

final class TestWallClock: WallClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant: WallClockInstant

  init(milliseconds: Int64) {
    self.instant = WallClockInstant(epochMilliseconds: milliseconds)
  }

  func now() -> WallClockInstant {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(milliseconds: Int64) {
    lock.lock()
    defer { lock.unlock() }
    instant = WallClockInstant(
      epochMilliseconds: instant.epochMilliseconds + milliseconds
    )
  }

  func set(milliseconds: Int64) {
    lock.lock()
    defer { lock.unlock() }
    instant = WallClockInstant(epochMilliseconds: milliseconds)
  }
}

final class TestMonotonicClock: MonotonicClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant: MonotonicInstant

  init(milliseconds: Int64) {
    self.instant = MonotonicInstant(uptimeMilliseconds: milliseconds)
  }

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(milliseconds: Int64) {
    lock.lock()
    defer { lock.unlock() }
    instant = MonotonicInstant(
      uptimeMilliseconds: instant.uptimeMilliseconds + milliseconds
    )
  }

  func set(milliseconds: Int64) {
    lock.lock()
    defer { lock.unlock() }
    instant = MonotonicInstant(uptimeMilliseconds: milliseconds)
  }
}
