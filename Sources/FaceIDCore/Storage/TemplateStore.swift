import CryptoKit
import Darwin
import Foundation
import Security

public struct EnrolledTemplate: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var modelIdentifier: String
    public var embeddings: [FaceEmbedding]

    public init(id: UUID = UUID(), createdAt: Date = Date(), modelIdentifier: String, embeddings: [FaceEmbedding]) {
        self.id = id
        self.createdAt = createdAt
        self.modelIdentifier = modelIdentifier
        self.embeddings = embeddings
    }
}

// MARK: - Raw secure storage

/// Byte storage for secrets. Production uses the Keychain; tests use an in-memory fake.
public protocol SecureItemStorage: Sendable {
    /// Never shows UI.
    func read(account: String) throws -> Data?
    /// May show the system's "allow access" dialog. Only while the user is at the Mac.
    func readAllowingUserInteraction(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

extension SecureItemStorage {
    public func readAllowingUserInteraction(account: String) throws -> Data? {
        try read(account: account)
    }
}

/// Whether legacy-keychain access may show its "allow access" dialog.
///
/// Without a paid Apple Developer team the login keychain ties an item to the exact binary
/// (cdhash), so every agent update triggers that dialog. At the lock screen nobody can answer it and
/// the agent would hang, so reads never prompt (they fail with `.keychainApprovalNeeded`); prompts
/// happen only on explicit owner actions from the menu bar app. `kSecUseAuthenticationUIFail` does
/// not cover the legacy keychain (tested on macOS 27), hence the legacy process-wide switch.
enum KeychainInteraction {
    private typealias SetAllowed = @convention(c) (DarwinBoolean) -> OSStatus
    private static let lock = NSLock()
    // Looked up at run time: the API is deprecated but still the only switch for the legacy keychain.
    private static let setAllowed: SetAllowed? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetAllowed.self)
    }()

    /// Runs `body` with prompts allowed or not; afterwards prompts are forbidden again.
    static func perform<T>(allowingPrompts: Bool, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            _ = setAllowed?(false)
            lock.unlock()
        }
        _ = setAllowed?(DarwinBoolean(allowingPrompts))
        return try body()
    }
}

public struct KeychainItemStorage: SecureItemStorage {
    public let service: String
    /// The data protection keychain honours `kSecAttrAccessible`, but needs an application
    /// identifier entitlement (a paid Apple Developer team). Without it the item goes to the
    /// local login keychain, whose ACL limits it to this binary's signature. Either way the
    /// stored blob is ciphertext whose key only this Mac's Secure Enclave can use.
    public let useDataProtectionKeychain: Bool

