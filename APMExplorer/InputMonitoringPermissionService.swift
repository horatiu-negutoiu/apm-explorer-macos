import CoreGraphics
import Foundation
import Security

protocol InputMonitoringPermissionProviding: Sendable {
    var hasStableCodeIdentity: Bool { get }
    func preflight() -> Bool
    func request() -> Bool
}

struct CoreGraphicsInputMonitoringPermissionProvider: InputMonitoringPermissionProviding {
    let hasStableCodeIdentity: Bool

    init() {
        hasStableCodeIdentity = Self.checkStableCodeIdentity()
    }

    private static func checkStableCodeIdentity() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let identifier = information[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return false
        }
        return identifier == Bundle.main.bundleIdentifier && !teamIdentifier.isEmpty
    }

    func preflight() -> Bool { CGPreflightListenEventAccess() }
    func request() -> Bool { CGRequestListenEventAccess() }
}

enum InputMonitoringPermissionState: Equatable {
    case notDetermined
    case denied
    case granted
    case revoked
    case relaunchRequired
    case invalidCodeSignature

    var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        case .granted: "Allowed"
        case .revoked: "Access removed"
        case .relaunchRequired: "Relaunch required"
        case .invalidCodeSignature: "Unsigned build"
        }
    }

    var symbolName: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .relaunchRequired: "arrow.clockwise.circle.fill"
        case .notDetermined: "hand.raised.circle.fill"
        case .denied, .revoked, .invalidCodeSignature: "exclamationmark.triangle.fill"
        }
    }

    var canRequestSystemPrompt: Bool { self == .notDetermined }
}

struct InputMonitoringPermissionHistory: Equatable {
    var hasRequested = false
    var hasBeenGranted = false
}

protocol InputMonitoringPermissionHistoryStoring: AnyObject {
    func load() -> InputMonitoringPermissionHistory
    func recordRequest()
    func recordGrant()
}

final class UserDefaultsInputMonitoringPermissionHistoryStore:
    InputMonitoringPermissionHistoryStoring
{
    private enum Key {
        static let hasRequested = "inputMonitoring.hasRequested"
        static let hasBeenGranted = "inputMonitoring.hasBeenGranted"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> InputMonitoringPermissionHistory {
        InputMonitoringPermissionHistory(
            hasRequested: defaults.bool(forKey: Key.hasRequested),
            hasBeenGranted: defaults.bool(forKey: Key.hasBeenGranted)
        )
    }

    func recordRequest() {
        defaults.set(true, forKey: Key.hasRequested)
    }

    func recordGrant() {
        defaults.set(true, forKey: Key.hasRequested)
        defaults.set(true, forKey: Key.hasBeenGranted)
    }
}

/// The only component that invokes the protected Input Monitoring APIs.
/// Passive checks never display a prompt; `requestAccess` is explicit and is
/// allowed only once for a previously undetermined installation.
@MainActor
final class InputMonitoringPermissionService {
    private(set) var state: InputMonitoringPermissionState

    private let provider: any InputMonitoringPermissionProviding
    private let historyStore: any InputMonitoringPermissionHistoryStoring

    init(
        provider: any InputMonitoringPermissionProviding =
            CoreGraphicsInputMonitoringPermissionProvider(),
        historyStore: any InputMonitoringPermissionHistoryStoring =
            UserDefaultsInputMonitoringPermissionHistoryStore()
    ) {
        self.provider = provider
        self.historyStore = historyStore
        let history = historyStore.load()
        state = if !provider.hasStableCodeIdentity {
            .invalidCodeSignature
        } else if history.hasBeenGranted {
            .revoked
        } else if history.hasRequested {
            .denied
        } else {
            .notDetermined
        }
    }

    @discardableResult
    func check() -> InputMonitoringPermissionState {
        guard provider.hasStableCodeIdentity else {
            state = .invalidCodeSignature
            return state
        }
        if provider.preflight() {
            historyStore.recordGrant()
            state = .granted
            return state
        }

        // A positive request result can require a process restart on some
        // macOS versions. Keep that honest state until a later check succeeds.
        if state == .relaunchRequired {
            return state
        }

        let history = historyStore.load()
        state = (state == .granted || history.hasBeenGranted)
            ? .revoked
            : (history.hasRequested ? .denied : .notDetermined)
        return state
    }

    @discardableResult
    func requestAccess() -> InputMonitoringPermissionState {
        guard state.canRequestSystemPrompt else {
            return check()
        }

        historyStore.recordRequest()
        let requestWasAccepted = provider.request()
        if provider.preflight() {
            historyStore.recordGrant()
            state = .granted
        } else {
            state = requestWasAccepted ? .relaunchRequired : .denied
        }
        return state
    }
}
