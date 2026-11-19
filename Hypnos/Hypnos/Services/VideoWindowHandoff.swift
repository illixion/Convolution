//
//  VideoWindowHandoff.swift
//  Hypnos
//
//  Keep a live video window model and native player together while a pushed
//  player is popped out into its own scene. The handoff id travels in the
//  Codable window value; the model and renderer stay in this process only.
//

import Foundation

@MainActor
enum VideoWindowHandoff {
    private struct Entry {
        let model: VideoWindowModel
        var expiry: Task<Void, Never>?
    }

    private static let gracePeriod: Duration = .seconds(30)
    private static var entries: [UUID: Entry] = [:]

    static func deposit(_ model: VideoWindowModel) -> UUID? {
        guard model.prepareForWindowHandoff() else { return nil }
        let id = UUID()
        entries[id] = Entry(model: model, expiry: nil)
        entries[id]?.expiry = Task { @MainActor in
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled, let entry = entries.removeValue(forKey: id) else { return }
            entry.model.cancelWindowHandoff()
        }
        return id
    }

    static func claim(_ id: UUID) -> VideoWindowModel? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.expiry?.cancel()
        return entry.model
    }
}
