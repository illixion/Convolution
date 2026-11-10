/*
 Hypnos - Choosing an accessory for the sleep timer

 Every controllable accessory of the chosen home, by room, with its icon and
 current state, and then the state to leave it in. Both homes read through
 RAVEHome's `HomeBackend`, so this is one list whichever the accessory is in.
 */

import RAVEHome
import SwiftUI

struct SleepTimerAccessoryPicker: View {
    private let home = SleepHome.shared
    @Environment(\.dismiss) private var dismiss
    @State private var source: HomeSource?
    @State private var search = ""

    private var activeSource: HomeSource? {
        source.flatMap { home.backend(for: $0) != nil ? $0 : nil } ?? home.availableSources.first
    }

    var body: some View {
        Group {
            if let active = activeSource, let backend = home.backend(for: active) {
                list(source: active, backend: backend)
            } else {
                ContentUnavailableView {
                    Label("No Home Connected", systemImage: "house")
                } description: {
                    Text("Set up Home Assistant or HomeKit in Sleep Timer settings first.")
                }
            }
        }
        .navigationTitle("Add Accessory")
        .task { home.prepareConfigured() }
    }

    private func list(source active: HomeSource, backend: any HomeBackend) -> some View {
        List {
            if home.availableSources.count > 1 {
                Section {
                    Picker("Home", selection: Binding(get: { active }, set: { source = $0 })) {
                        ForEach(home.availableSources) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            if !backend.isConnected {
                Section {
                    SleepHomeStatusRow(source: active, status: backend.status, detail: nil)
                }
            }
            ForEach(sections(of: backend), id: \.room) { section in
                Section(section.room) {
                    ForEach(section.entities) { entity in
                        NavigationLink {
                            SleepTimerActionEditor(adding: entity, source: active, backend: backend,
                                                   onFinish: { dismiss() })
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: EntityIcon.symbol(for: entity))
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entity.friendlyName)
                                    Text(entity.displayState).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search)
        .overlay {
            if backend.isConnected, sections(of: backend).isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Accessories" : "No Matches",
                                       systemImage: search.isEmpty ? "lightbulb.slash" : "magnifyingglass")
            }
        }
    }

    private struct RoomSection {
        let room: String
        let entities: [HAEntity]
    }

    private func sections(of backend: any HomeBackend) -> [RoomSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let found = backend.entities.values.filter { entity in
            HomeDesiredState.isControllable(entity)
                && (query.isEmpty || entity.friendlyName.localizedCaseInsensitiveContains(query)
                    || (backend.areaName(forEntity: entity.entityId) ?? "").localizedCaseInsensitiveContains(query))
        }
        let byRoom = Dictionary(grouping: found) { backend.areaName(forEntity: $0.entityId) ?? "No Room" }
        return byRoom
            .map { RoomSection(room: $0.key, entities: $0.value.sorted { $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending }) }
            .sorted { lhs, rhs in
                // "No Room" last, the rest alphabetical.
                if (lhs.room == "No Room") != (rhs.room == "No Room") { return rhs.room == "No Room" }
                return lhs.room.localizedStandardCompare(rhs.room) == .orderedAscending
            }
    }
}

/// Choose the state for an accessory, then add it to the timer's actions (or
/// save a change to one already there).
struct SleepTimerActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var target: HomeActionTarget
    private let isNew: Bool
    private let options: [HomeDesiredState]
    private let onFinish: () -> Void

    /// Levels offered for a level state: the common dim steps, never 0 (that is Off).
    private static let levels = [5] + Array(stride(from: 10, through: 100, by: 10))

    init(adding entity: HAEntity, source: HomeSource, backend: any HomeBackend, onFinish: @escaping () -> Void) {
        let options = HomeDesiredState.options(for: entity)
        _target = State(initialValue: HomeActionTarget(entity: entity, source: source, backend: backend,
                                                       state: options.first ?? .off))
        self.options = options
        self.isNew = true
        self.onFinish = onFinish
    }

    init(editing action: HomeActionTarget) {
        _target = State(initialValue: action)
        let live = SleepHome.shared.backend(for: action.source)?.entities[action.entityId]
        self.options = live.map(HomeDesiredState.options(for:))
            ?? HomeDesiredState.options(forDomain: action.domain, supportsLevel: action.state.isLevel)
        self.isNew = false
        self.onFinish = {}
    }

    var body: some View {
        Form {
            Section {
                SleepTimerActionRow(action: target)
            }
            Section("Set To") {
                ForEach(options, id: \.self) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack {
                            Text(option.isLevel ? "Brightness or Position" : option.title)
                            Spacer()
                            if option.sameKind(as: target.state) { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if case .level(let percent) = target.state {
                    Picker("Level", selection: Binding(get: { percent }, set: { target.state = .level($0) })) {
                        ForEach(Self.levels, id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
            }
            Section {
                Button(isNew ? "Add Action" : "Save") {
                    if isNew { SleepTimer.shared.add(target) } else { SleepTimer.shared.replace(target) }
                    dismiss()
                    onFinish()
                }
                if !isNew {
                    Button("Remove", role: .destructive) {
                        if let index = SleepTimer.shared.homeActions.firstIndex(where: { $0.id == target.id }) {
                            SleepTimer.shared.remove(at: IndexSet(integer: index))
                        }
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Action" : "Edit Action")
    }

    private func select(_ option: HomeDesiredState) {
        if option.isLevel, case .level = target.state { return }
        target.state = option
    }
}
