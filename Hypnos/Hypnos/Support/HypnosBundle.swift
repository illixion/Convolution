//
//  HypnosBundle.swift
//  Hypnos
//
//  The bundle this app's own resources (scripts, models, the Metal library, the asset catalog) are
//  in. Standalone that is the main bundle. Built into Nexus as a framework it is the framework,
//  which `Bundle.main` is not, so resources are always looked up here.
//

import Foundation

enum HypnosBundle {
    private final class Token {}

    static let resources = Bundle(for: Token.self)
}
