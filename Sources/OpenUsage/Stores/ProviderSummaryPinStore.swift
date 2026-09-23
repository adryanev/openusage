import Foundation
import Observation

@MainActor
@Observable
final class ProviderSummaryPinStore {
    static let storageKey = "openusage.providerSummaryPins.v1"
    static let featuredKey = "openusage.providerSummaryFeatured.v1"
    static let hiddenKey = "openusage.providerSummaryHidden.v1"
    private let defaults: UserDefaults
    private(set) var metricIDs: Set<String>
    private(set) var featuredMetricIDs: Set<String>
    private(set) var hiddenMetricIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metricIDs = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
        featuredMetricIDs = Set(defaults.stringArray(forKey: Self.featuredKey) ?? [])
        hiddenMetricIDs = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    func isPinned(_ id: String) -> Bool { metricIDs.contains(id) }

    func setPinned(_ pinned: Bool, for id: String) {
        if pinned { metricIDs.insert(id) } else { metricIDs.remove(id) }
        defaults.set(metricIDs.sorted(), forKey: Self.storageKey)
    }

    func isFeatured(_ id: String) -> Bool { featuredMetricIDs.contains(id) }

    func setFeatured(_ featured: Bool, for id: String) {
        if featured { featuredMetricIDs.insert(id) } else { featuredMetricIDs.remove(id) }
        defaults.set(featuredMetricIDs.sorted(), forKey: Self.featuredKey)
    }

    func isEnabled(_ id: String) -> Bool { !hiddenMetricIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled { hiddenMetricIDs.remove(id) } else { hiddenMetricIDs.insert(id) }
        defaults.set(hiddenMetricIDs.sorted(), forKey: Self.hiddenKey)
    }

    func reset() {
        metricIDs = []
        featuredMetricIDs = []
        hiddenMetricIDs = []
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.featuredKey)
        defaults.removeObject(forKey: Self.hiddenKey)
    }
}