    public init(
        service: String = FaceIDConfig.keychainService,
        useDataProtectionKeychain: Bool = KeychainItemStorage.dataProtectionKeychainAvailable
    ) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    /// Whether this process may use the data protection keychain, decided by actually writing
    /// (and removing) a probe item: a read-only probe can answer differently for signed code.
    public static let dataProtectionKeychainAvailable: Bool = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.faceid.entitlement-probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item = query
        item[kSecValueData as String] = Data([0])
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        let available = status == errSecSuccess || status == errSecDuplicateItem
        Log.storage.notice("data protection keychain probe: \(status, privacy: .public) (\(available ? "using it" : "using the login keychain", privacy: .public))")
        return available
    }()

    public func read(account: String) throws -> Data? {
        try read(account: account, allowingPrompt: false)
    }

    public func readAllowingUserInteraction(account: String) throws -> Data? {
        try read(account: account, allowingPrompt: true)
    }

    private func read(account: String, allowingPrompt: Bool) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = KeychainInteraction.perform(allowingPrompts: allowingPrompt) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw FaceIDError.storageFailure(errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            // Item made by an earlier build of the agent: the owner must allow access again.
            throw FaceIDError.keychainApprovalNeeded
        default:
            throw FaceIDError.storageFailure(status)
        }
    }

    public func write(_ data: Data, account: String) throws {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        // Writes happen only on owner actions (enrollment, deletion), so a prompt may be shown.
        let updateStatus = KeychainInteraction.perform(allowingPrompts: true) {
            SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        }
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account: account)
            item.merge(attributes) { _, new in new }
            let addStatus = KeychainInteraction.perform(allowingPrompts: true) { SecItemAdd(item as CFDictionary, nil) }
            guard addStatus == errSecSuccess else { throw FaceIDError.storageFailure(addStatus) }
        default:
            throw FaceIDError.storageFailure(updateStatus)
        }
    }

    public func delete(account: String) throws {
        let status = KeychainInteraction.perform(allowingPrompts: true) {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FaceIDError.storageFailure(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

// MARK: - Encryption

public protocol TemplateSealing: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
    /// Removes the key material, making any existing ciphertext unreadable.
    func destroyKey() throws
    /// Reads the key item allowing the system's "allow access" dialog (owner present only).
    func approveKeyAccess() throws
}

private let templateAAD = Data("com.example.faceid.template.v1".utf8)

/// AES-GCM with a random 256-bit key kept in secure storage.
/// Fallback for Macs without a Secure Enclave (Intel without T2, most VMs).
public struct SoftwareKeySealer: TemplateSealing {
    private static let formatVersion: UInt8 = 1
    private let storage: any SecureItemStorage
    private let keyAccount: String

    public init(storage: any SecureItemStorage, keyAccount: String = "template-key.software") {
        self.storage = storage
        self.keyAccount = keyAccount
    }

    public func seal(_ plaintext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: templateAAD)
            guard let combined = box.combined else { throw FaceIDError.encryptionFailure }
            return Data([Self.formatVersion]) + combined
        } catch {
            throw FaceIDError.encryptionFailure
        }
    }

    public func open(_ sealed: Data) throws -> Data {
        guard sealed.first == Self.formatVersion, let keyData = try storage.read(account: keyAccount) else {
            throw FaceIDError.encryptionFailure
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: templateAAD)
        } catch {
            throw FaceIDError.encryptionFailure
        }
    }

    public func destroyKey() throws {
        try storage.delete(account: keyAccount)
    }

    public func approveKeyAccess() throws {
        _ = try storage.readAllowingUserInteraction(account: keyAccount)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try storage.read(account: keyAccount) {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try storage.write(key.withUnsafeBytes { Data($0) }, account: keyAccount)
        return key
    }
}

/// ECIES with a P-256 key that never leaves the Secure Enclave. Only the enclave-wrapped
/// key blob is persisted; it is useless on any other device.
public struct SecureEnclaveSealer: TemplateSealing {
    private static let formatVersion: UInt8 = 2
    private static let x963PublicKeyLength = 65
    private let storage: any SecureItemStorage
    private let keyAccount: String

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init(storage: any SecureItemStorage, keyAccount: String = "template-key.secure-enclave") {
        self.storage = storage
        self.keyAccount = keyAccount
    }

    public func seal(_ plaintext: Data) throws -> Data {
        // Storage errors keep their OSStatus; only crypto failures become `.encryptionFailure`.
        let recipient = try loadOrCreateKey().publicKey
        do {
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let ephemeralPublic = ephemeral.publicKey.x963Representation
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            let key = Self.deriveKey(shared, ephemeralPublic: ephemeralPublic)
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: templateAAD)
            guard let combined = box.combined else { throw FaceIDError.encryptionFailure }
            return Data([Self.formatVersion]) + ephemeralPublic + combined
        } catch {
            Log.storage.error("secure enclave seal failed: \(Self.describe(error), privacy: .public)")
            throw FaceIDError.encryptionFailure
        }
    }

    public func open(_ sealed: Data) throws -> Data {
        guard sealed.first == Self.formatVersion, sealed.count > 1 + Self.x963PublicKeyLength,
              let keyBlob = try storage.read(account: keyAccount)
        else { throw FaceIDError.encryptionFailure }
        do {
            let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyBlob)
            let body = sealed.dropFirst()
            let ephemeralPublic = Data(body.prefix(Self.x963PublicKeyLength))
            let sender = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublic)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: sender)
            let key = Self.deriveKey(shared, ephemeralPublic: ephemeralPublic)
            let box = try AES.GCM.SealedBox(combined: body.dropFirst(Self.x963PublicKeyLength))
            return try AES.GCM.open(box, using: key, authenticating: templateAAD)
        } catch {
            Log.storage.error("secure enclave open failed: \(Self.describe(error), privacy: .public)")
            throw FaceIDError.encryptionFailure
        }
    }

    public func destroyKey() throws {
        try storage.delete(account: keyAccount)
    }

    public func approveKeyAccess() throws {
        _ = try storage.readAllowingUserInteraction(account: keyAccount)
    }

    /// Error domain and code only — never key material.
    static func describe(_ error: Error) -> String {
        if let faceID = error as? FaceIDError { return String(describing: faceID) }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    private static func deriveKey(_ shared: SharedSecret, ephemeralPublic: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublic,
            sharedInfo: templateAAD,
            outputByteCount: 32
        )
    }

    private func loadOrCreateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = try storage.read(account: keyAccount) {
            do {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
            } catch {
                Log.storage.error("secure enclave key restore failed: \(Self.describe(error), privacy: .public)")
                throw FaceIDError.encryptionFailure
            }
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            Log.storage.error("access control creation failed")
            throw FaceIDError.encryptionFailure
        }
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        } catch {
            Log.storage.error("secure enclave key creation failed: \(Self.describe(error), privacy: .public)")
            throw FaceIDError.encryptionFailure
        }
        do {
            try storage.write(key.dataRepresentation, account: keyAccount)
        } catch {
            Log.storage.error("saving the secure enclave key failed: \(Self.describe(error), privacy: .public)")
            throw error
        }
        return key
    }
}

