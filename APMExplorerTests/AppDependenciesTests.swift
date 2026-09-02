import AppKit
import CoreGraphics
import APMXCore
import Combine
@testable import APMExplorer
import XCTest

@MainActor
final class AppDependenciesTests: XCTestCase {
    func testAboutFAQContentDescribesTheAppAndLinksToTheWebsite() {
        XCTAssertEqual(AboutFAQContent.title, "About / FAQ")
        XCTAssertEqual(
            AboutFAQContent.message,
            "APM Explorer is a private, personal activity tracker built to help "
                + "you understand your activity over time - without compromising "
                + "your privacy."
        )
        XCTAssertEqual(AboutFAQContent.author, "Horatiu Negutoiu")
        XCTAssertEqual(
            AboutFAQContent.authorWebsiteURL.absoluteString,
            "https://horatiu.ca"
        )
        XCTAssertEqual(
            AboutFAQContent.appWebsiteURL.absoluteString,
            "https://apmx.horatiu.ca"
        )
        XCTAssertEqual(
            AboutFAQContent.aboutFAQURL.absoluteString,
            "https://apmx.horatiu.ca/about-faq"
        )
    }

    func testPrivacyDisclosureCoversLocalStorageAndNoOnlineTransmission() {
        XCTAssertEqual(PrivacyDisclosure.title, "Your data stays on your Mac.")
        XCTAssertTrue(
            PrivacyDisclosure.message.contains("all user and application data")
        )
        XCTAssertTrue(PrivacyDisclosure.message.contains("locally on your Mac"))
        XCTAssertTrue(PrivacyDisclosure.message.contains("does not transmit"))
        XCTAssertTrue(PrivacyDisclosure.message.contains("upload"))
        XCTAssertTrue(PrivacyDisclosure.message.contains("online"))
    }

    func testActivityStripLayoutUsesAvailableWidthForTwelveSquareCells() {
        let side = ActivityStripRowLayout.cellSide(
            availableWidth: 246,
            cellCount: 12,
            spacing: 2
        )

        XCTAssertEqual(side, 18.666_666_666_7, accuracy: 0.000_001)
        XCTAssertEqual((side * 12) + (2 * 11), 246, accuracy: 0.000_001)
    }

