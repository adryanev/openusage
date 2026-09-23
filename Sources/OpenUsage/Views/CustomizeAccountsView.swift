import AppKit
import SwiftUI

struct CustomizeAccountsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @State private var aliases: [String: String] = [:]
    @State private var message: String?
    @State private var historyDeletionID: String?

    private var accounts: ProviderAccountsStore { container.accountsStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(["claude", "codex"], id: \.self) { family in
                familySection(family)
            }
        }
        .onAppear { aliases = Dictionary(uniqueKeysWithValues: accounts.records.map { ($0.id, $0.alias ?? "") }) }
        .alert("Delete Local History?", isPresented: Binding(
            get: { historyDeletionID != nil }, set: { if !$0 { historyDeletionID = nil } }
        )) {
            Button("Delete History", role: .destructive) {
                if let id = historyDeletionID { accounts.deleteLocalHistory(id: id) }
                historyDeletionID = nil
                container.accountInventory.requestReload()
            }
            Button("Cancel", role: .cancel) { historyDeletionID = nil }
        } message: {
            Text("Deletes this account's history on this Mac. Other Macs keep their own history.")
        }
    }

    private func familySection(_ family: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(family.capitalized).font(.headline)
                Spacer()
                Button("Add Profile…") { chooseProfile(for: family) }
                    .buttonStyle(.bordered)
            }
            let activeIDs = layout.orderedProviderIDs().filter {
                ProviderAccountID.family(of: $0) == family && container.enablement.isEnabled($0)
            }
            if let summary = ProviderAccountSummary.make(
                family: family, accountIDs: activeIDs,
                snapshots: container.dataStore.snapshots, errors: container.dataStore.providerErrors
            ) {
                DisclosureGroup("Provider Summary") {
                    ForEach(summary.lines, id: \.label) { line in
                        let id = "\(family):summary.\(line.label)"
                        HStack {
                            Text(line.label).font(.caption)
                            Spacer()
                            if !["Session Available", "Weekly Available", "Today", "Last 30 Days"].contains(line.label) {
                                Toggle("Show", isOn: Binding(
                                    get: { container.summaryPins.isFeatured(id) },
                                    set: { container.summaryPins.setFeatured($0, for: id) }
                                ))
                                .toggleStyle(.checkbox)
                            }
                            if case .chart = line {
                                EmptyView()
                            } else {
                                Button {
                                    container.summaryPins.setPinned(!container.summaryPins.isPinned(id), for: id)
                                } label: {
                                    Image(systemName: container.summaryPins.isPinned(id) ? "star.fill" : "star")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(container.summaryPins.isPinned(id) ? "Unstar Summary" : "Star Summary")
                            }
                        }
                    }
                }
            }
            ForEach(accounts.records.filter { $0.family == family && !$0.removedTombstone }, id: \.id) { record in
                accountCard(record)
            }
            let archived = accounts.records.filter { $0.family == family && $0.removedTombstone }
            if !archived.isEmpty {
                Text("Removed Accounts").font(.subheadline).foregroundStyle(.secondary)
                ForEach(archived, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.alias ?? record.label ?? record.id).lineLimit(1)
                            Spacer()
                            Button("Add Again") {
                                accounts.addAgain(id: record.id)
                                container.accountInventory.requestReload()
                            }
                        }
                        if let history = ProviderSnapshotCache().loadSnapshots(providerIDs: [record.id])[record.id]?.usageHistory {
                            Text("\(history.series.daily.count) days saved on this Mac")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No saved history on this Mac")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Delete History", role: .destructive) { historyDeletionID = record.id }
                            .font(.caption)
                    }
                    .padding(10)
                    .cardSurface()
                }
            }
        }
    }

    private func accountCard(_ record: ProviderAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.alias ?? record.label ?? record.id).fontWeight(.semibold)
                Spacer()
                Button { accounts.moveAccount(id: record.id, by: -1); container.accountInventory.requestReload() } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Move Account Up")
                Button { accounts.moveAccount(id: record.id, by: 1); container.accountInventory.requestReload() } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Move Account Down")
            }
            HStack {
                Text("Alias").foregroundStyle(.secondary)
                TextField("Optional alias", text: Binding(
                    get: { aliases[record.id] ?? record.alias ?? "" },
                    set: { aliases[record.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAlias(record) }
                Button("Save") { saveAlias(record) }
            }
            if record.sources.isEmpty {
                Label("Session unavailable. Sign in with the CLI or add a profile directory.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(record.sources.indices, id: \.self) { index in
                let source = record.sources[index]
                HStack {
                    Text(source.anchor ?? source.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if source.kind == .selectedHome, let path = source.anchor {
                        Button("Detach") {
                            accounts.removeSelectedProfile(family: record.family, path: path)
                            container.accountInventory.requestReload()
                        }
                        .font(.caption)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Remove Account", role: .destructive) {
                    layout.resetProvider(record.id)
                    accounts.removeAccount(id: record.id)
                    container.accountInventory.requestReload()
                }
            }
        }
        .padding(12)
        .cardSurface()
    }

    private func saveAlias(_ record: ProviderAccountRecord) {
        accounts.setAlias(aliases[record.id], for: record.id)
        container.accountInventory.requestReload()
    }

    private func chooseProfile(for family: String) {
        let panel = NSOpenPanel()
        panel.message = "Choose a \(family.capitalized) CLI profile directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let finding = try SelectedAccountProfileDiscovery().find(family: family, path: url.path)
            guard accounts.addSelectedProfile(finding.profile) else {
                message = "This profile is already connected."
                return
            }
            message = nil
            container.accountInventory.requestReload()
        } catch {
            message = error.localizedDescription
        }
    }
}
