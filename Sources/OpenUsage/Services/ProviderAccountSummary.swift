import Foundation

/// A separate, explicit read model. Percent limits are counted by availability; they are never
/// added because the provider APIs do not reveal the underlying quota capacity.
enum ProviderAccountSummary {
    static func make(
        family: String, accountIDs: [String], snapshots: [String: ProviderSnapshot],
        errors: [String: String] = [:], sharedSpendLines: [MetricLine] = []
    ) -> ProviderSnapshot? {
        guard accountIDs.count > 1
                || ((family == "codex" || family == "claude") && !sharedSpendLines.isEmpty)
        else { return nil }
        let available = accountIDs.compactMap { snapshots[$0] }
        let incomplete = available.count != accountIDs.count
            || accountIDs.contains { errors[$0] != nil || snapshots[$0]?.lines.contains(where: \.isError) == true }
        var lines: [MetricLine] = []
        for label in ["Session", "Weekly"] {
            let count = available.filter { snapshot in
                guard case .progress(_, let used, let limit, .percent, _, _, _)? = snapshot.line(label: label), limit > 0
                else { return false }
                return used < limit
            }.count
            lines.append(.values(label: "\(label) Available", values: [
                MetricValue(number: Double(count), kind: .count, label: "accounts")
            ]))
        }
        for label in ["Today", "Last 30 Days"] {
            if let line = sharedSpendLines.first(where: { $0.label == label })
                ?? combinedValues(label: label, snapshots: available) { lines.append(line) }
        }
        let primary = Set(["Session", "Weekly", "Today", "Last 30 Days"])
        let optionalLabels = Set(available.flatMap { $0.lines.map(\.label) }
            + sharedSpendLines.map(\.label)).subtracting(primary)
        for label in optionalLabels.sorted() {
            if let line = sharedSpendLines.first(where: { $0.label == label })
                ?? combinedValues(label: label, snapshots: available)
                ?? combinedProgress(label: label, snapshots: available)
                ?? combinedChart(label: label, snapshots: available) {
                lines.append(line)
            }
        }
        let missingOptional = optionalLabels.contains { label in
            guard lines.contains(where: { $0.label == label }) else { return false }
            return sharedSpendLines.contains(where: { $0.label == label }) ? false
                : available.contains { $0.line(label: label) == nil }
        }
        var warnings: [String] = []
        if incomplete || missingOptional {
            warnings.append("Totals incomplete: one or more accounts have no current data.")
        }
        return ProviderSnapshot(providerID: "\(family):summary", displayName: "\(family.capitalized) Summary",
                                lines: lines, refreshedAt: available.map(\.refreshedAt).min() ?? Date(),
                                warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private static func combinedValues(label: String, snapshots: [ProviderSnapshot]) -> MetricLine? {
        let rows: [[MetricValue]] = snapshots.compactMap { snapshot in
            guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: label) else { return nil }
            return values
        }
        guard !rows.isEmpty else { return nil }
        let keys = Set(rows.flatMap { $0.map { ValueKey(kind: $0.kind, label: $0.label) } })
        let values = keys.sorted {
            let rank: [MetricKind: Int] = [.dollars: 0, .count: 1, .percent: 2]
            return (rank[$0.kind] ?? 3, $0.label ?? "") < (rank[$1.kind] ?? 3, $1.label ?? "")
        }.compactMap { key -> MetricValue? in
            guard key.kind != .percent else { return nil }
            let matches = rows.compactMap { row in row.first { $0.kind == key.kind && $0.label == key.label } }
            guard !matches.isEmpty else { return nil }
            return MetricValue(number: matches.reduce(0) { $0 + $1.number }, kind: key.kind,
                               label: key.label, estimated: matches.contains(where: \.estimated))
        }
        return values.isEmpty ? nil : .values(label: label, values: values)
    }

    private static func combinedProgress(label: String, snapshots: [ProviderSnapshot]) -> MetricLine? {
        let rows = snapshots.compactMap { snapshot -> (Double, Double, ProgressFormat, Int?)? in
            guard case .progress(_, let used, let limit, let format, _, let period, _)? = snapshot.line(label: label)
            else { return nil }
            return (used, limit, format, period)
        }
        guard let first = rows.first, first.2 != .percent,
              rows.allSatisfy({ $0.2 == first.2 && $0.3 == first.3 }) else { return nil }
        return .progress(label: label, used: rows.reduce(0) { $0 + $1.0 },
                         limit: rows.reduce(0) { $0 + $1.1 }, format: first.2,
                         periodDurationMs: first.3)
    }

    private static func combinedChart(label: String, snapshots: [ProviderSnapshot]) -> MetricLine? {
        let charts = snapshots.compactMap { snapshot -> [MetricChartPoint]? in
            guard case .chart(_, let points, _)? = snapshot.line(label: label) else { return nil }
            return points
        }
        guard !charts.isEmpty else { return nil }
        var order: [String] = []
        var totals: [String: Double] = [:]
        for point in charts.flatMap({ $0 }) {
            if totals[point.label] == nil { order.append(point.label) }
            totals[point.label, default: 0] += point.value
        }
        return .chart(label: label, points: order.map { title in
            let value = totals[title] ?? 0
            return MetricChartPoint(value: value, label: title,
                                    valueLabel: MetricFormatter.number(value, kind: .count, style: .row) + " tokens")
        })
    }

    private struct ValueKey: Hashable {
        let kind: MetricKind
        let label: String?
    }
}
