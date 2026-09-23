import Foundation

/// Reads an explicitly chosen CLI home. The home must name its account before it can be stored.
struct SelectedAccountProfileDiscovery {
    struct Finding: Sendable {
        let profile: SelectedAccountProfile
        let identityKey: String
        let label: String?
        let codexIdentity: CodexAccountIdentity?
    }

    enum DiscoveryError: LocalizedError, Equatable {
        case unsupportedFamily
        case notDirectory
        case missingIdentity
        case missingCredential

        var errorDescription: String? {
            switch self {
            case .unsupportedFamily: "Choose a Codex or Claude profile."
            case .notDirectory: "Choose an existing CLI profile directory."
            case .missingIdentity: "This profile does not identify its account. Sign in with the CLI, then try again."
            case .missingCredential: "This profile has no readable local login. Sign in with the CLI, then try again."
            }
        }
    }

    var environment: EnvironmentReading = ProcessEnvironmentReader()
    var files: TextFileAccessing = LocalTextFileAccessor()
    var keychain: KeychainAccessing = SecurityKeychainAccessor()
    var homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }

    func find(family: String, path: String) throws -> Finding {
        guard ProviderAccountID.families.contains(family) else { throw DiscoveryError.unsupportedFamily }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw DiscoveryError.notDirectory }
        switch family {
        case "claude": return try findClaude(at: url)
        case "codex": return try findCodex(at: url)
        default: throw DiscoveryError.unsupportedFamily
        }
    }

    private func findClaude(at url: URL) throws -> Finding {
        let observer = DefaultAccountObserver(
            environment: HomeOverrideEnvironment(base: environment, name: "CLAUDE_CONFIG_DIR", value: url.path),
            files: files, keychain: keychain, homeDirectory: homeDirectory
        )
        guard case .resolved(let identityKey, let label, _) = observer.observeClaude(),
              identityKey.contains("|") else {
            throw DiscoveryError.missingIdentity
        }
        let credentialPath = url.appendingPathComponent(".credentials.json").path
        let fileHasToken = (try? files.readTextIfPresent(credentialPath))
            .flatMap { $0 }
            .flatMap(ClaudeAuthStore.parseCredentials)?
            .claudeAiOauth?.accessToken?.nilIfEmpty != nil
        let literal = keychainLiterals(for: url).first { literal in
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: literal, environment: environment
            )
            return keychain.genericPasswordExists(service: service) == true
        }
        guard fileHasToken || literal != nil else { throw DiscoveryError.missingCredential }
        return Finding(
            profile: SelectedAccountProfile(family: "claude", path: url.path,
                                            keychainLiteral: literal ?? url.path),
            identityKey: identityKey, label: label, codexIdentity: nil
        )
    }

    private func findCodex(at url: URL) throws -> Finding {
        let text = try? files.readTextIfPresent(url.appendingPathComponent("auth.json").path)
        guard let text = text.flatMap({ $0 }), let auth = CodexAuthStore.parseAuth(text),
              let identity = CodexAccountIdentity(auth: auth),
              CodexAccountIdentity.isComplete(key: identity.key)
        else { throw DiscoveryError.missingIdentity }
        guard auth.tokens?.accessToken?.nilIfEmpty != nil else { throw DiscoveryError.missingCredential }
        return Finding(
            profile: SelectedAccountProfile(family: "codex", path: url.path, keychainLiteral: nil),
            identityKey: identity.key, label: identity.email ?? String(identity.accountID.prefix(8)),
            codexIdentity: identity
        )
    }

    private func keychainLiterals(for url: URL) -> [String] {
        let home = homeDirectory().resolvingSymlinksInPath().standardizedFileURL.path
        var literals = [url.path]
        if url.path.hasPrefix(home + "/") {
            literals.append("~" + url.path.dropFirst(home.count))
        }
        return literals
    }
}

private struct HomeOverrideEnvironment: EnvironmentReading {
    let base: EnvironmentReading
    let name: String
    let value: String

    func value(for requestedName: String) -> String? {
        requestedName == name ? value : base.value(for: requestedName)
    }
}