    func testActivityStripAlwaysPresentsTwelveChronologicalRollingHours() {
        let now = testInstant("2024-06-15T17:30:00Z")
        let presentation = ActivityStripPresentation(
            hours: nil,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(presentation.cells.count, 12)
        XCTAssertEqual(presentation.cells.map(\.hour), Array(6...17))
        XCTAssertTrue(presentation.cells.allSatisfy { $0.fill == .unavailable })
        XCTAssertEqual(presentation.cells.filter(\.isCurrentHour).map(\.hour), [17])
        XCTAssertEqual(
            presentation.cells.map(\.hourStart),
            presentation.cells.map(\.hourStart).sorted()
        )
    }

    func testActivityStripRollsAcrossLocalMidnight() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let presentation = ActivityStripPresentation(
            hours: nil,
            now: testInstant("2024-06-15T00:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.cells.map(\.hour), Array(13...23) + [0])
        XCTAssertTrue(presentation.cells.allSatisfy { $0.fill == .unavailable })
        XCTAssertTrue(presentation.cells[11].isCurrentHour)
    }

    func testActivityStripPresentationCoversEndpointsCoverageAndVoiceOver() throws {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let now = testInstant("2024-06-15T04:30:00Z")
        let hours = try HourlyAnalytics.rollingHours(
            from: [
                try hourlyPoint("2024-06-15T00:00:00Z", actions: 0),
                try hourlyPoint("2024-06-15T01:00:00Z", actions: 0),
                try hourlyPoint("2024-06-15T02:00:00Z", actions: 60),
                try hourlyPoint(
                    "2024-06-15T03:00:00Z",
                    actions: 120,
                    monitoredMilliseconds: 30 * 60 * 1_000
                ),
                try hourlyPoint(
                    "2024-06-15T04:00:00Z",
                    actions: 0,
                    monitoredMilliseconds: 0
                ),
            ],
            now: now,
            timeZone: timeZone
        )

        let presentation = ActivityStripPresentation(
            hours: hours,
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.cells[7].fill, .monitoredZero)
        XCTAssertEqual(presentation.cells[8].fill, .monitoredZero)
        XCTAssertEqual(presentation.cells[9].fill, .activity(0.5))
        XCTAssertEqual(presentation.cells[10].fill, .maximum)
        XCTAssertEqual(presentation.cells[10].coverage, .partial)
        XCTAssertEqual(presentation.cells[11].fill, .unmonitored)
        XCTAssertTrue(presentation.cells[11].isCurrentHour)
        XCTAssertTrue(presentation.cells[11].accessibilityLabel.contains("Local hour 04:00 to 04:59"))
        XCTAssertTrue(presentation.cells[11].accessibilityLabel.contains("current hour"))
        XCTAssertTrue(presentation.cells[10].accessibilityLabel.contains("partial monitoring coverage"))
        XCTAssertTrue(presentation.cells[6].accessibilityLabel.contains("coverage unavailable"))
    }

    func testActivityStripSnapshotNormalizationIsDeterministic() throws {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let now = testInstant("2024-06-15T12:00:00Z")
        let allZeroPoints = try (0..<24).map { hour in
            try hourlyPoint(
                String(format: "2024-06-15T%02d:00:00Z", hour),
                actions: 0
            )
        }
        let allZero = try HourlyAnalytics.rollingHours(
            from: allZeroPoints,
            now: now,
            timeZone: timeZone
        )
        let allZeroPresentation = ActivityStripPresentation(
            hours: allZero,
            now: now,
            timeZone: timeZone
        )

        XCTAssertTrue(
            allZeroPresentation.cells.allSatisfy { $0.fill == .monitoredZero }
        )

        let before = try HourlyAnalytics.rollingHours(
            from: [
                try hourlyPoint("2024-06-15T02:00:00Z", actions: 60),
                try hourlyPoint("2024-06-15T03:00:00Z", actions: 120),
            ],
            now: now,
            timeZone: timeZone
        )
        let after = try HourlyAnalytics.rollingHours(
            from: [
                try hourlyPoint("2024-06-15T02:00:00Z", actions: 180),
                try hourlyPoint("2024-06-15T03:00:00Z", actions: 120),
            ],
            now: now,
            timeZone: timeZone
        )
        let beforePresentation = ActivityStripPresentation(
            hours: before,
            now: now,
            timeZone: timeZone
        )
        let afterPresentation = ActivityStripPresentation(
            hours: after,
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(beforePresentation.cells[1].fill, .activity(0.5))
        XCTAssertEqual(beforePresentation.cells[2].fill, .maximum)
        XCTAssertEqual(afterPresentation.cells[1].fill, .maximum)
        XCTAssertEqual(afterPresentation.cells[2].fill, .activity(2.0 / 3.0))
        XCTAssertEqual(beforePresentation.cells.map(\.id), afterPresentation.cells.map(\.id))
    }

    func testAnalyticsPresentationOrdersNewestDayFirstAndHoursLeftToRight() throws {
        XCTAssertEqual(AnalyticsView.contentWidth, 720)
        XCTAssertEqual(AnalyticsView.contentHeight, 560)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let now = testInstant("2024-06-15T04:30:00Z")
        let history = try HourlyAnalytics.history(
            from: [
                try hourlyPoint("2024-06-15T01:00:00Z", actions: 0),
                try hourlyPoint("2024-06-15T02:00:00Z", actions: 120),
                try hourlyPoint(
                    "2024-06-15T03:00:00Z",
                    actions: 60,
                    monitoredMilliseconds: 30 * 60 * 1_000
                ),
                try hourlyPoint(
                    "2024-06-15T04:00:00Z",
                    actions: 0,
                    monitoredMilliseconds: 0
                ),
            ],
            now: now,
            timeZone: timeZone,
            dayCount: 2
        )

        let presentation = AnalyticsHistoryPresentation(
            days: history,
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.days.count, 2)
        XCTAssertEqual(
            presentation.days.map(\.day),
            [
                LocalCalendarDay(year: 2024, month: 6, day: 15),
                LocalCalendarDay(year: 2024, month: 6, day: 14),
            ]
        )
        XCTAssertEqual(
            presentation.days.flatMap(\.cells).map(\.id.hour),
            Array(0..<24) + Array(0..<24)
        )

        let cells = presentation.days[0].cells
        XCTAssertEqual(cells[0].fill, .unavailable)
        XCTAssertEqual(cells[1].fill, .monitoredZero)
        XCTAssertEqual(cells[2].fill, .activity(1))
        XCTAssertEqual(cells[3].fill, .activity(0.5))
        XCTAssertEqual(cells[3].coverageLabel, "Partial monitoring coverage")
        XCTAssertEqual(cells[4].fill, .unmonitored)
        XCTAssertTrue(cells[4].isCurrentHour)
        XCTAssertEqual(cells[2].hourLabel, "Local hour 02:00 to 02:59")
        XCTAssertEqual(cells[2].accessibilityValue, "120 actions, 2 hourly APM, Complete monitoring coverage")
        XCTAssertTrue(cells[2].accessibilityLabel.contains("2024"))
        XCTAssertTrue(presentation.hasPositiveActivity)
    }

    func testVisualizationRefreshUsesOneRepositoryRangeQueryForBothViews() async {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let repository = RecordingActivityRepository()
        let capture = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission,
                historyStore: InMemoryPermissionHistoryStore()
            ),
            activityRepository: repository,
            startsAutomatically: false
        )
        await capture.refreshHourlyVisualization(
            now: testInstant("2024-06-15T04:30:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(capture.hourlyVisualizationSnapshot?.analyticsDays.count, 14)
        XCTAssertEqual(capture.hourlyVisualizationSnapshot?.rollingHours.count, 12)
        XCTAssertTrue(
            capture.hourlyVisualizationSnapshot?.analyticsDays
                .allSatisfy { $0.hours.count == 24 } == true
        )
        let hourlyQueryCount = await repository.hourlyQueryCount
        XCTAssertEqual(hourlyQueryCount, 1)
    }

    func testUnavailablePersistenceDoesNotQueryVisualizationData() async {
        let capture = PassiveInputCaptureModel(startsAutomatically: false)

        await capture.refreshHourlyVisualization(
            now: testInstant("2024-06-15T04:30:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertNil(capture.hourlyVisualizationSnapshot)
    }

    func testOrdinaryModelRefreshesDoNotQueryOrRecomputeVisualizations() async {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let repository = RecordingActivityRepository()
        let model = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission,
                historyStore: InMemoryPermissionHistoryStore()
            ),
            activityRepository: repository,
            startsAutomatically: false
        )

        model.refresh()
        model.refresh()
        model.refresh()

        var hourlyQueryCount = await repository.hourlyQueryCount
        XCTAssertEqual(hourlyQueryCount, 0)
        XCTAssertNil(model.hourlyVisualizationSnapshot)

        await model.refreshHourlyVisualization(
            now: testInstant("2024-06-15T04:30:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        hourlyQueryCount = await repository.hourlyQueryCount
        XCTAssertEqual(hourlyQueryCount, 1)
    }

    func testHourlyVisualizationDefaultCadenceIsFiveMinutes() {
        XCTAssertEqual(
            PassiveInputCaptureModel.defaultHourlyVisualizationRefreshInterval,
            300
        )
    }

    func testScheduledSQLiteFlushFailureAutomaticallyTransitionsModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteActivitySessionRepository(
            databaseURL: directory.appendingPathComponent("activity.sqlite3"),
            now: .init(epochMilliseconds: 0)
        )
        try await repository.save(try session(startedAt: 0, actionCount: 1))
        try await repository.flush()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            repository: repository,
            startsDraining: false
        )
        let model = PassiveInputCaptureModel(
            ingestion: ingestion,
            activityRepository: repository,
            startsAutomatically: false
        )
        let failureTransition = expectation(
            description: "scheduled SQLite failure reaches the model"
        )
        failureTransition.assertForOverFulfill = true
        let observation = model.$persistenceState
            .dropFirst()
            .sink { state in
                if state == .failed {
                    failureTransition.fulfill()
                }
            }

        XCTAssertTrue(ingestion.enqueue(signal(.keyDown, at: 0)))
        ingestion.flush()

        await fulfillment(of: [failureTransition], timeout: 2)
        XCTAssertEqual(model.persistenceState, .failed)
        XCTAssertEqual(model.captureState, .suspended)
        XCTAssertNotNil(model.persistenceError)
        withExtendedLifetime(observation) {}
    }

    func testRecordingStatusFormattingCoversReleaseStates() {
        let fixtures: [(
            InputMonitoringPermissionState,
            PassiveCaptureState,
            ActivityPersistenceState,
            String
        )] = [
            (.granted, .listening, .available, "Allowed · Listening"),
            (.granted, .suspended, .available, "Recording suspended"),
            (.denied, .waitingForPermission, .available, "Not allowed"),
            (.revoked, .waitingForPermission, .available, "Access removed"),
            (.invalidCodeSignature, .waitingForPermission, .available, "Unsigned build"),
            (.granted, .unavailable, .available, "Event tap unavailable"),
            (.granted, .listening, .failed, "Persistence failed"),
            (.granted, .listening, .unavailable, "Persistence unavailable"),
        ]

        for (permission, capture, persistence, expected) in fixtures {
            XCTAssertEqual(
                RecordingStatusPresentation(
                    permission: permission,
                    capture: capture,
                    persistence: persistence
                ).title,
                expected
            )
        }
    }

    func testSettingsPersistLaunchAtLoginAcrossRepositoryInstances() throws {
        let suiteName = "APMExplorerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = AppSettings(
            launchAtLogin: true
        )

        UserDefaultsSettingsRepository(defaults: defaults).save(expected)
        let reloaded = UserDefaultsSettingsRepository(defaults: defaults).load()

        XCTAssertEqual(reloaded, expected)
        XCTAssertEqual(defaults.object(forKey: "settings.launchAtLogin") as? Bool, true)
    }

    func testRetiredSettingsAreRemoved() throws {
        let suiteName = "APMExplorerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(4_999, forKey: "settings.inactivityTimeoutMilliseconds")
        defaults.set(86_400_001, forKey: "settings.pulseWindowMilliseconds")
        defaults.set(0, forKey: "settings.movementSamplingMilliseconds")

        let repository = UserDefaultsSettingsRepository(defaults: defaults)

        XCTAssertEqual(repository.load(), .defaults)
        XCTAssertNil(defaults.object(forKey: "settings.inactivityTimeoutMilliseconds"))
        XCTAssertNil(defaults.object(forKey: "settings.pulseWindowMilliseconds"))
        XCTAssertNil(defaults.object(forKey: "settings.movementSamplingMilliseconds"))
    }

    func testLegacyPreferencesAreRemoved() throws {
        let suiteName = "APMExplorerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(90, forKey: "inactivityTimeoutSeconds")
        defaults.set(30, forKey: "pulseWindowMinutes")
        defaults.set(500, forKey: "movementSamplingMilliseconds")

        let settings = UserDefaultsSettingsRepository(defaults: defaults).load()

        XCTAssertEqual(settings, .defaults)
        XCTAssertNil(defaults.object(forKey: "inactivityTimeoutSeconds"))
        XCTAssertNil(defaults.object(forKey: "pulseWindowMinutes"))
        XCTAssertNil(defaults.object(forKey: "movementSamplingMilliseconds"))
    }

    func testInjectedLoggerReceivesOnlyAllowListedEvents() {
        let logger = RecordingLogger()
        let dependencies = AppDependencies(logger: logger)

        dependencies.logger.record(.settingsRequested)

        XCTAssertEqual(logger.events, [.settingsRequested])
    }

    func testAccumulatorStoresOnlyAggregateCategories() {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            startsDraining: false
        )

        ingestion.enqueue(signal(.keyDown, at: 0))
        ingestion.enqueue(signal(.keyDown, keyDownPhase: .autoRepeat, at: 1))
        ingestion.enqueue(signal(.mouseButtonDown, at: 4))
        ingestion.enqueue(scroll(.directBegan, at: 5))
        ingestion.enqueue(scroll(.directChanged, at: 6))
        ingestion.enqueue(scroll(.directEnded, at: 7))
        ingestion.enqueue(scroll(.momentum, at: 8))
        ingestion.flush()
        accumulator.recordTapDisabled(reenabled: true)
        accumulator.recordTapDisabled(reenabled: false)

        XCTAssertEqual(
            accumulator.currentSnapshot(),
            InputActivitySnapshot(
                keyDownCount: 1,
                mouseButtonDownCount: 1,
                scrollWheelCount: 1,
                tapDisabledCount: 2,
                tapReenabledCount: 1
            )
        )
    }

    func testTimeoutUpdateImmediatelyReconfiguresOpenSession() throws {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            sessionEngine: SessionEngine(
                wallClock: FixedWallClock(),
                monotonicClock: FixedMonotonicClock()
            ),
            startsDraining: false
        )
        ingestion.enqueue(signal(.keyDown, at: 0))
        ingestion.flush()

        ingestion.updateTimeout(try SessionTimeout(milliseconds: 5_000))

        XCTAssertEqual(ingestion.currentOpenSession()?.timeout.milliseconds, 5_000)
    }

