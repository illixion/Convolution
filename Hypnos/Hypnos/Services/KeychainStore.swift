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
/// Deliberately small. There is no `keychain-access-groups` entitlement; every
/// item is a plain per-app generic password, not shared with anything.
///
/// On macOS items go to the data protection keychain (the iOS-style one) rather
/// than the legacy file-based login keychain. A login-keychain item's ACL pins
/// the creating binary's code signature, so any build signed differently (and
/// every rebuild of an ad-hoc-signed debug build) gets a "Hypnos wants to use
/// your confidential information" password prompt. The data protection keychain
/// keys access on the app identifier instead and never prompts. It needs a
/// team-signed build; see `Backend` for what happens without one.
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
        #if os(macOS) && DEBUG
        if backend == .debugFile { return DebugFileStore.string(for: key) }
        #endif
        if let value = keychainString(for: key) { return value }
        #if os(macOS)
        return migrateFromLoginKeychain(key)
        #else
        return nil
        #endif
    }

    private static func keychainString(for key: Key) -> String? {
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
        #if os(macOS) && DEBUG
        if backend == .debugFile { return DebugFileStore.set(value, for: key) }
        #endif

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
        #if os(macOS) && DEBUG
        if backend == .debugFile { return DebugFileStore.remove(key) }
        #endif
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        // Deleting something that was never there is the desired end state.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLogger.app.error("Keychain delete failed for \(key.rawValue, privacy: .public): OSStatus \(status)")
            return false
        }
        return true
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        #if os(macOS)
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    // MARK: - macOS backend

    #if os(macOS)
    /// Where secrets go on this Mac build.
    enum Backend {
        /// The data protection keychain: team-signed builds (release, and
        /// debug builds with a development team set).
        case dataProtection
        /// The legacy login keychain. Only for a release build that somehow
        /// lacks an app identifier, where a prompt beats losing credentials.
        case loginKeychain
        /// A file in the sandbox container, for debug builds signed without a
        /// provisioning profile (ad hoc, or "Sign to Run Locally"). They have
        /// no app identifier, so the data protection keychain refuses them
        /// (errSecMissingEntitlement), and the login keychain prompts after
        /// every rebuild because its ACL pins the exact code signature.
        case debugFile
    }

    /// Decided once from this build's own signature. The data protection
    /// keychain needs an app identifier entitlement, which only a
    /// provisioning-profile-signed build carries. Probing the keychain instead
    /// does not work: a read without the entitlement answers "not found", and
    /// only a write reports errSecMissingEntitlement.
    static let backend: Backend = {
        if let task = SecTaskCreateFromSelf(nil),
           SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil {
            return .dataProtection
        }
        #if DEBUG
        AppLogger.app.info("Keychain: no app identifier (debug build without a provisioning profile); storing credentials in the container")
        return .debugFile
        #else
        AppLogger.app.error("Keychain: no app identifier; falling back to the login keychain")
        return .loginKeychain
        #endif
    }()

    /// Moves an item that an earlier build wrote to the login keychain into
    /// the data protection keychain, without ever showing the ACL prompt: an
    /// item this binary is not trusted for is left behind (the user re-enters
    /// the credential once) rather than interrupting with a password dialog.
    private static func migrateFromLoginKeychain(_ key: Key) -> String? {
        guard backend == .dataProtection else { return nil }
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        var read = legacy
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = withoutLoginKeychainPrompts { SecItemCopyMatching(read as CFDictionary, &result) }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty,
              set(value, for: key)
        else { return nil }
        _ = withoutLoginKeychainPrompts { SecItemDelete(legacy as CFDictionary) }
        AppLogger.app.info("Moved \(key.rawValue, privacy: .public) from the login keychain to the data protection keychain")
        return value
    }

    /// Runs `body` with login-keychain ACL prompts turned off, so an item this
    /// binary is not trusted for fails with errSecAuthFailed instead of showing
    /// the password dialog. Neither `kSecUseAuthenticationUIFail` nor an
    /// `LAContext` with `interactionNotAllowed` stops that dialog (tested on
    /// macOS 27); only the deprecated process-wide
    /// `SecKeychainSetUserInteractionAllowed` does. It is looked up at run time
    /// so this one-off migration read does not leave a permanent deprecation
    /// warning in the build.
    private static func withoutLoginKeychainPrompts(_ body: () -> OSStatus) -> OSStatus {
        typealias SetInteractionAllowed = @convention(c) (UInt8) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "SecKeychainSetUserInteractionAllowed")
        else { return errSecInteractionNotAllowed } // never risk the prompt
        let setAllowed = unsafeBitCast(symbol, to: SetInteractionAllowed.self)
        _ = setAllowed(0)
        defer { _ = setAllowed(1) }
        return body()
    }
    #endif

    #if os(macOS) && DEBUG
    /// Plain files under Application Support in the app's sandbox container,
    /// readable only by this user. Debug builds only, and only when the build
    /// cannot use either keychain without prompting; see `Backend.debugFile`.
    private enum DebugFileStore {
        private static var directory: URL? {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("DebugCredentials", isDirectory: true)
        }

        static func string(for key: Key) -> String? {
            guard let url = directory?.appendingPathComponent(key.rawValue),
                  let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty
            else { return nil }
            return value
        }

        static func set(_ value: String, for key: Key) -> Bool {
            guard let directory else { return false }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(key.rawValue)
                try Data(value.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch {
                AppLogger.app.error("Debug credential write failed for \(key.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        static func remove(_ key: Key) -> Bool {
            guard let url = directory?.appendingPathComponent(key.rawValue) else { return true }
            try? FileManager.default.removeItem(at: url)
            return true
        }
    }
    #endif

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
