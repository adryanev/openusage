import CryptoKit
import Foundation
import Observation

/// Card-id helpers for the account-first model. The account occupying a family's default home when
/// first observed keeps the bare family id (`claude`, `codex`) as its permanent record id — that is
/// what makes existing installs migrate by doing nothing. Any later account of the same family mints
/// `family@<hash8>` from its identity key.
enum ProviderAccountID {
    /// The family ids that participate in the account-first model.
    static let families: Set<String> = ["claude", "codex"]

    /// `claude@ab12cd34` — a stable, non-reversible id derived from the account's identity key.
    static func make(family: String, identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.lowercased().utf8))
        let hash8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(family)@\(hash8)"
    }

    /// The family a card id belongs to: `claude@ab12cd34` → `claude`, bare ids map to themselves.
    static func family(of cardID: String) -> String {
        cardID.firstIndex(of: "@").map { String(cardID[..<$0]) } ?? cardID
    }
}

/// One place an account is signed in. "Default" is a badge on a source (`holdsDefaultSource`), never
/// a key: it marks who currently occupies the default home, and it never drives ids or sort order —
/// a swap re-points source edges, cards don't move. Phase 1 only observes the default home; later
/// phases add config dirs, cswap vault slots, Codex homes, and Desktop logins as more kinds.
struct ProviderAccountSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The provider's standard home for this machine (`~/.claude`, `~/.codex`, env override).
        case defaultHome
        case claudeSwap
        case codexSwap
        case selectedHome
    }

    var kind: Kind
    /// Canonical home path the source was observed at.
    var anchor: String?
    var holdsDefaultSource: Bool
}

/// An account as the account-first model sees it: opaque identity key, stable record id minted at
/// creation, and the sources currently attaching to it.
struct ProviderAccountRecord: Codable, Equatable, Sendable {
    /// Stable id minted when the account is first seen; never re-derived. The first account observed
    /// at a family's default home gets the bare family id.
    var id: String
    var family: String
    var identityKey: String
    var label: String?
    var alias: String? = nil
    var sources: [ProviderAccountSource]
    /// Removed accounts retain their history and never resurrect through rescans.
    var removedTombstone: Bool = false
}

struct SelectedAccountProfile: Codable, Equatable, Sendable {
    let family: String
    let path: String
    let keychainLiteral: String?
}

/// The account-first registry (`openusage.providerAccounts.v1`). Reconciled at every launch from the
/// default-home identity reads; authoritative from day one — there is no parallel card model to drift
/// from. With a single account per family (all Phase 1 can observe), the registry is bookkeeping the
/// UI doesn't consult yet; multi-account rendering (Phase 2+) reads cards straight from these records.
@MainActor
@Observable
final class ProviderAccountsStore {
    static let storageKey = "openusage.providerAccounts.v1"
    static let selectedProfilesKey = "openusage.selectedAccountProfiles.v1"