    func testSettingsModelReflectsActualLoginServiceStatus() {
        let capture = PassiveInputCaptureModel(startsAutomatically: false)
        let repository = RecordingAppSettingsRepository()
        let launchService = RecordingLaunchAtLoginService(state: .requiresApproval)
        let model = AppSettingsModel(
            repository: repository,
            launchService: launchService,
            capture: capture
        )

        XCTAssertFalse(model.launchAtLoginIsOn)
        XCTAssertEqual(model.launchAtLoginState, .requiresApproval)

        launchService.state = .on
        model.refreshLaunchAtLoginState()

        XCTAssertTrue(model.launchAtLoginIsOn)
        XCTAssertEqual(repository.settings?.launchAtLogin, true)
    }

    func testStartupOffersLoginOnlyAfterActivityWelcomeCloses() {
        let setup = StartupOnboardingFixture(permissionGranted: false)
        defer { setup.controller.close() }
        XCTAssertNil(setup.controller.permissionWelcome?.window)
        XCTAssertNil(setup.controller.launchAtLoginWindow)

        setup.capture.refresh()
        XCTAssertTrue(setup.controller.permissionWelcome?.window?.isVisible == true)
        XCTAssertNil(setup.controller.launchAtLoginWindow)
        setup.controller.permissionWelcome?.close()

        XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
        XCTAssertEqual(setup.launchService.enableRequests, [])
    }

    func testAlreadyEnabledLoginStartupIsRememberedWithoutPrompting() {
        let setup = StartupOnboardingFixture(permissionGranted: true, launchState: .on)
        defer { setup.controller.close() }
        setup.capture.refresh()

        XCTAssertNil(setup.controller.permissionWelcome?.window)
        XCTAssertNil(setup.controller.launchAtLoginWindow)
        XCTAssertTrue(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)
        XCTAssertEqual(setup.launchService.enableRequests, [])
    }

    func testSkippingLoginOfferSurvivesRefreshAndAnotherLaunch() throws {
        let suiteName = "APMExplorerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let setup = StartupOnboardingFixture(
            permissionGranted: true,
            repository: UserDefaultsSettingsRepository(defaults: defaults)
        )
        defer { setup.controller.close() }
        setup.capture.refresh()
        XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
        setup.controller.launchAtLoginWindow?.performClose(nil)
        setup.settings.refreshLaunchAtLoginState()

