import Foundation
import Testing
import VCModels
import VCSpeakers

@Suite("SpeakerProfileStore")
struct SpeakerProfileStoreTests {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "vcspeakers-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func profile(_ name: String, seed: Float) -> SpeakerProfile {
        SpeakerProfile(
            name: name, embeddings: [[seed, 1 - seed, 0.25], [0.5, seed, 0.125]], preferredLocaleID: "en-GB",
            colorIndex: 3, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func profilesSurviveReopeningTheStore() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alice = Self.profile("Alice", seed: 0.1)
        let bob = Self.profile("Bob", seed: 0.7)

        let store = SpeakerProfileStore(directory: dir)  // directory does not exist yet
        #expect(await store.all().isEmpty)
        try await store.upsert(alice)
        try await store.upsert(bob)

        let reopened = SpeakerProfileStore(directory: dir)
        #expect(await reopened.all() == [alice, bob])
    }

    @Test func upsertReplacesByIDWithoutDuplicating() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var alice = Self.profile("Alice", seed: 0.1)
        let bob = Self.profile("Bob", seed: 0.7)
        let store = SpeakerProfileStore(directory: dir)
        try await store.upsert(alice)
        try await store.upsert(bob)

        alice.name = "Alice Smith"
        alice.embeddings.append([0, 0, 1])
        try await store.upsert(alice)

        let reopened = await SpeakerProfileStore(directory: dir).all()
        #expect(reopened.map(\.id) == [alice.id, bob.id])
        #expect(reopened.first == alice)
    }

    @Test func deleteIsPersistedAndUnknownIDIsHarmless() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alice = Self.profile("Alice", seed: 0.1)
        let bob = Self.profile("Bob", seed: 0.7)
        let store = SpeakerProfileStore(directory: dir)
        try await store.upsert(alice)
        try await store.upsert(bob)

        try await store.delete(id: alice.id)
        try await store.delete(id: UUID())
        #expect(await store.all() == [bob])
        #expect(await SpeakerProfileStore(directory: dir).all() == [bob])

        try await store.delete(id: bob.id)
        #expect(await SpeakerProfileStore(directory: dir).all().isEmpty)
    }

    @Test func corruptFileIsSetAsideNotOverwritten() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: dir.appending(path: "profiles.json"))

        let store = SpeakerProfileStore(directory: dir)
        #expect(await store.all().isEmpty)
        let alice = Self.profile("Alice", seed: 0.1)
        try await store.upsert(alice)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        let backups = names.filter { $0.hasPrefix("profiles.corrupt-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: dir.appending(path: backup)) == garbage)
        }
        #expect(await SpeakerProfileStore(directory: dir).all() == [alice])
    }
}
