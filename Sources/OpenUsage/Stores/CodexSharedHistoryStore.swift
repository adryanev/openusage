import Foundation
import Observation

/// Local Codex rollouts do not identify the account that paid for each turn. Keep their
/// combined spend outside account snapshots so it cannot be assigned to either card.
@MainActor
@Observable
final class CodexSharedHistoryStore {
    private let scanner: CodexLogUsageScanner
    private let pricing: @Sendable () async -> ModelPricing
    private let now: @Sendable () -> Date
    private(set) var lines: [MetricLine] = []

    init(
        additionalHomes: [String],
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        scanner = CodexLogUsageScanner(
            allowsUnattributedHistory: true, additionalHomes: additionalHomes
        )
        self.pricing = pricing
        self.now = now
    }

    func refresh() async {
        let date = now()
        let scan = await scanner.scan(
            now: date, pricing: await pricing(), fallbackModel: CodexFallbackModelSetting.current()
        )
        guard !Task.isCancelled else { return }
        guard let scan else {
            lines = []
            return
        }
        var next: [MetricLine] = []
        let note = "From local Codex logs across accounts (estimated)"
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &next, now: date,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage, modelSourceNote: note,
            fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
        )
        SpendTileMapper.appendUsageTrend(
            scan.series, to: &next, now: date, note: note,
            fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
        )
        lines = next
    }
}