        let next = StartupOnboardingFixture(
            permissionGranted: true,
            repository: UserDefaultsSettingsRepository(defaults: defaults)
        )
        defer { next.controller.close() }
        next.capture.refresh()
        XCTAssertNil(next.controller.launchAtLoginWindow)
        XCTAssertFalse(next.settings.launchAtLoginIsOn)
        XCTAssertEqual(setup.launchService.enableRequests, [])
    }

    func testEnablingLoginStartupClosesAndCompletesOffer() {
        let setup = StartupOnboardingFixture(permissionGranted: true)
        defer { setup.controller.close() }
        setup.capture.refresh()
        setup.controller.enableLaunchAtLogin()

        XCTAssertEqual(setup.launchService.enableRequests, [true])
        XCTAssertTrue(setup.settings.launchAtLoginIsOn)
        XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
        XCTAssertTrue(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)
    }

    func testPermissionRecoveryReoffersSkippedLoginAfterRestartOnlyOnce() throws {
        for checkBeforeOnboarding in [false, true] {
            let suiteName = "APMExplorerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let repository = UserDefaultsSettingsRepository(defaults: defaults)
            repository.save(AppSettings(launchAtLogin: false, hasCompletedLaunchAtLoginOnboarding: true))
            let removed = StartupOnboardingFixture(
                permissionGranted: false,
                repository: repository,
                permissionHistory: .init(hasRequested: true, hasBeenGranted: true)
            )
            removed.capture.refresh()
            XCTAssertTrue(removed.controller.permissionWelcome?.window?.isVisible == true)
            removed.controller.close()

            let restored = StartupOnboardingFixture(
                permissionGranted: true,
                repository: UserDefaultsSettingsRepository(defaults: defaults),
                permissionHistory: .init(hasRequested: true, hasBeenGranted: true),
                checkBeforeOnboarding: checkBeforeOnboarding
            )
            defer { restored.controller.close() }
            restored.capture.refresh()
            XCTAssertNil(restored.controller.permissionWelcome?.window)
            XCTAssertTrue(restored.controller.launchAtLoginWindow?.isVisible == true)
            restored.controller.launchAtLoginWindow?.performClose(nil)

            let next = StartupOnboardingFixture(
                permissionGranted: true,
                repository: UserDefaultsSettingsRepository(defaults: defaults),
                permissionHistory: .init(hasRequested: true, hasBeenGranted: true),
                checkBeforeOnboarding: checkBeforeOnboarding
            )
            defer { next.controller.close() }
            next.capture.refresh()
            XCTAssertNil(next.controller.launchAtLoginWindow)
            XCTAssertFalse(next.settings.launchAtLoginIsOn)
        }
    }

    func testMissingPermissionDoesNotRepeatSkippedLoginOfferBeforeRecovery() {
        let repository = RecordingAppSettingsRepository()
        repository.save(AppSettings(launchAtLogin: false, hasCompletedLaunchAtLoginOnboarding: true))
        for _ in 0..<2 {
            let setup = StartupOnboardingFixture(permissionGranted: false, repository: repository)
            setup.capture.refresh()
            setup.controller.permissionWelcome?.close()
            XCTAssertNil(setup.controller.launchAtLoginWindow)
            setup.controller.close()
        }
    }

    func testPermissionRecoveryReoffersLoginAfterWelcomeWasDismissed() {
        let setup = StartupOnboardingFixture(permissionGranted: false)
        defer { setup.controller.close() }
        setup.capture.refresh()
        setup.controller.permissionWelcome?.close()
        setup.controller.launchAtLoginWindow?.performClose(nil)

        for _ in 0..<2 {
            setup.permission.preflightResult = false
            setup.capture.refresh()
            XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
            setup.permission.preflightResult = true
            setup.capture.refresh()
            XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
            setup.controller.launchAtLoginWindow?.performClose(nil)
            setup.capture.refresh()
            XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
        }
    }

    func testLoginApprovalKeepsOfferOpenUntilSystemStatusBecomesEnabled() {
        let setup = StartupOnboardingFixture(permissionGranted: true)
        defer { setup.controller.close() }
        setup.launchService.stateAfterEnabling = .requiresApproval
        setup.capture.refresh()
        setup.controller.enableLaunchAtLogin()

        XCTAssertEqual(setup.settings.launchAtLoginState, .requiresApproval)
        XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
        XCTAssertFalse(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)

        setup.launchService.state = .on
        setup.controller.refreshLaunchAtLogin()
        XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
        XCTAssertTrue(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)
    }

    func testUnavailableLoginServiceOffersExplicitRetryAfterFailure() {
        let setup = StartupOnboardingFixture(permissionGranted: true, launchState: .unavailable)
        defer { setup.controller.close() }
        setup.launchService.enableError = NSError(domain: "LoginTest", code: 1)
        setup.capture.refresh()
        XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
        setup.controller.enableLaunchAtLogin()

        XCTAssertEqual(setup.settings.launchAtLoginState, .unavailable)
        XCTAssertNotNil(setup.settings.launchAtLoginError)
        XCTAssertTrue(setup.controller.launchAtLoginWindow?.isVisible == true)
        XCTAssertFalse(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)

        setup.launchService.enableError = nil
        setup.controller.enableLaunchAtLogin()
        XCTAssertNil(setup.settings.launchAtLoginError)
        XCTAssertTrue(setup.settings.launchAtLoginIsOn)
        XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
    }

    func testShutdownDoesNotAdvanceOrCompleteLoginOnboarding() {
        for permissionGranted in [false, true] {
            let setup = StartupOnboardingFixture(permissionGranted: permissionGranted)
            setup.capture.refresh()
            setup.controller.close()
            XCTAssertFalse(setup.controller.launchAtLoginWindow?.isVisible == true)
            XCTAssertFalse(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)
        }
    }

    func testShutdownBeforeInitialCheckDoesNotShowEitherOnboardingWindow() {
        let setup = StartupOnboardingFixture(permissionGranted: false)
        setup.controller.close()
        setup.capture.refresh()
        XCTAssertNil(setup.controller.permissionWelcome?.window)
        XCTAssertNil(setup.controller.launchAtLoginWindow)
        XCTAssertFalse(setup.repository.load().hasCompletedLaunchAtLoginOnboarding)
    }

    func testSignalFactoryDropsRepeatAndMomentumThroughReducer() throws {
        let factory = PrivacySafeInputSignalFactory(
            wallClock: FixedWallClock(),
            monotonicClock: FixedMonotonicClock()
        )
        let key = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 42,
                keyDown: true
            )
        )
        key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let scrollEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 100,
                wheel2: 0,
                wheel3: 0
            )
        )
        scrollEvent.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: 1
        )

        let repeatSignal = factory.signal(for: .keyDown, event: key)
        let momentumSignal = try XCTUnwrap(
            factory.signal(for: .scrollWheel, event: scrollEvent)
        )

        XCTAssertNil(repeatSignal)
        XCTAssertEqual(momentumSignal.scrollPhase, .momentum)
    }

    func testEventTapExcludesPointerMovementAndFactoryRejectsIt() throws {
        let factory = PrivacySafeInputSignalFactory(
            wallClock: FixedWallClock(),
            monotonicClock: FixedMonotonicClock()
        )
        let event = try XCTUnwrap(CGEvent(source: nil))
        let pointerEvents: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]

        XCTAssertEqual(
            PrivacySafeInputSignalFactory.observedEventTypes,
            [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        )
        for type in pointerEvents {
            XCTAssertNil(factory.signal(for: type, event: event))
            XCTAssertFalse(PrivacySafeInputSignalFactory.observedEventTypes.contains(type))
        }
    }

    func testBoundedIngestionDropsNewestSignalWhenFull() {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            capacity: 2,
            accumulator: accumulator,
            startsDraining: false
        )

        XCTAssertTrue(ingestion.enqueue(signal(.keyDown, at: 0)))
        XCTAssertTrue(ingestion.enqueue(signal(.mouseButtonDown, at: 1)))
        XCTAssertFalse(ingestion.enqueue(scroll(.directBegan, at: 2)))
        ingestion.flush()

        let snapshot = accumulator.currentSnapshot()
        XCTAssertEqual(snapshot.keyDownCount, 1)
        XCTAssertEqual(snapshot.mouseButtonDownCount, 1)
        XCTAssertEqual(snapshot.scrollWheelCount, 0)
        XCTAssertEqual(snapshot.droppedSignalCount, 1)
    }

    func testBoundedSignalBufferPreservesFIFOAcrossWraparound() {
        var buffer = BoundedActivitySignalBuffer(capacity: 3)
        XCTAssertTrue(buffer.append(signal(.keyDown, at: 0)))
        XCTAssertTrue(buffer.append(signal(.mouseButtonDown, at: 1)))
        XCTAssertEqual(buffer.removeFirst()?.kind, .keyDown)
        XCTAssertTrue(buffer.append(scroll(.directBegan, at: 2)))
        XCTAssertTrue(buffer.append(signal(.keyDown, at: 3)))
        XCTAssertFalse(buffer.append(signal(.mouseButtonDown, at: 4)))

        XCTAssertEqual(buffer.removeFirst()?.kind, .mouseButtonDown)
        XCTAssertEqual(buffer.removeFirst()?.kind, .scroll)
        XCTAssertEqual(buffer.removeFirst()?.kind, .keyDown)
        XCTAssertNil(buffer.removeFirst())
    }

    func testIngestionConnectsReducerToSessionEngine() {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            startsDraining: false
        )

        ingestion.enqueue(signal(.keyDown, at: 0))
        ingestion.enqueue(scroll(.directBegan, at: 1))
        ingestion.enqueue(scroll(.directChanged, at: 2))
        ingestion.flush()

        XCTAssertEqual(ingestion.currentOpenSession()?.actionCount, 2)
        XCTAssertEqual(accumulator.currentSnapshot().scrollWheelCount, 1)
    }

    func testSuspensionStopsAcceptanceAndClosesLiveSession() {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            startsDraining: false
        )
        ingestion.enqueue(signal(.keyDown, at: 0))
        ingestion.flush()

        ingestion.suspend(reason: .sleep)

        XCTAssertNil(ingestion.currentOpenSession())
        XCTAssertFalse(ingestion.enqueue(signal(.keyDown, at: 1)))
    }

    func testSuspensionDrainsSignalsAcceptedBeforeLifecycleBoundary() {
        let accumulator = InputActivityAccumulator()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: accumulator,
            startsDraining: false
        )
        ingestion.enqueue(signal(.keyDown, at: 0))

        ingestion.suspend(reason: .sleep)

        XCTAssertEqual(accumulator.currentSnapshot().keyDownCount, 1)
        XCTAssertNil(ingestion.currentOpenSession())
    }

    func testShutdownFlushesClosedSessionThroughRepository() async throws {
        let repository = RecordingActivityRepository()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            sessionEngine: SessionEngine(
                wallClock: FixedWallClock(),
                monotonicClock: FixedMonotonicClock()
            ),
            repository: repository,
            startsDraining: false
        )
        ingestion.enqueue(signal(.keyDown, at: 0))

        ingestion.suspend(reason: .shutdown)
        try await ingestion.flushPersistence()

        let sessions = await repository.savedSessions
        let flushCount = await repository.flushCount
        XCTAssertEqual(sessions.last?.endReason, .shutdown)
        XCTAssertEqual(flushCount, 1)
    }

    func testIngestionAtomicallySplitsCoverageAndActionAcrossHourBoundary() async throws {
        let hour: Int64 = 60 * 60 * 1_000
        let clock = AdjustableClock(wall: hour - 1_000, monotonic: 0)
        let repository = RecordingActivityRepository()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            sessionEngine: SessionEngine(wallClock: clock, monotonicClock: clock),
            repository: repository,
            wallClock: clock,
            monotonicClock: clock,
            startsDraining: false
        )
        ingestion.beginMonitoring()
        clock.set(wall: hour + 1_000, monotonic: 2_000)
        ingestion.enqueue(RawActivitySignal(
            kind: .keyDown,
            wallTime: clock.now(),
            monotonicTime: clock.now()
        ))
        ingestion.flush()
        try await ingestion.flushPersistence()

        let atomicUpdates = await repository.atomicHourlyUpdateBatches.last
        XCTAssertEqual(atomicUpdates?.map(\.hourStart.epochMilliseconds), [0, hour])
        XCTAssertEqual(atomicUpdates?.map(\.monitoredMillisecondsIncrement), [1_000, 1_000])
        XCTAssertEqual(atomicUpdates?.map(\.actionCountIncrement), [0, 1])
    }

    func testMonitoringLifecycleDoesNotDoubleCountOrCoverSuspendedGap() async throws {
        let clock = AdjustableClock(wall: 0, monotonic: 0)
        let repository = RecordingActivityRepository()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            repository: repository,
            wallClock: clock,
            monotonicClock: clock,
            startsDraining: false
        )

        ingestion.beginMonitoring()
        ingestion.beginMonitoring()
        clock.set(wall: 1_000, monotonic: 1_000)
        ingestion.suspend(reason: .sleep)
        ingestion.suspend(reason: .sleep)
        clock.set(wall: 2_000, monotonic: 2_000)
        ingestion.resume()
        ingestion.beginMonitoring()
        clock.set(wall: 3_000, monotonic: 3_000)
        ingestion.suspend(reason: .sessionInactive)
        try await ingestion.flushPersistence()

        let updates = await repository.hourlyUpdates
        XCTAssertEqual(
            updates.reduce(0) { $0 + $1.monitoredMillisecondsIncrement },
            2_000
        )
        XCTAssertEqual(
            updates.filter {
                $0.actionCountIncrement == 0 && $0.monitoredMillisecondsIncrement == 0
            }.count,
            2
        )
    }

    func testMaintenanceDoesNotPersistUnchangedMonitoringCoverage() async throws {
        let clock = AdjustableClock(wall: 0, monotonic: 0)
        let repository = RecordingActivityRepository()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            repository: repository,
            wallClock: clock,
            monotonicClock: clock,
            startsDraining: false
        )
        ingestion.beginMonitoring()
        try await ingestion.flushPersistence()
        let initialUpdates = await repository.hourlyUpdates

        clock.set(wall: 15_000, monotonic: 15_000)
        ingestion.performMaintenance()
        try await ingestion.flushPersistence()

        let finalUpdates = await repository.hourlyUpdates
        let maintenanceCallCount = await repository.maintenanceCallCount
        XCTAssertEqual(finalUpdates, initialUpdates)
        XCTAssertEqual(maintenanceCallCount, 1)
    }

    func testDeleteWhileMonitoringDoesNotRestorePreDeleteCoverage() async throws {
        let clock = AdjustableClock(wall: 0, monotonic: 0)
        let repository = RecordingActivityRepository()
        let ingestion = ActivitySignalIngestionExecutor(
            accumulator: InputActivityAccumulator(),
            sessionEngine: SessionEngine(wallClock: clock, monotonicClock: clock),
            repository: repository,
            wallClock: clock,
            monotonicClock: clock,
            startsDraining: false
        )
        ingestion.beginMonitoring()
        clock.set(wall: 1_000, monotonic: 1_000)
        ingestion.enqueue(RawActivitySignal(
            kind: .keyDown,
            wallTime: clock.now(),
            monotonicTime: clock.now()
        ))
        ingestion.flush()
        try await ingestion.deleteActivityData()

        clock.set(wall: 2_000, monotonic: 2_000)
        ingestion.enqueue(RawActivitySignal(
            kind: .keyDown,
            wallTime: clock.now(),
            monotonicTime: clock.now()
        ))
        ingestion.flush()
        try await ingestion.flushPersistence()

        let updates = await repository.hourlyUpdates
        XCTAssertEqual(
            updates.reduce(0) { $0 + $1.monitoredMillisecondsIncrement },
            1_000
        )
    }

    func testSignalFactoryMapsDirectAndPhaseLessScrollWithoutPayload() throws {
        let factory = PrivacySafeInputSignalFactory(
            wallClock: FixedWallClock(),
            monotonicClock: FixedMonotonicClock()
        )
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 100,
                wheel2: 50,
                wheel3: 0
            )
        )

        XCTAssertEqual(
            factory.signal(for: .scrollWheel, event: event)?.scrollPhase,
            .phaseLess
        )
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        XCTAssertEqual(
            factory.signal(for: .scrollWheel, event: event)?.scrollPhase,
            .directBegan
        )
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        XCTAssertEqual(
            factory.signal(for: .scrollWheel, event: event)?.scrollPhase,
            .directChanged
        )
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        XCTAssertEqual(
            factory.signal(for: .scrollWheel, event: event)?.scrollPhase,
            .directEnded
        )
        XCTAssertNil(factory.signal(for: .keyUp, event: event))
    }

    func testDisabledTapControlEventsAttemptRecoveryAndRecordOutcome() {
        let accumulator = InputActivityAccumulator()
        var reenableAttempts = 0

        XCTAssertTrue(
            handlePassiveEventTapControlEvent(
                .tapDisabledByTimeout,
                accumulator: accumulator
            ) {
                reenableAttempts += 1
                return true
            }
        )
        XCTAssertTrue(
            handlePassiveEventTapControlEvent(
                .tapDisabledByUserInput,
                accumulator: accumulator
            ) {
                reenableAttempts += 1
                return false
            }
        )
        XCTAssertFalse(
            handlePassiveEventTapControlEvent(
                .keyDown,
                accumulator: accumulator
            ) {
                XCTFail("Ordinary input must not enter the recovery path")
                return false
            }
        )

        XCTAssertEqual(reenableAttempts, 2)
        XCTAssertEqual(accumulator.currentSnapshot().tapDisabledCount, 2)
        XCTAssertEqual(accumulator.currentSnapshot().tapReenabledCount, 1)
    }

    func testPreflightRefreshNeverRequestsPermission() {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore()
        )
        let model = PassiveInputCaptureModel(
            permissionService: service,
            startsAutomatically: false
        )

        model.refresh()
        model.refresh()

        XCTAssertEqual(permission.preflightCount, 2)
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(model.permissionState, .notDetermined)
        XCTAssertEqual(model.captureState, .waitingForPermission)
    }

    func testWelcomeWaitsForCompletedPermissionCheck() {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let model = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission,
                historyStore: InMemoryPermissionHistoryStore()
            ),
            startsAutomatically: false
        )
        let welcome = PermissionWelcomeWindowController(capture: model)
        defer { welcome.close() }

        XCTAssertNil(welcome.window)
        model.suspend(reason: .sleep)
        model.refresh()
        XCTAssertNil(welcome.window)
        XCTAssertEqual(permission.preflightCount, 0)

        model.resume()
        XCTAssertTrue(welcome.window?.isVisible == true)
        XCTAssertFalse(model.metricsAreAvailable)
        XCTAssertEqual(permission.requestCount, 0)
    }

    func testGrantedStartupNeverShowsWelcomeEvenWithStaleHistoryOrLaterRevocation() {
        for history in [
            InputMonitoringPermissionHistory(),
            .init(hasRequested: true),
            .init(hasRequested: true, hasBeenGranted: true)
        ] {
            let permission = RecordingPermissionProvider(preflightResult: true)
            let model = PassiveInputCaptureModel(
                permissionService: InputMonitoringPermissionService(
                    provider: permission,
                    historyStore: InMemoryPermissionHistoryStore(history: history)
                ),
                startsAutomatically: false
            )
            let welcome = PermissionWelcomeWindowController(capture: model)
            defer { welcome.close() }
            XCTAssertNil(welcome.window)
            model.refresh()
            XCTAssertEqual(model.permissionState, .granted)
            XCTAssertNil(welcome.window)

            permission.preflightResult = false
            model.refresh()
            XCTAssertEqual(model.permissionState, .revoked)
            XCTAssertNil(welcome.window)
            XCTAssertEqual(permission.requestCount, 0)
        }
    }

    func testWelcomeHandlesCheckFinishingBeforeWindowControllerIsCreated() {
        let model = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: RecordingPermissionProvider(preflightResult: false),
                historyStore: InMemoryPermissionHistoryStore()
            ),
            startsAutomatically: false
        )
        model.refresh()
        let welcome = PermissionWelcomeWindowController(capture: model)
        defer { welcome.close() }
        XCTAssertTrue(welcome.window?.isVisible == true)
    }

    func testWelcomeOffersRecoveryForEveryMissingPermissionState() {
        for state in [InputMonitoringPermissionState.notDetermined, .denied,
                      .revoked, .relaunchRequired, .invalidCodeSignature] {
            let permission = RecordingPermissionProvider(
                preflightResult: false,
                requestResult: state == .relaunchRequired,
                hasStableCodeIdentity: state != .invalidCodeSignature
            )
            let service = InputMonitoringPermissionService(
                provider: permission,
                historyStore: InMemoryPermissionHistoryStore(history: .init(
                    hasRequested: state == .denied || state == .revoked,
                    hasBeenGranted: state == .revoked
                ))
            )
            if state == .relaunchRequired { service.requestAccess() }
            let model = PassiveInputCaptureModel(
                permissionService: service,
                startsAutomatically: false
            )
            let welcome = PermissionWelcomeWindowController(capture: model)
            defer { welcome.close() }
            model.refresh()
            XCTAssertEqual(model.permissionState, state)
            XCTAssertTrue(welcome.window?.isVisible == true, "Missing welcome for \(state)")
            XCTAssertFalse(model.metricsAreAvailable)
            XCTAssertEqual(permission.requestCount, state == .relaunchRequired ? 1 : 0)
        }
    }

    func testDismissedWelcomeStaysClosedDuringPollingAndFocusChanges() async {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let history = InMemoryPermissionHistoryStore()
        let model = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission, historyStore: history
            ),
            recoveryCheckInterval: 0.01,
            startsAutomatically: false
        )
        defer { model.suspend(reason: .shutdown) }
        let welcome = PermissionWelcomeWindowController(capture: model)
        model.start()
        for _ in 0..<100 where welcome.window == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(welcome.window?.isVisible == true)
        welcome.close()
        let checksBeforeDismissal = permission.preflightCount
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where permission.preflightCount < checksBeforeDismissal + 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(permission.preflightCount, checksBeforeDismissal + 2)
        XCTAssertFalse(welcome.window?.isVisible == true)
        XCTAssertEqual(permission.requestCount, 0)

        let nextLaunch = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission, historyStore: history
            ),
            startsAutomatically: false
        )
        let nextWelcome = PermissionWelcomeWindowController(capture: nextLaunch)
        defer { nextWelcome.close() }
        nextLaunch.refresh()
        XCTAssertTrue(nextWelcome.window?.isVisible == true)
    }

    func testRequestPermissionIsExplicitAndRefreshesState() {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore()
        )
        let model = PassiveInputCaptureModel(
            permissionService: service,
            startsAutomatically: false
        )

        model.requestAccess()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(permission.preflightCount, 1)
        XCTAssertEqual(model.permissionState, .denied)
    }

    func testDeniedPermissionDoesNotRepeatSystemPrompt() {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore()
        )
        let model = PassiveInputCaptureModel(
            permissionService: service,
            startsAutomatically: false
        )

        model.requestAccess()
        model.requestAccess()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(model.permissionState, .denied)
    }

    func testPermissionServiceModelsGrantThenRuntimeRevocation() {
        let permission = RecordingPermissionProvider(preflightResult: true)
        let history = InMemoryPermissionHistoryStore()
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: history
        )

        XCTAssertEqual(service.check(), .granted)
        permission.preflightResult = false
        XCTAssertEqual(service.check(), .revoked)
        XCTAssertEqual(history.load().hasBeenGranted, true)
    }

    func testStartupRapidlyRechecksPermissionAfterSystemRelaunch() async {
        let permission = RecordingPermissionProvider(preflightResult: false)
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore(
                history: .init(hasRequested: true, hasBeenGranted: true)
            )
        )
        let model = PassiveInputCaptureModel(
            permissionService: service,
            pollingInterval: 60,
            recoveryCheckInterval: 0.01,
            rapidRecoveryCheckLimit: 5
        )

        for _ in 0..<20 where permission.preflightCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.permissionState, .revoked)

        permission.preflightResult = true
        for _ in 0..<40 where model.permissionState != .granted {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(model.permissionState, .granted)
        XCTAssertGreaterThanOrEqual(permission.preflightCount, 2)
    }

    func testAcceptedRequestCanRequireRelaunch() {
        let permission = RecordingPermissionProvider(
            preflightResult: false,
            requestResult: true
        )
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore()
        )

        XCTAssertEqual(service.requestAccess(), .relaunchRequired)
        XCTAssertEqual(service.check(), .relaunchRequired)
    }

    func testUnsignedBuildDoesNotRequestOrPreflightInputMonitoring() {
        let permission = RecordingPermissionProvider(
            preflightResult: true,
            hasStableCodeIdentity: false
        )
        let service = InputMonitoringPermissionService(
            provider: permission,
            historyStore: InMemoryPermissionHistoryStore()
        )

        XCTAssertEqual(service.state, .invalidCodeSignature)
        XCTAssertEqual(service.check(), .invalidCodeSignature)
        XCTAssertEqual(service.requestAccess(), .invalidCodeSignature)
        XCTAssertEqual(permission.preflightCount, 0)
        XCTAssertEqual(permission.requestCount, 0)
    }

    func testSystemSettingsButtonsUseDirectAndFallbackLinks() {
        let opener = RecordingSettingsOpener()
        let model = PassiveInputCaptureModel(
            settingsOpener: opener,
            startsAutomatically: false
        )

        model.openInputMonitoringSettings()
        model.openPrivacyAndSecurityFallback()

        XCTAssertEqual(
            opener.openedURLs,
            [SystemSettingsLink.inputMonitoring, SystemSettingsLink.privacyAndSecurity]
        )
    }

    func testInputMonitoringLinkFailureUsesGenericFallback() {
        let opener = RecordingSettingsOpener(results: [false, true])
        let model = PassiveInputCaptureModel(
            settingsOpener: opener,
            startsAutomatically: false
        )

        model.openInputMonitoringSettings()

        XCTAssertEqual(
            opener.openedURLs,
            [SystemSettingsLink.inputMonitoring, SystemSettingsLink.privacyAndSecurity]
        )
        XCTAssertFalse(model.settingsOpenFailed)
    }
}

