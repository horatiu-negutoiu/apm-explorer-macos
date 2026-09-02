import Foundation
import ServiceManagement

struct AppSettings: Equatable, Sendable {
    static let defaults = AppSettings(
        launchAtLogin: false
    )

    var launchAtLogin: Bool
}

protocol AppSettingsPersisting: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

final class UserDefaultsSettingsRepository: AppSettingsPersisting, @unchecked Sendable {
    private enum Key {
        static let schemaVersion = "settings.schemaVersion"
        static let launchAtLogin = "settings.launchAtLogin"

        static let retiredInactivityTimeoutMilliseconds = "settings.inactivityTimeoutMilliseconds"
        static let legacyInactivityTimeoutSeconds = "inactivityTimeoutSeconds"
        static let retiredPulseWindowMilliseconds = "settings.pulseWindowMilliseconds"
        static let retiredMovementSamplingMilliseconds = "settings.movementSamplingMilliseconds"
        static let retiredLegacyPulseWindowMinutes = "pulseWindowMinutes"
        static let retiredLegacyMovementSamplingMilliseconds = "movementSamplingMilliseconds"
    }

    private static let schemaVersion = 3
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }

        var settings = AppSettings.defaults
        if defaults.object(forKey: Key.launchAtLogin) != nil {
            settings.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }

        saveUnlocked(settings)
        return settings
    }

    func save(_ settings: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(settings)
    }

    private func saveUnlocked(_ settings: AppSettings) {
        defaults.set(Self.schemaVersion, forKey: Key.schemaVersion)
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin)
        removeObsoleteValues()
    }

    private func removeObsoleteValues() {
        defaults.removeObject(forKey: Key.retiredInactivityTimeoutMilliseconds)
        defaults.removeObject(forKey: Key.legacyInactivityTimeoutSeconds)
        defaults.removeObject(forKey: Key.retiredPulseWindowMilliseconds)
        defaults.removeObject(forKey: Key.retiredMovementSamplingMilliseconds)
        defaults.removeObject(forKey: Key.retiredLegacyPulseWindowMinutes)
        defaults.removeObject(forKey: Key.retiredLegacyMovementSamplingMilliseconds)
    }
}

enum LaunchAtLoginState: Equatable, Sendable {
    case off
    case on
    case requiresApproval
    case unavailable

    var isEnabled: Bool { self == .on }

    var detail: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .requiresApproval: "Needs approval in System Settings"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
final class SMAppServiceLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var state: LaunchAtLoginState {
        switch service.status {
        case .notRegistered: .off
        case .enabled: .on
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class AppSettingsModel: ObservableObject {
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var deletionError: String?
    @Published private(set) var isDeletingActivityData = false

    private let repository: any AppSettingsPersisting
    private let launchService: any LaunchAtLoginServicing
    private unowned let capture: PassiveInputCaptureModel

    init(
        repository: any AppSettingsPersisting,
        launchService: any LaunchAtLoginServicing,
        capture: PassiveInputCaptureModel
    ) {
        self.repository = repository
        self.launchService = launchService
        self.capture = capture
        launchAtLoginState = launchService.state
        persist(actualLaunchState: launchService.state)
    }

    var launchAtLoginIsOn: Bool { launchAtLoginState.isEnabled }

    func refreshLaunchAtLoginState() {
        launchAtLoginState = launchService.state
        launchAtLoginError = nil
        persist(actualLaunchState: launchAtLoginState)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try launchService.setEnabled(enabled)
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginState = launchService.state
        persist(actualLaunchState: launchAtLoginState)
    }

    func openLoginItemsSettings() {
        launchService.openSystemSettings()
    }

    func deleteActivityData() {
        guard !isDeletingActivityData else { return }
        isDeletingActivityData = true
        deletionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.deleteActivityData()
            } catch {
                deletionError = error.localizedDescription
            }
            isDeletingActivityData = false
        }
    }

    private func persist(actualLaunchState: LaunchAtLoginState) {
        repository.save(AppSettings(launchAtLogin: actualLaunchState == .on))
    }
}
