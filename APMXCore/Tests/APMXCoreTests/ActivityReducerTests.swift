import XCTest

@testable import APMXCore

final class ActivityReducerTests: XCTestCase {
  func testPhysicalKeyDownCountsButAutoRepeatProducesNothing() {
    var reducer = ActivityReducer()

    XCTAssertEqual(
      reducer.reduce(signal(.keyDown, at: 0))?.countedAction,
      .keyDown
    )
    XCTAssertNil(
      reducer.reduce(
        signal(.keyDown, keyDownPhase: .autoRepeat, at: 1)
      )
    )
  }

  func testMouseButtonDownProducesEvidenceAndAction() {
    var reducer = ActivityReducer()

    let activity = reducer.reduce(signal(.mouseButtonDown, at: 10))

    XCTAssertEqual(activity?.evidenceAt.epochMilliseconds, 1_010)
    XCTAssertEqual(activity?.monotonicTime.uptimeMilliseconds, 10)
    XCTAssertEqual(activity?.countedAction, .mouseButtonDown)
  }

  func testDirectScrollRefreshesEvidenceAndCountsOncePerGesture() {
    var reducer = ActivityReducer()

    let began = reducer.reduce(scroll(.directBegan, at: 0))
    let changed = reducer.reduce(scroll(.directChanged, at: 10))
    let ended = reducer.reduce(scroll(.directEnded, at: 20))
    let nextBegan = reducer.reduce(scroll(.directBegan, at: 30))

    XCTAssertEqual(began?.countedAction, .scroll)
    XCTAssertNil(changed?.countedAction)
    XCTAssertNil(ended?.countedAction)
    XCTAssertEqual(nextBegan?.countedAction, .scroll)
    XCTAssertEqual(changed?.monotonicTime.uptimeMilliseconds, 10)
    XCTAssertEqual(ended?.monotonicTime.uptimeMilliseconds, 20)
  }

  func testDirectScrollChangedWithoutBeganProvidesEvidenceButNoAction() {
    var reducer = ActivityReducer()

    let changed = reducer.reduce(scroll(.directChanged, at: 10))

    XCTAssertNotNil(changed)
    XCTAssertNil(changed?.countedAction)
    XCTAssertNil(
      reducer.reduce(scroll(.directChanged, at: 20))?.countedAction
    )
  }

  func testMomentumProducesNeitherEvidenceNorAction() {
    var reducer = ActivityReducer()
    XCTAssertNotNil(reducer.reduce(scroll(.directBegan, at: 0)))

    XCTAssertNil(reducer.reduce(scroll(.momentum, at: 10)))
    XCTAssertNil(reducer.reduce(scroll(.momentum, at: 20)))

    let changedAfterMomentum = reducer.reduce(scroll(.directChanged, at: 30))
    XCTAssertNotNil(changedAfterMomentum)
    XCTAssertNil(changedAfterMomentum?.countedAction)
  }

  func testContinuousDirectScrollExtendsLeaseButCountsOneAction() throws {
    var reducer = ActivityReducer()
    let engine = SessionEngine(
      timeout: try SessionTimeout(milliseconds: 60_000)
    )

    engine.ingest(try XCTUnwrap(reducer.reduce(scroll(.directBegan, at: 0))))
    engine.ingest(
      try XCTUnwrap(reducer.reduce(scroll(.directChanged, at: 50_000)))
    )
    engine.ingest(
      try XCTUnwrap(reducer.reduce(scroll(.directChanged, at: 100_000)))
    )

    XCTAssertEqual(engine.openSession?.actionCount, 1)
    XCTAssertEqual(
      engine.openSession?.lastActivityAt.epochMilliseconds,
      101_000
    )
    XCTAssertEqual(engine.nextDeadline?.uptimeMilliseconds, 160_000)
  }

  func testPhaseLessScrollUsesQuietGapBetweenConsecutiveUpdates() {
    var reducer = ActivityReducer()

    XCTAssertEqual(
      reducer.reduce(scroll(.phaseLess, at: 0))?.countedAction,
      .scroll
    )
    XCTAssertNil(reducer.reduce(scroll(.phaseLess, at: 249))?.countedAction)
    XCTAssertNil(reducer.reduce(scroll(.phaseLess, at: 498))?.countedAction)
    XCTAssertEqual(
      reducer.reduce(scroll(.phaseLess, at: 748))?.countedAction,
      .scroll
    )
  }

  func testScrollWithoutPhaseMetadataIsPhaseLess() {
    var reducer = ActivityReducer()
    let first = signal(.scroll, at: 0)
    let second = signal(.scroll, at: 250)

    XCTAssertEqual(first.scrollPhase, .phaseLess)
    XCTAssertEqual(reducer.reduce(first)?.countedAction, .scroll)
    XCTAssertEqual(reducer.reduce(second)?.countedAction, .scroll)
  }

  func testOutOfOrderSignalIsDiscarded() {
    var reducer = ActivityReducer()
    XCTAssertNotNil(reducer.reduce(signal(.mouseButtonDown, at: 100)))

    XCTAssertNil(reducer.reduce(signal(.keyDown, at: 99)))
  }

  private func signal(
    _ kind: RawActivityKind,
    keyDownPhase: RawKeyDownPhase? = nil,
    at milliseconds: Int64
  ) -> RawActivitySignal {
    RawActivitySignal(
      kind: kind,
      keyDownPhase: keyDownPhase,
      wallTime: .init(epochMilliseconds: 1_000 + milliseconds),
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
      wallTime: .init(epochMilliseconds: 1_000 + milliseconds),
      monotonicTime: .init(uptimeMilliseconds: milliseconds)
    )
  }
}