private func session(startedAt: Int64, actionCount: Int64) throws -> ActivitySession {
    try ActivitySession(
        id: UUID(),
        startedAt: .init(epochMilliseconds: startedAt),
        lastActivityAt: .init(epochMilliseconds: 10_000),
        endedAt: nil,
        actionCount: actionCount,
        timeout: .oneMinute,
        endReason: nil
    )
}

private func testInstant(_ value: String) -> WallClockInstant {
    WallClockInstant(date: ISO8601DateFormatter().date(from: value)!)
}

private func hourlyPoint(
    _ timestamp: String,
    actions: Int64,
    monitoredMilliseconds: Int64 = HourlyActivityAggregate.hourMilliseconds
) throws -> HourlyActivityPoint {
    let hourStart = testInstant(timestamp)
    return HourlyActivityPoint(
        hourStart: hourStart,
        aggregate: try HourlyActivityAggregate(
            hourStart: hourStart,
            actionCount: actions,
            monitoredMilliseconds: monitoredMilliseconds
        )
    )
}

private func signal(
    _ kind: RawActivityKind,
    keyDownPhase: RawKeyDownPhase? = nil,
    at milliseconds: Int64
) -> RawActivitySignal {
    RawActivitySignal(
        kind: kind,
        keyDownPhase: keyDownPhase,
        wallTime: .init(epochMilliseconds: 10_000 + milliseconds),
        monotonicTime: .init(uptimeMilliseconds: milliseconds)
    )
}