    private let defaults: UserDefaults
    private let initiallyAliasedIDs: Set<String>
    private(set) var records: [ProviderAccountRecord]
    private(set) var selectedProfiles: [SelectedAccountProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.selectedProfilesKey) {
            do {
                selectedProfiles = try JSONDecoder().decode([SelectedAccountProfile].self, from: data)
            } catch {
                AppLog.error(.config, "selected account profiles were undecodable: \(error.localizedDescription)")
                selectedProfiles = []
            }
        } else {
            selectedProfiles = []
        }
        let loadedRecords: [ProviderAccountRecord]
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                loadedRecords = try JSONDecoder().decode([ProviderAccountRecord].self, from: data)
            } catch {
                AppLog.error(.config, "provider-account records were undecodable; starting a fresh registry: \(error.localizedDescription)")
                loadedRecords = []
            }
        } else {
            loadedRecords = []
        }
        self.initiallyAliasedIDs = Set(loadedRecords.filter { $0.alias != nil }.map(\.id))
        self.records = loadedRecords
    }

    @discardableResult
    func addSelectedProfile(_ profile: SelectedAccountProfile) -> Bool {
        guard ProviderAccountID.families.contains(profile.family),
              !selectedProfiles.contains(where: { $0.family == profile.family && $0.path == profile.path })
        else { return false }
        selectedProfiles.append(profile)
        persistSelectedProfiles()
        return true
    }

    func removeSelectedProfile(family: String, path: String) {
        selectedProfiles.removeAll { $0.family == family && $0.path == path }
        for index in records.indices where records[index].family == family {
            records[index].sources.removeAll { $0.kind == .selectedHome && $0.anchor == path }
        }
        persistSelectedProfiles()
        persist()
    }

    func setAlias(_ alias: String?, for id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persist()
    }

    func displayName(for id: String, fallback: String) -> String {
        guard let record = records.first(where: { $0.id == id }) else { return fallback }
        if let alias = record.alias { return "\(record.family.capitalized): \(alias)" }
        guard initiallyAliasedIDs.contains(id), let label = record.label else { return fallback }
        return "\(record.family.capitalized): \(label)"
    }

    func displayProvider(_ provider: Provider) -> Provider {
        Provider(id: provider.id, displayName: displayName(for: provider.id, fallback: provider.displayName),
                 icon: provider.icon, links: provider.links)
    }

    func removeAccount(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let family = records[index].family
        let selectedPaths = Set(records[index].sources.filter { $0.kind == .selectedHome }.compactMap(\.anchor))
        selectedProfiles.removeAll { $0.family == family && selectedPaths.contains($0.path) }
        records[index].removedTombstone = true
        persistSelectedProfiles()
        persist()
    }

    func addAgain(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].removedTombstone = false
        persist()
    }

    func deleteLocalHistory(id: String) {
        guard records.contains(where: { $0.id == id && $0.removedTombstone }) else { return }
        AccountHistoryDeletion.markDeleted(for: id, defaults: defaults)
        ProviderSnapshotCache(userDefaults: defaults).removeHistory(providerID: id)
    }

    func reorderAccount(dragged: String, before target: String) {
        guard let source = records.firstIndex(where: { $0.id == dragged }),
              let destination = records.firstIndex(where: { $0.id == target }), source != destination
        else { return }
        let record = records.remove(at: source)
        let insertion = records.firstIndex(where: { $0.id == target }) ?? records.endIndex
        records.insert(record, at: insertion)
        persist()
    }

    func moveAccount(id: String, by offset: Int) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let familyPosition = records.indices.filter({ records[$0].family == records[index].family })
                .firstIndex(of: index)
        else { return }
        let familyIndices = records.indices.filter { records[$0].family == records[index].family }
        let destination = familyPosition + offset
        guard familyIndices.indices.contains(destination) else { return }
        records.swapAt(index, familyIndices[destination])
        persist()
    }

    /// One account observed this launch, before reconciliation assigns (or re-finds) its record id.
    struct AccountObservation {
        var family: String
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
    }

    /// Merges this launch's observations into the persisted set. Phase 1 semantics: an observation
    /// updates its account's label and sources, or creates the record; the first account of a family
    /// gets the bare family id, a later one mints `family@<hash8>`. Records never move or vanish here
    /// — an account that went unobserved (logged out, unreadable identity) is simply left as it was,
    /// except that a newly observed default-home holder takes the default badge off every sibling.
    @discardableResult
    func reconcile(with observations: [AccountObservation], scannedFamilies: Set<String> = []) -> [ProviderAccountRecord] {
        var updated = records
        var changed = false

        for index in updated.indices where scannedFamilies.contains(updated[index].family)
            && !updated[index].removedTombstone && !updated[index].sources.isEmpty {
            updated[index].sources = []
            changed = true
        }

        for observation in observations {
            let index = updated.firstIndex {
                $0.family == observation.family && $0.identityKey == observation.identityKey
            }
            if let index {
                guard !updated[index].removedTombstone else { continue }
                var record = updated[index]
                record.label = observation.label ?? record.label
                record.sources = observation.sources
                if record != updated[index] {
                    updated[index] = record
                    changed = true
                }
            } else {
                updated.append(ProviderAccountRecord(
                    id: Self.availableID(for: observation, in: updated),
                    family: observation.family,
                    identityKey: observation.identityKey,
                    label: observation.label,
                    sources: observation.sources
                ))
                changed = true
            }

            // The default badge is exclusive per family: when this observation holds it, strip it
            // from every sibling record (the account that swapped out no longer answers the bare id).
            if observation.sources.contains(where: \.holdsDefaultSource) {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && updated[index].sources.contains(where: \.holdsDefaultSource)
                {
                    updated[index].sources = updated[index].sources.map { source in
                        var source = source
                        source.holdsDefaultSource = false
                        return source
                    }
                    changed = true
                }
            }
        }

        if changed && updated != records {
            records = updated
            persist()
        }
        return records
    }

    /// The record currently holding a family's default badge, if any.
    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }

    /// Preserve the existing card and pins when adding xswap's user component to a workspace id.
    func upgradeCodexIdentity(_ identity: CodexAccountIdentity) {
        guard !identity.accountID.isEmpty,
              !records.contains(where: { $0.family == "codex" && $0.identityKey == identity.key }),
              let index = records.firstIndex(where: {
                  $0.family == "codex" && $0.identityKey == identity.accountID
                      && ($0.label == nil || $0.label?.lowercased() == identity.email)
              }) else { return }
        records[index].identityKey = identity.key
        persist()
    }

    /// The bare family id when free (the migration-killing rule: the first account observed at the
    /// default home IS the existing card), else an identity-derived `family@<hash8>` id.
    private static func availableID(for observation: AccountObservation, in records: [ProviderAccountRecord]) -> String {
        if !records.contains(where: { $0.id == observation.family }) { return observation.family }
        let derived = ProviderAccountID.make(family: observation.family, identityKey: observation.identityKey)
        guard records.contains(where: { $0.id == derived }) else { return derived }
        // A hash-prefix collision between two distinct identities of one family; salt until free.
        var attempt = 0
        while true {
            let salted = ProviderAccountID.make(
                family: observation.family,
                identityKey: "\(observation.identityKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == salted }) { return salted }
            attempt += 1
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-account records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func persistSelectedProfiles() {
        guard let data = try? JSONEncoder().encode(selectedProfiles) else {
            AppLog.error(.config, "failed to encode selected account profiles")
            return
        }
        defaults.set(data, forKey: Self.selectedProfilesKey)
    }
}
