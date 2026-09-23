import Foundation
import XCTest
@testable import OpenUsage

final class SelectedAccountProfileDiscoveryTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageSelectedProfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCodexProfileRequiresStableAccountIdentity() throws {
        let home = try scratchDirectory()
        let idToken = "header." + Data(#"{"email":"user@example.com"}"#.utf8).base64EncodedString() + ".signature"
        let files = FakeFiles([
            home.appendingPathComponent("auth.json").path:
                #"{"tokens":{"access_token":"access","account_id":"workspace-1","id_token":"\#(idToken)"}}"#,
        ])
        let discovery = SelectedAccountProfileDiscovery(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let finding = try discovery.find(family: "codex", path: home.path)

        XCTAssertEqual(finding.identityKey, "workspace-1|user@example.com")
        XCTAssertEqual(finding.profile.path, home.path)
        XCTAssertEqual(finding.codexIdentity?.accountID, "workspace-1")
    }

    func testCodexProfileRejectsWorkspaceWithoutUserIdentity() throws {
        let home = try scratchDirectory()
        let files = FakeFiles([
            home.appendingPathComponent("auth.json").path:
                #"{"tokens":{"access_token":"access","account_id":"workspace-1"}}"#,
        ])
        let discovery = SelectedAccountProfileDiscovery(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )
        XCTAssertThrowsError(try discovery.find(family: "codex", path: home.path)) { error in
            XCTAssertEqual(error as? SelectedAccountProfileDiscovery.DiscoveryError, .missingIdentity)
        }
    }

    func testCodexProfileRejectsTokenWithoutAccountIdentity() throws {
        let home = try scratchDirectory()
        let files = FakeFiles([
            home.appendingPathComponent("auth.json").path:
                #"{"tokens":{"access_token":"access"}}"#,
        ])
        let discovery = SelectedAccountProfileDiscovery(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        XCTAssertThrowsError(try discovery.find(family: "codex", path: home.path)) { error in
            XCTAssertEqual(error as? SelectedAccountProfileDiscovery.DiscoveryError, .missingIdentity)
        }
    }

    func testClaudeProfileUsesItsOwnIdentityAndCredentialFile() throws {
        let home = try scratchDirectory()
        let files = FakeFiles([
            home.appendingPathComponent(".claude.json").path:
                #"{"oauthAccount":{"accountUuid":"user-1","organizationUuid":"org-1","emailAddress":"work@example.com"}}"#,
            home.appendingPathComponent(".credentials.json").path:
                #"{"claudeAiOauth":{"accessToken":"access"}}"#,
        ])
        let discovery = SelectedAccountProfileDiscovery(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let finding = try discovery.find(family: "claude", path: home.path)

        XCTAssertEqual(finding.identityKey, "user-1|org-1")
        XCTAssertEqual(finding.label, "work@example.com")
        XCTAssertEqual(finding.profile.keychainLiteral, home.path)
    }

    func testClaudeProfileRejectsAmbiguousOrganization() throws {
        let home = try scratchDirectory()
        let files = FakeFiles([
            home.appendingPathComponent(".claude.json").path:
                #"{"oauthAccount":{"accountUuid":"user-1"}}"#,
            home.appendingPathComponent(".credentials.json").path:
                #"{"claudeAiOauth":{"accessToken":"access"}}"#,
        ])
        let discovery = SelectedAccountProfileDiscovery(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )
        XCTAssertThrowsError(try discovery.find(family: "claude", path: home.path)) { error in
            XCTAssertEqual(error as? SelectedAccountProfileDiscovery.DiscoveryError, .missingIdentity)
        }
    }
}
