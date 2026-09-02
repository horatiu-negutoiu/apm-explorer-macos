/// Lifecycle events that are safe to send to a diagnostic logger.
///
/// Input payloads are intentionally not representable here. Keep raw input
/// events and all macOS logging adapters outside APMXCore.
public enum ApplicationLogEvent: Sendable, Equatable {
  case applicationLaunched
  case settingsRequested
  case quitRequested
}

/// A privacy-safe diagnostic boundary shared with the application layer.
///
/// Conforming loggers can record only the fixed events above. The API does not
/// accept strings, input events, coordinates, key codes, or timestamps.
public protocol ApplicationLogging: Sendable {
  func record(_ event: ApplicationLogEvent)
}

public struct DisabledApplicationLogger: ApplicationLogging {
  public init() {}

  public func record(_: ApplicationLogEvent) {}
}
