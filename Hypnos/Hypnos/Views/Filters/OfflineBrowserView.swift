//
//  OfflineBrowserView.swift
//  Hypnos
//
//  Filters → On This Device: one grid of everything the device holds that opens
//  without a network, from any source (`OfflineCatalog`), filtered by media type.
//  For a trip with no signal, and for getting back to something saved on the
//  device quickly (a generated 3D model, a downloaded film, a picture cached
//  from Stash).
//

import SwiftUI

struct OfflineBrowserView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case name = "Name"
        case size = "Size"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @PushWindowProxy private var pushWindow
    @State private var catalog = OfflineCatalog.shared
    @State private var playback = LibraryPlayback()
    @AppStorage("offline.types") private var typesRaw = ""
    @AppStorage("offline.sort") private var sortRaw = Sort.recent.rawValue
    @State private var search = ""

    private var selectedTypes: Set<OfflineMediaType> {
        Set(typesRaw.split(separator: ",").compactMap { OfflineMediaType(rawValue: String($0)) })
    }
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .recent }

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]

    /// The items that pass the type chips and the search, in the chosen order.
    private var shown: [OfflineItem] {
        let types = selectedTypes
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = catalog.items.filter { item in
            (types.isEmpty || types.contains(item.type))
                && (query.isEmpty || item.title.lowercased().contains(query)
                    || (item.subtitle?.lowercased().contains(query) ?? false))
        }
        switch sort {
        case .recent: return filtered.sorted { $0.date > $1.date }
        case .name: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    typeChips
                    if shown.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(shown) { item in
                                OfflineCard(item: item) { open(item) }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("On This Device")
            .searchable(text: $search, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Sort By", selection: $sortRaw) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .refreshable { await catalog.reload() }
        }
        .task { await catalog.reload() }
        .libraryPlayback(playback)
    }

    // MARK: - Type chips

    private var typeChips: some View {
        let counts = Dictionary(grouping: catalog.items, by: \.type).mapValues(\.count)
        let total = catalog.items.reduce(0) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    chip("All", symbol: "square.grid.2x2", count: catalog.items.count, on: selectedTypes.isEmpty) {
                        typesRaw = ""
                    }
                    ForEach(OfflineMediaType.available) { type in
                        chip(type.label, symbol: type.symbol, count: counts[type] ?? 0, on: selectedTypes.contains(type)) {
                            var types = selectedTypes
                            if types.contains(type) { types.remove(type) } else { types.insert(type) }
                            typesRaw = types.map(\.rawValue).sorted().joined(separator: ",")
                        }
                    }
                }
            }
            Text("\(shown.count) of \(catalog.items.count) items · \(total.formatted(.byteCount(style: .file))) on this device")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, symbol: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("\(title) \(count)", systemImage: symbol)
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .cardHover()
    }

    @ViewBuilder private var emptyState: some View {
        if catalog.isLoading && catalog.items.isEmpty {
            ProgressView("Looking through this device…").frame(maxWidth: .infinity).padding(.top, 60)
        } else if catalog.items.isEmpty {
            ContentUnavailableView(
                "Nothing on This Device Yet", systemImage: "internaldrive",
                description: Text("Pictures you open from a server are kept while the cache holds them. Downloaded films, files in the app's folders and generated 3D models show up here too."))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    // MARK: - Opening

    private func open(_ item: OfflineItem) {
        switch item.payload {
        case .picture(let image):
            if appModel.openMediaInNewWindows {
                appModel.enqueuePhotoWindowOpen(image)
            } else {
                pushWindow(id: HypnosSceneID.photoDetail, value: PhotoWindowValue(image: image, wasPushed: true))
            }
        case .video(let video):
            if appModel.openMediaInNewWindows {
                openWindow(id: HypnosSceneID.videoDetail, value: VideoWindowValue(video: video, galleryVideos: [video]))
            } else {
                pushWindow(id: HypnosSceneID.videoDetail, value: VideoWindowValue(video: video, galleryVideos: [video], wasPushed: true))
            }
        case .film(let film):
            Task { await playback.play(film) }
        #if HYPNOS_GEN3D && os(visionOS)
        case .model(let model):
            openWindow(id: HypnosSceneID.gen3d, value: Gen3DWindowValue(item: model))
        #endif
        }
    }
}

// MARK: - Card

private struct OfflineCard: View {
    let item: OfflineItem
    let action: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let thumbnail {
                        Image(platformImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.type.symbol).font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(item.type == .films ? 2.0 / 3.0 : 1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    Image(systemName: item.type.symbol)
                        .font(.caption2).padding(6)
                        .background(.ultraThinMaterial, in: Circle()).padding(6)
                }
                Text(item.title).font(.subheadline).lineLimit(2)
                Text([item.subtitle, item.bytes > 0 ? item.bytes.formatted(.byteCount(style: .file)) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
        }
        .buttonStyle(.plain)
        .cardHover()
        .task(id: item.id) { thumbnail = await Self.loadThumbnail(for: item) }
    }

    private static func loadThumbnail(for item: OfflineItem) async -> UIImage? {
        switch item.payload {
        case .picture(let image):
            return try? await ImageLoader.shared.loadDisplayImage(from: image.fullSizeURL, maxPixelSize: 400)
        case .video(let video):
            return await ImageLoader.shared.loadThumbnail(from: video.thumbnailURL, maxSize: 400)
        case .film(let film):
            // The poster, or an episode's landscape still, as downloaded.
            for kind in [LibraryImageKind.primary, .thumb, .backdrop] {
                if let ref = film.image(kind),
                   let url = LibraryOfflineStore.shared.artworkURL(ownerId: ref.ownerId ?? film.id, kind: kind),
                   let image = try? await ImageLoader.shared.loadDisplayImage(from: url, maxPixelSize: 400) {
                    return image
                }
            }
            return nil
        #if HYPNOS_GEN3D && os(visionOS)
        case .model(let model):
            await Gen3DLibrary.shared.makeThumbnailIfNeeded(for: model)
            return (try? Data(contentsOf: Gen3DLibrary.shared.thumbnailURL(for: model.id))).flatMap(UIImage.init(data:))
        #endif
        }
    }
}

private extension View {
    /// The gaze / pointer highlight (macOS has no `hoverEffect`).
    @ViewBuilder func cardHover() -> some View {
        #if os(macOS)
        self
        #else
        self.hoverEffect()
        #endif
    }
}