// MARK: - Template store

/// Stores the template as an encrypted blob. Only embeddings are stored — never images.
/// Saving must only happen after the user has authenticated with their password (CLAUDE.md §6).
public struct EncryptedTemplateStore: TemplateStoring {
    private let storage: any SecureItemStorage
    private let sealer: any TemplateSealing
    private let account: String

    public init(storage: any SecureItemStorage, sealer: any TemplateSealing, account: String = "template") {
        self.storage = storage
        self.sealer = sealer
        self.account = account
    }

    /// Keychain-backed store whose key lives in the Secure Enclave.
    ///
    /// Release builds refuse to run without a Secure Enclave: a software key would sit in the
    /// same keychain as the ciphertext. Debug builds fall back to it so the VM test setup works.
    public static func makeDefault() throws -> EncryptedTemplateStore {
        let storage = KeychainItemStorage()
        if SecureEnclaveSealer.isAvailable {
            return EncryptedTemplateStore(storage: storage, sealer: SecureEnclaveSealer(storage: storage))
        }
        #if DEBUG
        Log.storage.notice("Secure Enclave unavailable; using a software key (debug builds only)")
        return EncryptedTemplateStore(storage: storage, sealer: SoftwareKeySealer(storage: storage))
        #else
        throw FaceIDError.secureEnclaveUnavailable
        #endif
    }

    public func load() throws -> EnrolledTemplate? {
        guard let sealed = try storage.read(account: account) else { return nil }
        let plaintext = try sealer.open(sealed)
        do {
            return try JSONDecoder().decode(EnrolledTemplate.self, from: plaintext)
        } catch {
            throw FaceIDError.invalidTemplate
        }
    }

    public func save(_ template: EnrolledTemplate) throws {
        guard !template.embeddings.isEmpty else { throw FaceIDError.invalidTemplate }
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(template)
        } catch {
            throw FaceIDError.invalidTemplate
        }
        // The owner is present while saving: let them allow access to an existing key first.
        try sealer.approveKeyAccess()
        let sealed = try sealer.seal(plaintext)
        do {
            try storage.write(sealed, account: account)
        } catch {
            Log.storage.error("saving the template failed: \(SecureEnclaveSealer.describe(error), privacy: .public)")
            throw error
        }
        Log.storage.notice("template saved (\(KeychainItemStorage.dataProtectionKeychainAvailable ? "data protection keychain" : "login keychain", privacy: .public))")
    }

    public func delete() throws {
        try storage.delete(account: account)
        try sealer.destroyKey()
        Log.storage.info("template deleted")
    }

    public func approveAccess() throws {
        _ = try storage.readAllowingUserInteraction(account: account)
        try sealer.approveKeyAccess()
        _ = try load()
        Log.storage.notice("keychain access approved for this agent build")
    }
}
