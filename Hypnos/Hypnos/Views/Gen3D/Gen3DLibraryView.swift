//
//  Gen3DLibraryView.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D), visionOS: every generated model the cache
//  still holds, to browse and open. Opening one brings it up as it was left
//  (size, turn, light), ready to adjust further.
//

#if HYPNOS_GEN3D && os(visionOS)

import SwiftUI

struct Gen3DLibraryView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @State private var library = Gen3DLibrary.shared
    @State private var pendingDelete: Gen3DLibraryItem?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView(
                        "No Models Yet", systemImage: "cube.transparent",
                        description: Text("Models you generate from the photo viewer's 3D menu are kept here, until the cache needs the room."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(library.items) { item in
                                card(item)
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Generated 3D Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(library.items.reduce(0) { $0 + $1.bytes }.formatted(.byteCount(style: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { library.refresh() }
        .confirmationDialog(
            "Delete this model?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                if let item = pendingDelete { library.remove(key: item.id) }
                pendingDelete = nil
            }
        } message: {
            Text("It is generated again if you ask for it, which takes a couple of minutes.")
        }
    }

    private func card(_ item: Gen3DLibraryItem) -> some View {
        Button {
            openWindow(id: HypnosSceneID.gen3d, value: Gen3DWindowValue(item: item))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Gen3DThumbnail(item: item, version: library.thumbnailVersion)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(item.title).font(.subheadline).lineLimit(2)
                Text("\(item.record.engine) · \(item.bytes.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .contextMenu {
            Button("Open", systemImage: "cube") { openWindow(id: HypnosSceneID.gen3d, value: Gen3DWindowValue(item: item)) }
            Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = item }
        }
        .task { await library.makeThumbnailIfNeeded(for: item) }
    }
}

private struct Gen3DThumbnail: View {
    let item: Gen3DLibraryItem
    /// Read so a thumbnail that lands later redraws the card.
    let version: Int

    var body: some View {
        let url = Gen3DLibrary.shared.thumbnailURL(for: item.id)
        ZStack {
            Rectangle().fill(.quaternary)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .id(version)
    }
}

#endif

#if HYPNOS_GEN3D && os(visionOS)

private struct RestoreGen3DModels: ViewModifier {
    @OpenWindowProxy private var openWindow

    func body(content: Content) -> some View {
        content.task {
            await Gen3DOpenWindows.restoreIfNeeded { openWindow(id: HypnosSceneID.gen3d, value: $0) }
        }
    }
}

extension View {
    /// Brings back the model volumes that were open at the last launch.
    func restoreGen3DModels() -> some View { modifier(RestoreGen3DModels()) }
}

#endif
