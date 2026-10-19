import Foundation
import Testing
@testable import FaceIDCore

struct TemplateStoreTests {
    private let storage = InMemoryItemStorage()

    private func makeStore() -> EncryptedTemplateStore {
        EncryptedTemplateStore(storage: storage, sealer: SoftwareKeySealer(storage: storage))
    }

    private let template = EnrolledTemplate(
        modelIdentifier: testModelID,
        embeddings: [FaceEmbedding([0.125, -0.5, 0.75]), FaceEmbedding([1, 2, 3])]
    )

    @Test func roundTrip() throws {
        let store = makeStore()
        try store.save(template)
        #expect(try store.load() == template)
    }

    @Test func emptyStoreLoadsNil() throws {
        #expect(try makeStore().load() == nil)
    }

    @Test func storedBytesAreEncrypted() throws {
        try makeStore().save(template)
        let raw = try #require(try storage.read(account: "template"))
        let plaintext = try JSONEncoder().encode(template)
        #expect(raw.range(of: Data("embeddings".utf8)) == nil)
        #expect(raw.range(of: Data(testModelID.utf8)) == nil)
        #expect(raw != plaintext)
    }

    @Test func tamperedCiphertextIsRejected() throws {
        let store = makeStore()
        try store.save(template)
        var raw = try #require(try storage.read(account: "template"))
        raw[raw.count - 1] ^= 0x01
        try storage.write(raw, account: "template")
        #expect(throws: FaceIDError.encryptionFailure) { try store.load() }
    }

    @Test func missingKeyIsRejected() throws {
        let store = makeStore()
        try store.save(template)
        try storage.delete(account: "template-key.software")
        #expect(throws: FaceIDError.encryptionFailure) { try store.load() }
    }

    @Test func deleteRemovesTemplateAndKey() throws {
        let store = makeStore()
        try store.save(template)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(try storage.read(account: "template-key.software") == nil)
    }

    @Test func emptyTemplateIsRejected() {
        let empty = EnrolledTemplate(modelIdentifier: testModelID, embeddings: [])
        #expect(throws: FaceIDError.invalidTemplate) { try makeStore().save(empty) }
    }

    @Test func eachSealUsesFreshNonce() throws {
        let sealer = SoftwareKeySealer(storage: storage)
        let data = Data("same".utf8)
        #expect(try sealer.seal(data) != sealer.seal(data))
    }
}

/// Storage that behaves like the login keychain after an agent update: silent reads are refused,
/// reads that may show the "allow access" dialog succeed (the owner clicked Always Allow).
final class ApprovalGatedStorage: SecureItemStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var approved = false
    private(set) var interactiveReads = 0

    func read(account: String) throws -> Data? {
        try lock.withLock {
            guard items[account] == nil || approved else { throw FaceIDError.keychainApprovalNeeded }
            return items[account]
        }
    }

    func readAllowingUserInteraction(account: String) throws -> Data? {
        lock.withLock {
            interactiveReads += 1
            approved = true
            return items[account]
        }
    }

    func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }

    func simulateUpdate() { lock.withLock { approved = false } }
}

struct KeychainApprovalStoreTests {
    private let template = EnrolledTemplate(modelIdentifier: testModelID, embeddings: [FaceEmbedding([1, 2, 3])])

    @Test func silentLoadFailsAfterUpdateUntilApproved() throws {
        let storage = ApprovalGatedStorage()
        let store = EncryptedTemplateStore(storage: storage, sealer: SoftwareKeySealer(storage: storage))
        try store.save(template)
        storage.simulateUpdate()

        #expect(throws: FaceIDError.keychainApprovalNeeded) { try store.load() }
        try store.approveAccess()
        #expect(try store.load() == template)
    }

    @Test func savingAsksForAccessToAnExistingKey() throws {
        let storage = ApprovalGatedStorage()
        let store = EncryptedTemplateStore(storage: storage, sealer: SoftwareKeySealer(storage: storage))
        try store.save(template)
        storage.simulateUpdate()
        let before = storage.interactiveReads
        try store.save(template)   // re-enrolment while the owner is present
        #expect(storage.interactiveReads > before)
    }
}
