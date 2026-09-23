import SwiftUI

/// The dashboard display: one inset group per provider (System Settings style). A provider's icon + name
/// sits above a rounded container holding its metric rows, so heterogeneous metric sets read as belonging
/// to their provider. Rows are the shared `WidgetRowView`, fed by the same `WidgetDataStore` the menu bar
/// uses.
///
/// Reordering works here directly (no Customize needed): drag any metric row to reorder it within its
/// provider, or drag a provider's header line to reorder whole providers. Customize stays the discoverable,
/// obvious place to do the same plus toggle metrics on/off. Both surfaces use the same local gesture/geometry
/// helper so they work inside the menu-bar popover without a system drag/drop session.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var frameStore = ReorderFrameStore()
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    @State private var collapsedAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "openusage.collapsedAccounts.v1") ?? [])
    @State private var expandedSummaries: Set<String> = []
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @Environment(\.codexResetClaims) private var codexResetClaims

    var body: some View {
        // Provider-section spacing is noticeably wider than the in-card row rhythm (so groups
        // still read as groups); the exact step comes from the density setting.
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            ForEach(layout.displayGroups) { group in
                let family = ProviderAccountID.family(of: group.provider.id)
                let siblings = layout.displayGroups.filter { ProviderAccountID.family(of: $0.provider.id) == family }
                if ProviderAccountID.families.contains(family),
                   siblings.count > 1
                       || (family == "codex" && container.codexSharedHistory != nil)
                       || (family == "claude" && container.claudeSharedHistory != nil) {
                    if siblings.first?.provider.id == group.provider.id {
                        accountSection(family: family, groups: siblings)
                    }
                } else {
                    section(group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frameStore.frames = $0 }
        .animation(Motion.spring, value: layout.displayGroups.map(\.provider.id))
    }

    private func accountSection(family: String, groups: [ProviderGroup]) -> some View {
        let order = container.accountsStore.records.filter { $0.family == family }.map(\.id)
        let sorted = groups.sorted { (order.firstIndex(of: $0.provider.id) ?? Int.max) < (order.firstIndex(of: $1.provider.id) ?? Int.max) }
        let summary = ProviderAccountSummary.make(
            family: family, accountIDs: sorted.map { $0.provider.id },
            snapshots: dataStore.snapshots, errors: dataStore.providerErrors,
            sharedSpendLines: family == "codex" ? container.codexSharedHistory?.lines ?? []
                : family == "claude" ? container.claudeSharedHistory?.lines ?? [] : []
        )
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(family.capitalized).font(.headline).padding(.horizontal, 8)
            if let summary {
                summaryCard(summary, family: family, accountCount: sorted.count)
            }
            ForEach(sorted) { group in
                VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
                    HStack {
                        Text(container.accountsStore.displayName(
                            for: group.provider.id, fallback: group.provider.displayName
                        )).font(.subheadline).fontWeight(.semibold)
                        Spacer()
                        if let notice = dataStore.headerNotice(for: group.provider.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel(notice)
                        }
                        Button {
                            if !collapsedAccounts.insert(group.provider.id).inserted {
                                collapsedAccounts.remove(group.provider.id)
                            }
                            UserDefaults.standard.set(collapsedAccounts.sorted(), forKey: "openusage.collapsedAccounts.v1")
                        } label: {
                            Image(systemName: collapsedAccounts.contains(group.provider.id) ? "chevron.down" : "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(collapsedAccounts.contains(group.provider.id) ? "Expand Account" : "Collapse Account")
                    }
                    .padding(.horizontal, 8)
                    if (family == "codex" && container.codexSharedHistory?.lines.isEmpty == false)
                        || (family == "claude" && container.claudeSharedHistory?.lines.isEmpty == false) {
                        Text("Spend and trend are in Combined Usage above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    if !collapsedAccounts.contains(group.provider.id) { container(group) }
                }
            }
        }
    }

    private func summaryCard(_ summary: ProviderSnapshot, family: String, accountCount: Int) -> some View {
        let primary = Set(["Session Available", "Weekly Available", "Today", "Last 30 Days"])
        let visible = summary.lines.filter {
            let id = "\(family):summary.\($0.label)"
            return container.summaryPins.isEnabled(id)
                && (primary.contains($0.label) || ((family == "codex" || family == "claude") && $0.label == "Usage Trend")
                    || expandedSummaries.contains(family)
                    || container.summaryPins.isFeatured(id))
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(family == "codex" || family == "claude"
                    ? "\(accountCount) \(accountCount == 1 ? "Account" : "Accounts") · Combined Usage"
                    : "\(accountCount) Accounts")
                    .fontWeight(.semibold)
                Spacer()
                Button(expandedSummaries.contains(family) ? "Less" : "More") {
                    if !expandedSummaries.insert(family).inserted { expandedSummaries.remove(family) }
                }
                .buttonStyle(.plain)
            }
            ForEach(visible, id: \.label) { line in
                if let value = summaryValue(line) {
                    HStack {
                        Text(line.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(value)
                    }
                    .font(.caption)
                    .contextMenu {
                        if case .chart = line {
                            EmptyView()
                        } else {
                            let id = "\(family):summary.\(line.label)"
                            Button(container.summaryPins.isPinned(id) ? "Unstar" : "Star for menu bar") {
                                container.summaryPins.setPinned(!container.summaryPins.isPinned(id), for: id)
                            }
                        }
                    }
                }
            }
            if (family == "codex" && container.codexSharedHistory?.lines.isEmpty == false)
                || (family == "claude" && container.claudeSharedHistory?.lines.isEmpty == false) {
                Label("Spend combines local logs; account attribution is unavailable.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = summary.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .cardSurface()
    }

    private func summaryValue(_ line: MetricLine) -> String? {
        switch line {
        case .values(_, let values, _, _, _, _):
            return values.map { value in
                let style: MetricFormatter.Style = value.kind == .count && value.label == "tokens" ? .row : .full
                return MetricFormatter.string(for: value, style: style)
            }.joined(separator: " · ")
        case .progress(_, let used, let limit, let format, _, _, _):
            let kind = format.metricKind
            return "\(MetricFormatter.number(used, kind: kind, style: .row)) / \(MetricFormatter.number(limit, kind: kind, style: .row))"
        case .chart(_, let points, _):
            return MetricFormatter.number(points.reduce(0) { $0 + $1.value }, kind: .count, style: .row) + " tokens"
        case .text(_, let value, _, _): return value
        case .badge(_, let text, _, _): return text
        }
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func header(_ group: ProviderGroup) -> some View {
        let displayed = container.accountsStore.displayProvider(group.provider)
        return ProviderSectionHeader(
            provider: displayed,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.headerNotice(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id),
            onCopyScreenshot: { shareCard(group) }
        )
        // Keep the provider mark and hover-revealed copy control aligned with the card's content edges.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            // Hides the whole provider section (the Customize provider list brings it back). Mirrors
            // the per-metric "Hide" but one level up, so the verb order reads the same on a header as a row.
            Button("Hide \(displayed.displayName)") {
                container.enablement.setEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(displayed.displayName)") {
                Task { await dataStore.refresh(providerID: group.provider.id, force: true) }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard. The appearance is
    /// taken from the popover's own `colorScheme` — this view is hosted in the popover panel, whose
    /// appearance is `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System) — so
    /// the export matches the card on screen instead of guessing from `NSApp.effectiveAppearance`. The
    /// same render path backs the footer's "Share Screenshot" submenu, which reaches it without a
    /// right-click.
    private func shareCard(_ group: ProviderGroup) -> Bool {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme
        )
    }

    /// A row's placed widget paired with its resolved descriptor + data, so each `dataStore.data(for:)`
    /// is computed once per render and reused by both the condensing rule and the row. Keyed off the
    /// `PlacedWidget` so `ForEach` identity stays exactly what it was before this was precomputed.
    private struct ResolvedRow: Identifiable {
        let widget: PlacedWidget
        let descriptor: WidgetDescriptor
        let data: WidgetData
        var id: PlacedWidget.ID { widget.id }
    }

    private enum DashboardMetricCardRow: Identifiable {
        case metric(ResolvedRow)
        case divider
        /// #596: the provider's quick-link buttons (Status / Console / Dashboard ...), pinned at the
        /// bottom of the collapsible expanded section. They collapse with the caret — part of the
        /// expander, not always-visible chrome.
        case links([ProviderLink])

        var id: String {
            switch self {
            case .metric(let row):
                "metric:\(row.descriptor.id)"
            case .divider:
                "expanded-divider"
            case .links:
                "provider-links"
            }
        }
    }

    private func container(_ group: ProviderGroup) -> some View {
        // Resolve each row's descriptor + data exactly once per render, then reuse it for both the
        // neighbor-aware condensing rule and the row itself — `dataStore.data(for:)` used to be
        // recomputed several times per row (twice per adjacent pair plus once in `row`).
        let providerID = group.provider.id
        let isExpanded = layout.isProviderExpanded(providerID)
        let alwaysRows = resolvedRows(group.alwaysShownWidgets)
        let expandedRows = resolvedRows(group.expandedWidgets)
        // The caret separates Always Visible and On Demand rows, so text-row condensing should not
        // bridge across it. Each side tightens only against rows on the same side of the separator.
        let condensedIDs = visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        let cardRows = metricCardRows(
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            hasExpandedMetrics: group.hasExpandedMetrics,
            isExpanded: isExpanded,
            links: group.provider.visibleLinks
        )
        // Same card builder the lifted preview uses, so the floating chip can't drift from the live card.
        return DashboardMetricCard {
            // One stable list keeps the drag-owning metric row alive when it crosses the caret boundary.
            // Separate always-shown/expanded loops can tear that source view down before `onEnded` fires,
            // leaving the lift overlay visible until another drag forces a reset.
            ForEach(cardRows) { cardRow in
                switch cardRow {
                case .metric(let entry):
                    row(entry.descriptor, data: entry.data, in: providerID,
                        condensedTop: condensedIDs.contains(entry.descriptor.id))
                case .links(let links):
                    ProviderLinksView(links: links)
                case .divider:
                    expandToggle(providerID: providerID, isExpanded: isExpanded)
                }
            }
        }
    }

    private func resolvedRows(_ widgets: [PlacedWidget]) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: dataStore.data(for: descriptor))
        }
    }

    private func metricCardRows(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow],
        hasExpandedMetrics: Bool,
        isExpanded: Bool,
        links: [ProviderLink]
    ) -> [DashboardMetricCardRow] {
        // #596: provider quick-link buttons live INSIDE the collapsible expanded section, pinned at its
        // bottom, so collapsing the caret hides them along with the expanded metrics — they're part of
        // the expander, not always-visible chrome. The caret shows for any provider with expanded
        // content (metrics OR links), so a links-only provider still gets a caret to reveal its buttons.
        let hasLinks = !links.isEmpty
        let hasExpandedContent = hasExpandedMetrics || hasLinks
        return alwaysRows.map(DashboardMetricCardRow.metric)
            + (hasExpandedContent ? [.divider] : [])
            + (isExpanded && !expandedRows.isEmpty ? expandedRows.map(DashboardMetricCardRow.metric) : [])
            + (isExpanded && hasLinks ? [.links(links)] : [])
    }

    /// The centered caret at the bottom of a provider card that reveals or hides its On Demand metrics
    /// and quick links. Rendered whenever the provider has either kind of expanded content.
    private func expandToggle(providerID: String, isExpanded: Bool) -> some View {
        Button {
            withAnimation(Motion.spring) {
                _ = layout.setProviderExpanded(!isExpanded, for: providerID)
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reorderFrame(
            id: expandedDividerID(for: providerID),
            in: .named(reorderSpaceName)
        )
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::dashboard-expanded-divider"
    }

    private func visibleCondensedTextRowIDs(alwaysRows: [ResolvedRow], expandedRows: [ResolvedRow]) -> Set<String> {
        condensedTextRowIDs(alwaysRows).union(condensedTextRowIDs(expandedRows))
    }

    /// Neighbor-aware rule (shared with the share-card export via `WidgetData.condensedTextRowOffsets`):
    /// IDs of text-only rows sitting directly under another text-only row. Rows can't see their
    /// neighbors, so the list computes the pairs; Compact density pulls these rows up so a run of
    /// one-liners reads as one cluster. Called per segment (always-shown / expanded), so the expand
    /// caret is never crossed.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        let offsets = WidgetData.condensedTextRowOffsets(in: rows.map(\.data))
        return Set(offsets.map { rows[$0].descriptor.id })
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String,
                     condensedTop: Bool) -> some View {
        return WidgetRowView(
            data: data,
            onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
            onToggleMeterStyle: { dataStore.meterStyle.toggle() },
            condensedTop: condensedTop
        )
            .environment(\.codexResetClaim, codexResetClaims[providerID])
            .contentShape(Rectangle())
            .opacity(activeMetricID == descriptor.id ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: descriptor, providerID: providerID))
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: .named(reorderSpaceName))
    }

    /// Desktop-native management for a single metric: hide it, pin/unpin it, refresh its provider, or jump
    /// into Customize — without a trip through Customize first. Hide leads (the most-reached-for verb), then
    /// star, then a divider before the two provider-/app-level actions.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unstar" : "Star for menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id) {
                    layout.setPinned(true, for: descriptor.id)
                } else {
                    layout.notePinDenied(descriptor.id)
                }
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(provider.displayName)") {
                Task { await dataStore.refresh(providerID: providerID, force: true) }
            }
        }
        Button("Customize…") {
            openCustomize(for: providerID)
        }
    }

    /// From the dashboard, jump straight into this provider's Customize metrics (L2), not the provider list.
    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = providerID
            layout.isEditing = true
        }
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.displayGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: { metricTargetIDs(for: providerID) },
            reorder: { target in
                let current = metricTargetIDs(for: providerID)
                if current.contains(expandedDividerID(for: providerID)) {
                    guard let next = LayoutStore.reordered(current, dragged: descriptor.id, target: target) else {
                        return false
                    }
                    return layout.applyMetricDividerOrder(
                        next,
                        dragged: descriptor.id,
                        dividerID: expandedDividerID(for: providerID),
                        in: providerID
                    )
                }
                return layout.reorderMetric(dragged: descriptor.id, target: target, in: providerID)
            }
        )
    }

    private func metricTargetIDs(for providerID: String) -> [String] {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return []
        }
        let alwaysShown = group.alwaysShownWidgets.compactMap { layout.descriptor(for: $0)?.id }
        // The caret is a drop target whenever the expanded section is open — including a links-only
        // section (buttons but no expanded metrics), so a metric can be dragged past the caret to tuck
        // it below the fold even when only buttons are showing there.
        let hasExpandedContent = group.hasExpandedMetrics || !group.provider.visibleLinks.isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        let expanded = group.expandedWidgets.compactMap { layout.descriptor(for: $0)?.id }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    private func makeProviderLift(for group: ProviderGroup, value: DragGesture.Value) -> ReorderLift? {
        // The floating preview should match what the card shows: only the always-shown rows unless this
        // provider's caret is currently open.
        let visibleWidgets = layout.isProviderExpanded(group.provider.id) ? group.widgets : group.alwaysShownWidgets
        let rows = visibleWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        return ReorderLift.make(
            id: group.provider.id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: rows
            ),
            value: value,
            frames: frameStore.frames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: frameStore.frames
        )
    }
}
