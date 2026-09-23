import AppKit
import Observation

/// Owns the menu-bar strip's render loop, split out of `StatusItemController`: render the pinned-metrics
/// strip and re-render whenever anything it reads changes (pins, live data, meter style, menu-bar style).
///
/// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. After the first change,
/// the next render waits briefly so a burst of snapshot writes collapses into one render with the latest
/// values — avoiding enough repeated work to make the menu-bar item disappear during a busy refresh.
/// Unchanged memoized images are not re-applied: setting the same `NSImage` still costs a WindowServer
/// redraw.
@MainActor
final class StatusItemImageUpdater {
    /// Applies a status-item image only when the instance changed. The renderer memoizes by content,
    /// so an identical instance means the button already shows this render — an unconditional set
    /// still costs a full status-item redraw through WindowServer on macOS 26+.
    struct ApplyGate {
        private var lastApplied: NSImage?

        mutating func apply(_ image: NSImage, using apply: (NSImage) -> Void) {
            guard image !== lastApplied else { return }
            lastApplied = image
            apply(image)
        }
    }

    private let container: AppContainer
    private let apply: (NSImage) -> Void
    private var applyGate = ApplyGate()

    /// - Parameter apply: sets the rendered image onto the status-item button.
    init(container: AppContainer, apply: @escaping (NSImage) -> Void) {
        self.container = container
        self.apply = apply
    }

    /// Render now and re-arm on the next observable change.
    func update() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDelayedUpdate()
            }
        }
        applyGate.apply(image, using: apply)
    }

    /// The observation callback fires only once until `update()` reads and re-arms it. Waiting here lets
    /// any immediately-following writes land first; the eventual render then reads their latest values.
    private func scheduleDelayedUpdate() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// The pinned-metrics strip in the chosen style, or the app icon when nothing is pinned.
    private func renderButtonImage() -> NSImage {
        // Screen-share privacy: while a capture is active (and the setting is on), the strip is
        // replaced with the wordmark so a shared screen never carries usage numbers. Read inside the
        // observation closure so the render re-arms on capture-state changes too.
        if container.privacy.concealUsage {
            return MenuBarStripRenderer.privacyImage
                ?? MenuBarIcon.image
                ?? MenuBarStripRenderer.fallbackIcon
        }
        let base = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) }
        )
        let summaryGroups = ProviderAccountID.families.sorted().compactMap { family -> MenuBarContent.Group? in
            let accountIDs = container.layout.orderedProviderIDs().filter {
                ProviderAccountID.family(of: $0) == family && container.enablement.isEnabled($0)
            }
            guard let first = accountIDs.first, let provider = container.layout.provider(id: first),
                  let snapshot = ProviderAccountSummary.make(
                    family: family, accountIDs: accountIDs,
                    snapshots: container.dataStore.snapshots, errors: container.dataStore.providerErrors
                  ) else { return nil }
            let metrics = snapshot.lines.compactMap { line -> MenuBarContent.Metric? in
                let id = "\(family):summary.\(line.label)"
                guard container.summaryPins.isPinned(id) else { return nil }
                switch line {
                case .values(let label, let values, _, _, _, _) where !values.isEmpty:
                    let bounded = label.hasSuffix("Available")
                    return MenuBarContent.Metric(
                        id: id, label: label,
                        value: values.map { MetricFormatter.string(for: $0, style: .tray) }.joined(separator: " · "),
                        fraction: bounded ? min(1, (values.first?.number ?? 0) / Double(accountIDs.count)) : 0,
                        isBounded: bounded, hasData: true
                    )
                case .progress(let label, let used, let limit, let format, _, _, _):
                    return MenuBarContent.Metric(
                        id: id, label: label,
                        value: MetricFormatter.number(used, kind: format.metricKind, style: .tray),
                        fraction: limit > 0 ? min(1, used / limit) : 0,
                        isBounded: limit > 0, hasData: true
                    )
                default: return nil
                }
            }
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(providerID: "\(family):summary",
                                        displayName: "\(family.capitalized) Summary",
                                        icon: provider.icon, metrics: metrics)
        }
        let groups = base.groups + summaryGroups
        let bars = (base.bars + summaryGroups.flatMap(\.metrics).filter(\.isBounded))
            .prefix(MenuBarContentBuilder.maxBars)
        let content = MenuBarContent(groups: groups, bars: Array(bars))
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }
}