private func scroll(
    _ phase: RawScrollPhase,
    at milliseconds: Int64
) -> RawActivitySignal {
    RawActivitySignal(
        kind: .scroll,
        scrollPhase: phase,
        wallTime: .init(epochMilliseconds: 10_000 + milliseconds),
        monotonicTime: .init(uptimeMilliseconds: milliseconds)
    )
}

private struct FixedWallClock: WallClock {
    func now() -> WallClockInstant {
        .init(epochMilliseconds: 10_000)
    }
}

private struct FixedMonotonicClock: MonotonicClock {
    func now() -> MonotonicInstant {
        .init(uptimeMilliseconds: 100)
    }
}

private final class AdjustableClock: WallClock, MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wallMilliseconds: Int64
    private var monotonicMilliseconds: Int64

    init(wall: Int64, monotonic: Int64) {
        wallMilliseconds = wall
        monotonicMilliseconds = monotonic
    }

    func set(wall: Int64, monotonic: Int64) {
        lock.lock()
        wallMilliseconds = wall
        monotonicMilliseconds = monotonic
        lock.unlock()
    }

    func now() -> WallClockInstant {
        lock.lock()
        defer { lock.unlock() }
        return .init(epochMilliseconds: wallMilliseconds)
    }

    func now() -> MonotonicInstant {
        lock.lock()
        defer { lock.unlock() }
        return .init(uptimeMilliseconds: monotonicMilliseconds)
    }
}

