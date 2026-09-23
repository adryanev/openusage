import Foundation

/// Reads only credentials belonging to the selected Claude homes. It never falls back to the
/// process-wide token or another account's Desktop login.
struct SelectedClaudeCredentialLoader {
    let profiles: [SelectedAccountProfile]
    let environment: EnvironmentReading
    let files: TextFileAccessing
    let keychain: KeychainAccessing

    func load() -> [ClaudeCredentialState] {
        profiles.flatMap { profile in
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: profile.keychainLiteral ?? profile.path,
                environment: environment
            )
            var candidates: [ClaudeCredentialState] = []
            if let text = try? keychain.readGenericPasswordForCurrentUser(service: service),
               let candidate = credential(text, source: .keychainCurrentUser(service: service)) {
                candidates.append(candidate)
            } else if let text = try? keychain.readGenericPassword(service: service),
                      let candidate = credential(text, source: .keychainLegacy(service: service)) {
                candidates.append(candidate)
            }
            let filePath = URL(fileURLWithPath: profile.path).appendingPathComponent(".credentials.json").path
            if let text = try? files.readTextIfPresent(filePath),
               let candidate = credential(text, source: .accountFile(path: filePath)) {
                candidates.append(candidate)
            }
            return candidates
        }
    }

    private func credential(_ text: String, source: ClaudeCredentialState.Source) -> ClaudeCredentialState? {
        guard let parsed = ClaudeAuthStore.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.nilIfEmpty != nil
        else { return nil }
        return ClaudeCredentialState(oauth: oauth, source: source, fullData: parsed, inferenceOnly: false)
    }
}
