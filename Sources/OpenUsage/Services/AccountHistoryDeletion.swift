import Foundation

enum AccountHistoryDeletion {
    static let storageKey = "openusage.accountHistoryDeletedThrough.v1"

    static func cutoff(for id: String, defaults: UserDefaults) -> Date? {
        let dates = defaults.dictionary(forKey: storageKey) as? [String: Date]
        return dates?[id]
    }

    static func markDeleted(for id: String, defaults: UserDefaults, at date: Date = Date()) {
        var dates = defaults.dictionary(forKey: storageKey) as? [String: Date] ?? [:]
        dates[id] = date
        defaults.set(dates, forKey: storageKey)
    }

    static func apply(to snapshot: ProviderSnapshot, cutoff: Date?,
                      descriptor: UsageHistoryDescriptor?, now: Date = Date()) -> ProviderSnapshot {
        guard let cutoff, let history = snapshot.usageHistory, let descriptor else { return snapshot }
        let day = DailyUsageAccumulator.dayKey(from: cutoff)
        var filtered = history
        filtered.series.daily.removeAll { $0.date <= day }
        filtered.modelUsage?.daily.removeAll { $0.date <= day }
        filtered.unknownModelsByDay = filtered.unknownModelsByDay.filter { $0.key > day }
        filtered.fallbackPricingModelsByDay = filtered.fallbackPricingModelsByDay?.filter { $0.key > day }
        var result = snapshot
        result.usageHistory = filtered
        return UsageHistorySnapshotRenderer.render(local: result, history: filtered,
                                                   descriptor: descriptor, now: now, combined: false)
    }
}
