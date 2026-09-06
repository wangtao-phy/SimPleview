import Foundation
import Security

// Replace only Security's OS boundary with a deterministic vault. No access to
// the user's login keychain or actual credentials is required for failure tests.
enum ReviewDefaults { static let standard = UserDefaults(suiteName: "SimPleview.KeyRegression." + UUID().uuidString)! }
enum TestVault {
    static var values: [String: Data] = [:]
    static var value: Data? { get { values["default"] } set { values["default"] = newValue } }
    static func account(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    static var refuse = false
    static func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if refuse { return errSecInteractionNotAllowed }
        guard let value = values[account(query)] else { return errSecItemNotFound }
        result?.pointee = value as CFData; return errSecSuccess
    }
    static func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        if refuse { return errSecInteractionNotAllowed }
        guard values[account(query)] != nil else { return errSecItemNotFound }
        values[account(query)] = (attributes as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }
    static func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if refuse { return errSecInteractionNotAllowed }
        values[account(query)] = (query as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }
    static func SecItemDelete(_ query: CFDictionary) -> OSStatus {
        if refuse { return errSecInteractionNotAllowed }
        values[account(query)] = nil; return errSecSuccess
    }
}
@main struct KeyStoreHarness {
    static func main() throws {
        ReviewDefaults.standard.set("fake-legacy-value", forKey: "aiAPIKey")
        TestVault.refuse = true
        do { _ = try APIKeyStore.load(); fatalError("expected access failure") } catch {}
        precondition(ReviewDefaults.standard.string(forKey: "aiAPIKey") == "fake-legacy-value")
        TestVault.refuse = false
        let migrated = try APIKeyStore.load()
        precondition(migrated == "fake-legacy-value" && ReviewDefaults.standard.object(forKey: "aiAPIKey") == nil)
        try APIKeyStore.save("fake-new-value"); let changed = try APIKeyStore.load(); precondition(changed == "fake-new-value")
        try APIKeyStore.save(""); precondition(TestVault.value == nil)
        try APIKeyStore.save("key-A", account: "provider-A")
        try APIKeyStore.save("key-B", account: "provider-B")
        let a = try APIKeyStore.load(account: "provider-A"), b = try APIKeyStore.load(account: "provider-B")
        precondition(a == "key-A" && b == "key-B")
        try APIKeyStore.save("", account: "provider-A")
        let remaining = try APIKeyStore.load(account: "provider-B"); precondition(remaining == "key-B")
        print("PASS independent provider keychain accounts; deleting A preserves B (mock OS vault)")
        print("PASS key migration preserves legacy value on refusal, removes it after success, updates and deletes (mock OS vault)")
    }
}
