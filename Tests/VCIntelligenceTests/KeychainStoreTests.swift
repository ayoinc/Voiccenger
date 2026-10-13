import Foundation
import Security
import Testing
@testable import VCIntelligence

@Suite struct KeychainStoreTests {
    @Test func storesReplacesAndDeletes() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? KeychainStore.set(nil, account: account) }
        do {
            try KeychainStore.set("first", account: account)
        } catch let failure as KeychainStore.Failure where failure.status == errSecInteractionNotAllowed || failure.status == errSecNotAvailable {
            return  // Locked or absent login keychain (headless CI); nothing to exercise.
        }
        #expect(KeychainStore.get(account: account) == "first")
        try KeychainStore.set("sk-ant-é✓", account: account)
        #expect(KeychainStore.get(account: account) == "sk-ant-é✓")
        try KeychainStore.set("", account: account)
        #expect(KeychainStore.get(account: account) == nil)
        // Deleting what is already gone is not an error.
        try KeychainStore.set(nil, account: account)
    }

    @Test func environmentKeyIsUsedWhenKeychainHasNone() {
        // A stored key takes precedence; only check the fallback when none is stored on this machine.
        guard KeychainStore.get(account: IntelligenceFactory.anthropicKeyAccount) == nil else { return }
        #expect(IntelligenceFactory.anthropicAPIKey(environment: ["ANTHROPIC_API_KEY": "  sk-ant-test \n"]) == "sk-ant-test")
        #expect(IntelligenceFactory.anthropicAPIKey(environment: ["ANTHROPIC_API_KEY": "   "]) == nil)
        #expect(IntelligenceFactory.anthropicAPIKey(environment: [:]) == nil)
    }
}
