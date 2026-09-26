import Foundation
import os
import Security

/// The app's credential store.
///
/// Server *addresses* stay in UserDefaults — they are configuration, and having
/// them readable makes support and backup restore straightforward. Secrets (the
/// Stash API key, a Nextcloud app password) live here instead, because the
/// defaults plist is an ordinary file inside the container: readable by anything
/// that can reach the container, included verbatim in an unencrypted device
/// backup, and trivially dumped from a jailbroken or restored image.
///
/// Deliberately small. There is no entitlements file in this project and so no
/// `keychain-access-groups`; every item is a plain per-app generic password,
/// which needs no entitlement and is not shared with anything.
enum KeychainStore {

    /// Namespaces items so two keys never collide with another app's.
    private static let service = "com.illixion.hypnos.credentials"

    /// Which secret an item holds. An enum rather than free-form strings so a
    /// typo is a compile error rather than a silently empty credential.
    enum Key: String, CaseIterable {
        case stashAPIKey
        case nextcloudAppPassword
        case jellyfinAPIKey
        /// Access token from `/Users/AuthenticateByName` (username/password
        /// sign-in) — distinct from `jellyfinAPIKey`, which is a
        /// server-issued API key with no associated user. See
        /// `JellyfinAuth.swift`.
        case jellyfinAccessToken
    }

    // MARK: - Reading

    /// The stored secret, or nil when absent or unreadable.
    ///
    /// Returns nil rather than throwing on failure: every caller's answer to "I
    /// could not read the credential" is the same as its answer to "there is no
    /// credential" — proceed unauthenticated and let the server object. A throw
    /// would just be caught and discarded at each call site.
    static func string(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                // Not the secret, just why it could not be read.
                AppLogger.app.error("Keychain read failed for \(key.rawValue, privacy: .public): OSStatus \(status)")
            }
            return nil
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: - Writing

    /// Stores a secret, or removes it when `value` is nil or empty.
    ///
    /// Treating empty as removal matters because the settings fields bind to
    /// non-optional `String`s: clearing the text field must delete the item, not
    /// store a zero-length password that later reads back as "present".
    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        guard let value, !value.isEmpty else {
            return remove(key)
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        // Update first; add only if nothing is there. SecItemAdd on an existing
        // item fails with errSecDuplicateItem rather than overwriting.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            AppLogger.app.error("Keychain update failed for \(key.rawValue, privacy: .public): OSStatus \(updateStatus)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        // The credential is only ever used while the app is running in the
        // foreground, so it does not need to survive a locked device, and
        // ThisDeviceOnly keeps it out of iCloud Keychain and encrypted backups.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            AppLogger.app.error("Keychain add failed for \(key.rawValue, privacy: .public): OSStatus \(addStatus)")
            return false
        }
        return true
    }

    @discardableResult
    static func remove(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        // Deleting something that was never there is the desired end state.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLogger.app.error("Keychain delete failed for \(key.rawValue, privacy: .public): OSStatus \(status)")
            return false
        }
        return true
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    // MARK: - Migration off UserDefaults

    /// Moves a secret that earlier versions wrote to UserDefaults into the
    /// Keychain, then deletes the plaintext copy.
    ///
    /// Run before the value is first read, and idempotent: once the defaults key
    /// is gone this does nothing. Returns the migrated value so a caller can use
    /// it without a second read.
    ///
    /// The defaults entry is removed **only after** the Keychain write is
    /// confirmed. A failed write that had already deleted the plaintext would
    /// silently log the user out of their server with no way back.
    @discardableResult
    static func migrateFromUserDefaults(legacyKey: String, to key: Key,
                                        defaults: UserDefaults = .standard) -> String? {
        guard let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty else {
            // Nothing to migrate. Tidy up an empty-string leftover so this stops
            // being asked on every launch.
            if defaults.object(forKey: legacyKey) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
            return nil
        }

        guard set(legacy, for: key) else {
            AppLogger.app.error("Keychain migration for \(key.rawValue, privacy: .public) failed; leaving the UserDefaults copy in place")
            return legacy
        }

        defaults.removeObject(forKey: legacyKey)
        AppLogger.app.info("Migrated \(key.rawValue, privacy: .public) from UserDefaults into the Keychain")
        return legacy
    }
}
