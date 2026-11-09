//
//  HypnosDefaults.swift
//  Hypnos
//
//  The defaults store every Hypnos setting lives in. Standalone it is the app's own
//  `UserDefaults.standard`, as ever. Built into Nexus (`NEXUS_MODULE`), which runs this app beside
//  others in one process, it is a suite of its own: the character and Longwave read unprefixed keys
//  from `standard` too, and two modules sharing one key space would overwrite each other's
//  settings. Nothing in this app reads `UserDefaults.standard` directly, and `@AppStorage` always
//  names this store.
//

import Foundation

enum HypnosDefaults {
    #if NEXUS_MODULE
    static let suiteName = "com.illixion.nexus.hypnos"
    nonisolated(unsafe) static let store: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    #else
    nonisolated(unsafe) static let store: UserDefaults = .standard
    #endif
}
