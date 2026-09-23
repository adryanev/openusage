import Foundation
import XCTest
@testable import OpenUsage

final class JSONLUsageWindowTests: XCTestCase {
    func testThirtyDayWindowCoversExactlyThirtyCalendarDates() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 14)))
        let since = JSONLScanning.sinceDate(daysBack: 30, now: now)
        let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)))
        let excludedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: expected))

        XCTAssertEqual(since, expected)
        XCTAssertLessThan(excludedDay, since)
        XCTAssertEqual(calendar.dateComponents([.day], from: since, to: calendar.startOfDay(for: now)).day, 29)
    }
}