private final class RecordingLogger: ApplicationLogging, @unchecked Sendable {
    private(set) var events: [ApplicationLogEvent] = []

    func record(_ event: ApplicationLogEvent) {
        events.append(event)
    }
}

private final class RecordingAppSettingsRepository: AppSettingsPersisting, @unchecked Sendable {
    private(set) var settings: AppSettings?

    func load() -> AppSettings { settings ?? .defaults }
    func save(_ settings: AppSettings) { self.settings = settings }
}

@MainActor
private final class RecordingLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState
    var stateAfterEnabling: LaunchAtLoginState?
    var enableError: Error?
    private(set) var enableRequests: [Bool] = []

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        enableRequests.append(enabled)
        if let enableError { throw enableError }
        state = enabled ? stateAfterEnabling ?? .on : .off
    }

    func openSystemSettings() {}
}

@MainActor
private struct StartupOnboardingFixture {
    let permission: RecordingPermissionProvider
    let capture: PassiveInputCaptureModel
    let repository: any AppSettingsPersisting
    let launchService: RecordingLaunchAtLoginService
    let settings: AppSettingsModel
    let controller: StartupOnboardingWindowController

    init(
        permissionGranted: Bool,
        launchState: LaunchAtLoginState = .off,
        repository: any AppSettingsPersisting = RecordingAppSettingsRepository(),
        permissionHistory: InputMonitoringPermissionHistory = .init(),
        checkBeforeOnboarding: Bool = false
    ) {
        permission = RecordingPermissionProvider(preflightResult: permissionGranted)
        capture = PassiveInputCaptureModel(
            permissionService: InputMonitoringPermissionService(
                provider: permission,
                historyStore: InMemoryPermissionHistoryStore(history: permissionHistory)
            ),
            startsAutomatically: false
        )
        self.repository = repository
        launchService = RecordingLaunchAtLoginService(state: launchState)
        settings = AppSettingsModel(repository: repository, launchService: launchService, capture: capture)
        if checkBeforeOnboarding { capture.refresh() }
        controller = StartupOnboardingWindowController(capture: capture, settings: settings)
    }
}

