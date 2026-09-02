import APMXCore
import OSLog

/// The app's only facade over OSLog.
///
/// Its public operation accepts an allow-listed event rather than a string or
/// an input event. This keeps key codes, characters, pointer data, scroll data,
/// application identity, and individual input timestamps outside the logging
/// API by construction.
struct OSLogFacade: ApplicationLogging, Sendable {
    private let logger: Logger

    init(subsystem: String = "ca.horatiu.apmx") {
        logger = Logger(subsystem: subsystem, category: "lifecycle")
    }

    func record(_ event: ApplicationLogEvent) {
        switch event {
        case .applicationLaunched:
            logger.notice("Application launched")
        case .settingsRequested:
            logger.info("Settings requested")
        case .quitRequested:
            logger.notice("Quit requested")
        }
    }
}
