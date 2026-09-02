import Foundation
import XCTest

@testable import APMXCore

final class SharedFixtureTests: XCTestCase {
  func testPortableRequirementsMetricFixtures() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "requirements-examples",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    let fixture = try JSONDecoder().decode(
      RequirementsFixture.self,
      from: Data(contentsOf: url)
    )

    XCTAssertEqual(fixture.version, 2)
    XCTAssertEqual(fixture.metricExamples.count, 1)

    for example in fixture.metricExamples {
      let sessions = try example.sessions.map { try $0.activitySession }
      switch example.calculation {
      case "apm":
        guard case .value(let value) = APMCalculator.calculate(
          for: sessions.first,
          now: .init(epochMilliseconds: example.nowMilliseconds)
        ) else {
          return XCTFail("\(example.name) did not produce an APM value")
        }
        XCTAssertEqual(value, example.expected, accuracy: 0.000_001, example.name)
      default:
        XCTFail("Unknown fixture calculation \(example.calculation)")
      }
    }
  }
}

private struct RequirementsFixture: Decodable {
  let version: Int
  let metricExamples: [MetricExample]
}

private struct MetricExample: Decodable {
  let name: String
  let calculation: String
  let nowMilliseconds: Int64
  let sessions: [SessionFixture]
  let expected: Double
}

private struct SessionFixture: Decodable {
  let id: UUID
  let startedAtMilliseconds: Int64
  let lastActivityAtMilliseconds: Int64
  let endedAtMilliseconds: Int64?
  let actionCount: Int64
  let timeoutMilliseconds: Int64
  let endReason: String?

  var activitySession: ActivitySession {
    get throws {
      let reason: SessionEndReason?
      switch endReason {
      case nil: reason = nil
      case "inactivityTimeout": reason = .inactivityTimeout
      default: throw FixtureError.unknownEndReason(endReason!)
      }
      return try ActivitySession(
        id: id,
        startedAt: .init(epochMilliseconds: startedAtMilliseconds),
        lastActivityAt: .init(epochMilliseconds: lastActivityAtMilliseconds),
        endedAt: endedAtMilliseconds.map(WallClockInstant.init(epochMilliseconds:)),
        actionCount: actionCount,
        timeout: try SessionTimeout(milliseconds: timeoutMilliseconds),
        endReason: reason
      )
    }
  }
}

private enum FixtureError: Error {
  case unknownEndReason(String)
}
