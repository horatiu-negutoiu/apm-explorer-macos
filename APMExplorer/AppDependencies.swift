import APMXCore

struct AppDependencies: Sendable {
    let logger: any ApplicationLogging
    let settingsRepository: any AppSettingsPersisting
    let activityRepository: (any ActivitySessionRepository)?
    let activityRepositoryError: String?

    init(
        logger: any ApplicationLogging,
        settingsRepository: any AppSettingsPersisting = UserDefaultsSettingsRepository(),
        activityRepository: (any ActivitySessionRepository)? = nil,
        activityRepositoryError: String? = nil
    ) {
        self.logger = logger
        self.settingsRepository = settingsRepository
        self.activityRepository = activityRepository
        self.activityRepositoryError = activityRepositoryError
    }

    static func live() -> AppDependencies {
        let settingsRepository = UserDefaultsSettingsRepository()
        _ = settingsRepository.load()
        let activityRepository: (any ActivitySessionRepository)?
        let activityRepositoryError: String?
        do {
            let databaseURL = try SQLiteActivitySessionRepository
                .applicationSupportDatabaseURL(applicationIdentifier: "ca.horatiu.apmx")
            activityRepository = try SQLiteActivitySessionRepository(databaseURL: databaseURL)
            activityRepositoryError = nil
        } catch {
            activityRepository = nil
            activityRepositoryError = String(describing: error)
        }
        return AppDependencies(
            logger: OSLogFacade(),
            settingsRepository: settingsRepository,
            activityRepository: activityRepository,
            activityRepositoryError: activityRepositoryError
        )
    }
}
