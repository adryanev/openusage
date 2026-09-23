import XCTest
@testable import OpenUsage

final class AccountHistoryDeletionTests: XCTestCase {
    func testDeletedLocalDaysDoNotReturnAfterRescan() throws {
        let cutoff = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23)))
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-09-22", totalTokens: 10, costUSD: 1),
            DailyUsageEntry(date: "2026-09-23", totalTokens: 20, costUSD: 2),
            DailyUsageEntry(date: "2026-09-24", totalTokens: 30, costUSD: 3),
        ]))
        let snapshot = ProviderSnapshot(providerID: "claude", displayName: "Claude",
                                        lines: [.values(label: "Today", values: [MetricValue(number: 2, kind: .dollars)])],
                                        usageHistory: history)
        let result = AccountHistoryDeletion.apply(
            to: snapshot, cutoff: cutoff,
            descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "Local logs"),
            now: cutoff.addingTimeInterval(86_400)
        )
        XCTAssertEqual(result.usageHistory?.series.daily.map(\.date), ["2026-09-24"])
    }
}
