import Foundation

/// A UTC wall-clock timestamp represented as epoch milliseconds.
///
/// Using an integer value gives persistence and boundary tests exact semantics,
/// without exposing a platform clock type to the domain layer.
public struct WallClockInstant: Hashable, Comparable, Codable, Sendable {
  public let epochMilliseconds: Int64

  public init(epochMilliseconds: Int64) {
    self.epochMilliseconds = epochMilliseconds
  }

  public init(date: Date) {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    self.epochMilliseconds = Self.clampToInt64(milliseconds.rounded(.towardZero))
  }

  public var date: Date {
    Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.epochMilliseconds < rhs.epochMilliseconds
  }

  func advanced(byMilliseconds milliseconds: Int64) -> Self {
    Self(epochMilliseconds: epochMilliseconds.addingClamped(milliseconds))
  }

  private static func clampToInt64(_ value: Double) -> Int64 {
    guard value.isFinite else { return value.sign == .minus ? .min : .max }
    if value <= Double(Int64.min) { return .min }
    if value >= Double(Int64.max) { return .max }
    return Int64(value)
  }
}

/// A process-uptime timestamp represented as milliseconds.
///
/// Session deadlines use this clock so time-zone and wall-clock changes cannot
/// shorten, extend, or reorder a live activity lease.
public struct MonotonicInstant: Hashable, Comparable, Codable, Sendable {
  public let uptimeMilliseconds: Int64

  public init(uptimeMilliseconds: Int64) {
    self.uptimeMilliseconds = uptimeMilliseconds
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.uptimeMilliseconds < rhs.uptimeMilliseconds
  }

  func advanced(byMilliseconds milliseconds: Int64) -> Self {
    Self(uptimeMilliseconds: uptimeMilliseconds.addingClamped(milliseconds))
  }

  func elapsed(since earlier: Self) -> Int64? {
    guard self >= earlier else { return nil }
    let (value, overflow) = uptimeMilliseconds.subtractingReportingOverflow(
      earlier.uptimeMilliseconds
    )
    return overflow ? .max : value
  }
}

/// A validated, nonzero session lease duration.
public struct SessionTimeout: Hashable, Codable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case mustBePositive
  }

  public let milliseconds: Int64

  public init(milliseconds: Int64) throws {
    guard milliseconds > 0 else { throw ValidationError.mustBePositive }
    self.milliseconds = milliseconds
  }

  public static let oneMinute = try! SessionTimeout(milliseconds: 60_000)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(milliseconds: container.decode(Int64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(milliseconds)
  }
}

extension Int64 {
  func addingClamped(_ other: Int64) -> Int64 {
    let (value, overflow) = addingReportingOverflow(other)
    guard overflow else { return value }
    return other >= 0 ? .max : .min
  }
}