private final class RecordingPermissionProvider: InputMonitoringPermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreflightResult: Bool
    private let requestResult: Bool?
    let hasStableCodeIdentity: Bool
    private(set) var preflightCount = 0
    private(set) var requestCount = 0

    init(
        preflightResult: Bool,
        requestResult: Bool? = nil,
        hasStableCodeIdentity: Bool = true
    ) {
        storedPreflightResult = preflightResult
        self.requestResult = requestResult
        self.hasStableCodeIdentity = hasStableCodeIdentity
    }

    var preflightResult: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPreflightResult
        }
        set {
            lock.lock()
            storedPreflightResult = newValue
            lock.unlock()
        }
    }

    func preflight() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        preflightCount += 1
        return storedPreflightResult
    }

    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return requestResult ?? storedPreflightResult
    }
}

private final class InMemoryPermissionHistoryStore:
    InputMonitoringPermissionHistoryStoring
{
    private var history: InputMonitoringPermissionHistory

    init(history: InputMonitoringPermissionHistory = .init()) {
        self.history = history
    }

    func load() -> InputMonitoringPermissionHistory { history }

    func recordRequest() {
        history.hasRequested = true
    }

    func recordGrant() {
        history.hasRequested = true
        history.hasBeenGranted = true
    }
}

private actor RecordingActivityRepository: ActivitySessionRepository {
    private(set) var savedSessions: [ActivitySession] = []
    private(set) var hourlyUpdates: [HourlyActivityUpdate] = []
    private(set) var atomicHourlyUpdateBatches: [[HourlyActivityUpdate]] = []
    private(set) var flushCount = 0
    private(set) var hourlyQueryCount = 0
    private(set) var maintenanceCallCount = 0

    func save(_ session: ActivitySession) {
        savedSessions.append(session)
    }

    func save(
        _ sessions: [ActivitySession],
        applying hourlyUpdates: [HourlyActivityUpdate]
    ) {
        savedSessions.append(contentsOf: sessions)
        self.hourlyUpdates.append(contentsOf: hourlyUpdates)
        atomicHourlyUpdateBatches.append(hourlyUpdates)
    }

    func applyHourlyUpdates(_ updates: [HourlyActivityUpdate]) {
        hourlyUpdates.append(contentsOf: updates)
    }

    func flush() { flushCount += 1 }
    func openSession() -> ActivitySession? { savedSessions.last(where: \.isOpen) }
    func recoverOpenSession(at now: WallClockInstant) -> ActivitySession? { nil }
    func sessions(
        overlapping intervalStart: WallClockInstant,
        through intervalEnd: WallClockInstant
    ) -> [ActivitySession] { savedSessions }
    func hourlyActivity(
        overlapping intervalStart: WallClockInstant,
        through intervalEnd: WallClockInstant
    ) -> [HourlyActivityPoint] {
        hourlyQueryCount += 1
        return []
    }
    func purgeExpiredClosedSessions(at now: WallClockInstant) -> Int { 0 }
    func performDailyMaintenanceIfNeeded(at now: WallClockInstant) -> Int {
        maintenanceCallCount += 1
        return 0
    }
    func deleteAllActivitySummaries() {
        savedSessions.removeAll()
        hourlyUpdates.removeAll()
        atomicHourlyUpdateBatches.removeAll()
    }
    func checkHealth() {}
}

@MainActor
private final class RecordingSettingsOpener: SystemSettingsOpening {
    private(set) var openedURLs: [URL] = []
    private var results: [Bool]

    init(results: [Bool] = []) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return results.isEmpty ? true : results.removeFirst()
    }
}
