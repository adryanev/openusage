import Foundation
import Observation

/// Most Claude Code sessions omit organization identity. Show local spend once for all
/// known accounts rather than claiming it belongs to one account card.
@MainActor
@Observable
final class ClaudeSharedHistoryStore {
    private let scanner: ClaudeLogUsageScanner
    private let pricing: @Sendable () async -> ModelPricing
    private let now: @Sendable () -> Date
    private(set) var lines: [MetricLine] = []

    init(
        additionalConfigDirectories: [String],
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        scanner = ClaudeLogUsageScanner(additionalConfigDirectories: additionalConfigDirectories)
        self.pricing = pricing
        self.now = now
    }

    func refresh() async {
        let date = now()
        let scan = await scanner.scan(now: date, pricing: await pricing())
        guard !Task.isCancelled else { return }
        guard let scan else {
            lines = []
            return
        }
        var next: [MetricLine] = []
        let note = "From local Claude logs across accounts (estimated)"
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &next, now: date,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage, modelSourceNote: note
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &next, now: date, note: note)
        lines = next
    }
}
