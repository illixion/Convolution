/*
 Hypnos - Media Detail Sheet

 Two-tab sheet for viewing and editing image/video metadata.
 Tab 1 (Info): read-only file metadata, associations, stats.
 Tab 2 (Edit): editable fields with save/cancel, plus delete.
 Fetches full detail on-demand when the sheet opens.
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

// MARK: - Media Type Abstraction

/// Identifies whether this sheet is for an image or a scene/video.
enum MediaDetailType {
    case image(stashId: String)
    case scene(stashId: String)

    var stashId: String {
        switch self {
        case .image(let id): return id
        case .scene(let id): return id
        }
    }
}

/// Normalized snapshot of the editable fields, used to detect unsaved changes
/// so closing the sheet only writes to the server when something changed.
private struct EditSnapshot: Equatable {
    var title: String
    var code: String
    var date: String
    var details: String
    var creator: String
    var rating100: Int?
    var organized: Bool
    var urls: [String]
    var studioId: String?
    var performerIds: [String]
    var tagIds: [String]
}

// MARK: - Sheet View

struct MediaDetailSheet: View {
    let mediaType: MediaDetailType
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @OpenWindowProxy private var openWindow

    @State private var selectedTab = 0
    @State private var isLoading = true
    @State private var loadError: String?

    // Detail data (loaded on appear)
    @State private var imageDetail: ImageDetail?
    @State private var sceneDetail: SceneDetail?

    // Edit state
    @State private var editTitle: String = ""
    @State private var editCode: String = ""
    @State private var editDate: String = ""
    @State private var editDetails: String = ""
    @State private var editCreator: String = "" // photographer or director
    @State private var editRating100: Int? = nil
    @State private var editOrganized: Bool = false
    @State private var editUrls: [String] = []
    @State private var editStudio: MediaStudio? = nil
    @State private var editPerformers: [MediaPerformer] = []
    @State private var editTags: [MediaTag] = []
    @State private var editGalleries: [MediaGalleryRef] = []

    // Search state for pickers
    @State private var tagSearchText: String = ""
    @State private var tagSearchResults: [MediaTag] = []
    @State private var performerSearchText: String = ""
    @State private var performerSearchResults: [MediaPerformer] = []
    @State private var studioSearchText: String = ""
    @State private var studioSearchResults: [MediaStudio] = []

    // Save / delete state
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    // O counter state
    @State private var isUpdatingOCounter = false

    /// Called after a successful delete so the parent can remove the item and navigate away.
    var onDelete: (() -> Void)?

    /// Called after a successful save with the new rating100, so the presenting
    /// view can refresh its displayed item (e.g. the ornament's rating icon).
    var onSaved: ((Int?) -> Void)?

    /// Snapshot of the edit fields as last loaded/saved. Drives `hasUnsavedChanges`
    /// so closing the sheet only writes when something actually changed.
    @State private var originalSnapshot: EditSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                        Button("Retry") { Task { await loadDetail() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    #if os(tvOS)
                    // Read-only on a TV: with no lock screen, editing would
                    // let anyone with the remote strip tags, performers and
                    // URLs off the server's items. Ratings stay in the
                    // thumbnail menu.
                    infoTab
                    #else
                    VStack(spacing: 0) {
                        Picker("Mode", selection: $selectedTab) {
                            Label("Info", systemImage: "info.circle").tag(0)
                            Label("Edit", systemImage: "pencil").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        if selectedTab == 0 {
                            infoTab
                        } else {
                            editTab
                        }
                    }
                    #endif
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Done") {
                        let model = appModel
                        Task {
                            if await commitChanges(using: model) { dismiss() }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 650)
        .task { await loadDetail() }
        .onDisappear {
            // Persist edits for any close path that didn't go through "Done"
            // (e.g. swipe-to-dismiss). Capture the model synchronously while the
            // environment is still valid, then save off the main close path.
            guard hasUnsavedChanges else { return }
            let model = appModel
            Task { _ = await commitChanges(using: model) }
        }
        .confirmationDialog(
            "Delete Item",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Stash", role: .destructive) {
                Task { await performDelete(deleteFile: false) }
            }
            Button("Delete File from Disk", role: .destructive) {
                Task { await performDelete(deleteFile: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. Removing from Stash keeps the file on disk. Deleting from disk permanently removes the file.")
        }
    }

    private var navigationTitle: String {
        switch mediaType {
        case .image: return "Image Details"
        case .scene: return "Video Details"
        }
    }

    // MARK: - Info Tab

    private var infoTab: some View {
        List {
            // File section
            Section("File") {
                if let path = filePath {
                    copyableLabeledRow("Path", value: path)
                }
                if let w = fileWidth, let h = fileHeight {
                    copyableLabeledRow("Dimensions", value: "\(w) x \(h)")
                }
                if let size = fileSize {
                    copyableLabeledRow("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let format = fileFormat {
                    copyableLabeledRow("Format", value: format)
                }
                // Video-specific
                if let detail = sceneDetail {
                    if let codec = detail.videoCodec {
                        copyableLabeledRow("Video Codec", value: codec)
                    }
                    if let codec = detail.audioCodec {
                        copyableLabeledRow("Audio Codec", value: codec)
                    }
                    if let fps = detail.frameRate {
                        copyableLabeledRow("Frame Rate", value: String(format: "%.2f fps", fps))
                    }
                    if let br = detail.bitrate {
                        copyableLabeledRow("Bitrate", value: formatBitrate(br))
                    }
                    if let dur = detail.duration {
                        copyableLabeledRow("Duration", value: formatDuration(dur))
                    }
                }
            }

            // Details section
            Section("Details") {
                if let title = currentTitle, !title.isEmpty {
                    copyableLabeledRow("Title", value: title)
                }
                if let code = currentCode, !code.isEmpty {
                    copyableLabeledRow("Code", value: code)
                }
                if let date = currentDate, !date.isEmpty {
                    copyableLabeledRow("Date", value: date)
                }
                if let creator = currentCreator, !creator.isEmpty {
                    copyableLabeledRow(creatorLabel, value: creator)
                }
                if let details = currentDetails, !details.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Details")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(details)
                            .copyOnHold(details)
                    }
                }
            }

            // Associations section
            Section("Associations") {
                if let studio = currentStudio {
                    copyableLabeledRow("Studio", value: studio.name)
                }
                if !currentPerformers.isEmpty {
                    associationGroup(label: "Performers", items: currentPerformers.map(\.name))
                }
                if !currentTags.isEmpty {
                    tagsAssociationGroup(currentTags)
                }
                if !currentGalleries.isEmpty {
                    associationGroup(
                        label: "Galleries",
                        items: currentGalleries.map { $0.title ?? "Gallery \($0.id)" }
                    )
                }
                if let groups = currentGroups, !groups.isEmpty {
                    associationGroup(label: "Groups", items: groups.map(\.name))
                }
            }

            // Stats section
            Section("Stats") {
                ratingDisplay
                oCounterDisplay
                if let detail = sceneDetail {
                    if let count = detail.playCount {
                        copyableLabeledRow("Play Count", value: "\(count)")
                    }
                    if let dur = detail.playDuration, dur > 0 {
                        copyableLabeledRow("Play Duration", value: formatDuration(dur))
                    }
                }
                LabeledContent("Organized", value: currentOrganized ? "Yes" : "No")
            }

            // URLs section
            if !currentUrls.isEmpty {
                Section("URLs") {
                    ForEach(currentUrls, id: \.self) { url in
                        Text(url)
                            .font(.callout)
                            .lineLimit(2)
                            .copyOnHold(url)
                    }
                }
            }
        }
    }

    // MARK: - Copy helpers

    /// LabeledContent row with a context menu offering Copy of the value.
    /// On visionOS, pinch-and-hold opens the context menu via gaze focus,
    /// which avoids the tap-location issues caused by gaze drift.
    private func copyableLabeledRow(_ label: String, value: String) -> some View {
        LabeledContent(label, value: value)
            .copyOnHold(value)
    }

    /// Collapsible association group: shows a comma-separated inline summary by default,
    /// expands to a flat list of individually copyable rows on tap. Using a list-row layout
    /// avoids the chip/hover-shape problems where the system highlight wrapped the whole
    /// section instead of an individual badge.
    @ViewBuilder
    private func associationGroup(label: String, items: [String]) -> some View {
        let cleaned = items.filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            platformDisclosureGroup {
                ForEach(Array(cleaned.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .copyOnHold(item)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .foregroundColor(.secondary)
                    Text(cleaned.joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Tags association group where each expanded row is tappable: it opens a
    /// new gallery window filtered to that single tag, in the Pictures or Videos
    /// section depending on this sheet's media type. Falls back to copy-on-hold
    /// for the tag name, matching the other association rows.
    @ViewBuilder
    private func tagsAssociationGroup(_ tags: [MediaTag]) -> some View {
        let cleaned = tags.filter { !$0.name.isEmpty }
        if !cleaned.isEmpty {
            platformDisclosureGroup {
                ForEach(cleaned) { tag in
                    Button {
                        openTagGallery(tag)
                    } label: {
                        HStack {
                            Text(tag.name)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .copyOnHold(tag.name)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags")
                        .foregroundColor(.secondary)
                    Text(cleaned.map(\.name).joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Opens a new gallery window filtered by the given tag, choosing the
    /// Pictures or Videos section based on the current media type, then closes
    /// this sheet.
    private func openTagGallery(_ tag: MediaTag) {
        let isVideo: Bool
        switch mediaType {
        case .image: isVideo = false
        case .scene: isVideo = true
        }
        appModel.openGalleryFilteredByTag(id: tag.id, name: tag.name, isVideo: isVideo, openWindow: openWindow)
        dismiss()
    }

    // MARK: - Edit Tab

    private var editTab: some View {
        List {
            Section("Details") {
                TextField("Title", text: $editTitle)
                TextField("Code", text: $editCode)
                TextField("Date (YYYY-MM-DD)", text: $editDate)
                TextField(creatorLabel, text: $editCreator)

                VStack(alignment: .leading) {
                    Text("Details")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    #if !os(tvOS)
                    TextEditor(text: $editDetails)
                        .frame(minHeight: 80)
                    #else
                    // No multi-line text editor on tvOS, and this edit tab
                    // isn't part of the tvOS root UI in the first place (see
                    // Hypnos/CLAUDE.md "tvOS") — a single-line fallback keeps
                    // the module compiling.
                    TextField("Details", text: $editDetails)
                    #endif
                }
            }

            Section("Rating & Activity") {
                ratingEditor
                oCounterEditor
                Toggle("Organized", isOn: $editOrganized)
            }

            Section("Studio") {
                if let studio = editStudio {
                    HStack {
                        Text(studio.name)
                        Spacer()
                        Button {
                            editStudio = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Search studios...", text: $studioSearchText)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                .onChange(of: studioSearchText) { _, query in
                    Task { await searchStudios(query: query) }
                }
                ForEach(studioSearchResults) { studio in
                    Button {
                        editStudio = studio
                        studioSearchText = ""
                        studioSearchResults = []
                    } label: {
                        Text(studio.name)
                    }
                }
            }

            Section("Performers") {
                FlowLayout(spacing: 6) {
                    ForEach(editPerformers) { performer in
                        HStack(spacing: 4) {
                            Text(performer.name)
                            Button {
                                editPerformers.removeAll { $0.id == performer.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack {
                    TextField("Search performers...", text: $performerSearchText)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                .onChange(of: performerSearchText) { _, query in
                    Task { await searchPerformers(query: query) }
                }
                ForEach(performerSearchResults) { performer in
                    Button {
                        if !editPerformers.contains(where: { $0.id == performer.id }) {
                            editPerformers.append(performer)
                        }
                        performerSearchText = ""
                        performerSearchResults = []
                    } label: {
                        Text(performer.name)
                    }
                }
            }

            Section("Tags") {
                FlowLayout(spacing: 6) {
                    ForEach(editTags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                            Button {
                                editTags.removeAll { $0.id == tag.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack {
                    TextField("Search tags...", text: $tagSearchText)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                .onChange(of: tagSearchText) { _, query in
                    Task { await searchTags(query: query) }
                }
                ForEach(tagSearchResults) { tag in
                    Button {
                        if !editTags.contains(where: { $0.id == tag.id }) {
                            editTags.append(tag)
                        }
                        tagSearchText = ""
                        tagSearchResults = []
                    } label: {
                        Text(tag.name)
                    }
                }
            }

            Section("URLs") {
                ForEach(editUrls.indices, id: \.self) { index in
                    HStack {
                        TextField("URL", text: $editUrls[index])
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button {
                            editUrls.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    editUrls.append("")
                } label: {
                    Label("Add URL", systemImage: "plus")
                }
            }

            // Changes are committed automatically when the sheet is closed
            // (see commitChanges); only surface an error if a save fails.
            if let error = saveError {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.callout)
                }
            }

            // Delete section. None on a TV (`MediaDeletion.isAvailable`).
            if MediaDeletion.isAvailable {
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        } else {
                            Label("Delete", systemImage: "trash")
                                .foregroundColor(.red)
                        }
                        Spacer()
                    }
                }
                .disabled(isDeleting)
            }
            }
        }
    }

    // MARK: - Rating Display / Editor

    private var ratingDisplay: some View {
        HStack {
            Text("Rating")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= currentStarRating ? "star.fill" : "star")
                        .foregroundColor(star <= currentStarRating ? .yellow : .gray)
                        .font(.callout)
                }
            }
        }
    }

    private var ratingEditor: some View {
        HStack {
            Text("Rating")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        editRating100 = ImageFilterCriteria.ratingToAPI(star)
                    } label: {
                        Image(systemName: star <= editStarRating ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(star <= editStarRating ? .yellow : .gray)
                    }
                    .buttonStyle(.borderless)
                }
                if editRating100 != nil {
                    Button {
                        editRating100 = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - O Counter Display / Editor

    private var oCounterDisplay: some View {
        LabeledContent("Activity", value: "\(currentOCounter)")
    }

    private var oCounterEditor: some View {
        HStack {
            Text("Activity")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 12) {
                Button {
                    Task { await decrementOCounter() }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(currentOCounter <= 0 || isUpdatingOCounter)

                if isUpdatingOCounter {
                    ProgressView()
                        .frame(minWidth: 30)
                } else {
                    Text("\(currentOCounter)")
                        .font(.title3.monospacedDigit())
                        .frame(minWidth: 30)
                }

                Button {
                    Task { await incrementOCounter() }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(isUpdatingOCounter)
            }
        }
    }

    // MARK: - Computed Properties for current detail

    private var currentTitle: String? {
        switch mediaType {
        case .image: return imageDetail?.title
        case .scene: return sceneDetail?.title
        }
    }

    private var currentCode: String? {
        switch mediaType {
        case .image: return imageDetail?.code
        case .scene: return sceneDetail?.code
        }
    }

    private var currentDate: String? {
        switch mediaType {
        case .image: return imageDetail?.date
        case .scene: return sceneDetail?.date
        }
    }

    private var currentDetails: String? {
        switch mediaType {
        case .image: return imageDetail?.details
        case .scene: return sceneDetail?.details
        }
    }

    private var currentCreator: String? {
        switch mediaType {
        case .image: return imageDetail?.photographer
        case .scene: return sceneDetail?.director
        }
    }

    private var creatorLabel: String {
        switch mediaType {
        case .image: return "Photographer"
        case .scene: return "Director"
        }
    }

    private var currentStudio: MediaStudio? {
        switch mediaType {
        case .image: return imageDetail?.studio
        case .scene: return sceneDetail?.studio
        }
    }

    private var currentPerformers: [MediaPerformer] {
        switch mediaType {
        case .image: return imageDetail?.performers ?? []
        case .scene: return sceneDetail?.performers ?? []
        }
    }

    private var currentTags: [MediaTag] {
        switch mediaType {
        case .image: return imageDetail?.tags ?? []
        case .scene: return sceneDetail?.tags ?? []
        }
    }

    private var currentGalleries: [MediaGalleryRef] {
        switch mediaType {
        case .image: return imageDetail?.galleries ?? []
        case .scene: return sceneDetail?.galleries ?? []
        }
    }

    private var currentGroups: [MediaGroupRef]? {
        switch mediaType {
        case .image: return nil
        case .scene: return sceneDetail?.groups
        }
    }

    private var currentUrls: [String] {
        switch mediaType {
        case .image: return imageDetail?.urls ?? []
        case .scene: return sceneDetail?.urls ?? []
        }
    }

    private var currentOrganized: Bool {
        switch mediaType {
        case .image: return imageDetail?.organized ?? false
        case .scene: return sceneDetail?.organized ?? false
        }
    }

    private var currentStarRating: Int {
        let rating = (imageDetail?.rating100 ?? sceneDetail?.rating100) ?? 0
        return rating > 0 ? ImageFilterCriteria.ratingFromAPI(rating) : 0
    }

    private var editStarRating: Int {
        guard let r = editRating100 else { return 0 }
        return ImageFilterCriteria.ratingFromAPI(r)
    }

    private var currentOCounter: Int {
        switch mediaType {
        case .image: return imageDetail?.oCounter ?? 0
        case .scene: return sceneDetail?.oCounter ?? 0
        }
    }

    private var filePath: String? {
        switch mediaType {
        case .image: return imageDetail?.filePath
        case .scene: return sceneDetail?.filePath
        }
    }

    private var fileSize: Int64? {
        switch mediaType {
        case .image: return imageDetail?.fileSize
        case .scene: return sceneDetail?.fileSize
        }
    }

    private var fileFormat: String? {
        switch mediaType {
        case .image: return imageDetail?.format
        case .scene: return sceneDetail?.format
        }
    }

    private var fileWidth: Int? {
        switch mediaType {
        case .image: return imageDetail?.width
        case .scene: return sceneDetail?.width
        }
    }

    private var fileHeight: Int? {
        switch mediaType {
        case .image: return imageDetail?.height
        case .scene: return sceneDetail?.height
        }
    }

    // MARK: - Data Loading

    private func loadDetail() async {
        isLoading = true
        loadError = nil

        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                imageDetail = try await client.fetchImageDetail(id: id)
                populateEditFields(from: imageDetail!)
            case .scene(let id):
                sceneDetail = try await client.fetchSceneDetail(id: id)
                populateEditFields(from: sceneDetail!)
            }
            // Baseline for unsaved-changes detection.
            originalSnapshot = currentSnapshot
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func populateEditFields(from detail: ImageDetail) {
        editTitle = detail.title ?? ""
        editCode = detail.code ?? ""
        editDate = detail.date ?? ""
        editDetails = detail.details ?? ""
        editCreator = detail.photographer ?? ""
        editRating100 = detail.rating100
        editOrganized = detail.organized
        editUrls = detail.urls
        editStudio = detail.studio
        editPerformers = detail.performers
        editTags = detail.tags
        editGalleries = detail.galleries
    }

    private func populateEditFields(from detail: SceneDetail) {
        editTitle = detail.title ?? ""
        editCode = detail.code ?? ""
        editDate = detail.date ?? ""
        editDetails = detail.details ?? ""
        editCreator = detail.director ?? ""
        editRating100 = detail.rating100
        editOrganized = detail.organized
        editUrls = detail.urls
        editStudio = detail.studio
        editPerformers = detail.performers
        editTags = detail.tags
        editGalleries = detail.galleries
    }

    // MARK: - Search

    private func searchTags(query: String) async {
        guard !query.isEmpty else { tagSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findTags(query: query, perPage: 20)
            tagSearchResults = result.tags
                .map { MediaTag(id: $0.id, name: $0.name) }
                .filter { tag in !editTags.contains(where: { $0.id == tag.id }) }
        } catch {
            tagSearchResults = []
        }
    }

    private func searchPerformers(query: String) async {
        guard !query.isEmpty else { performerSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findPerformers(query: query, perPage: 20)
            performerSearchResults = result.performers
                .map { MediaPerformer(id: $0.id, name: $0.name) }
                .filter { p in !editPerformers.contains(where: { $0.id == p.id }) }
        } catch {
            performerSearchResults = []
        }
    }

    private func searchStudios(query: String) async {
        guard !query.isEmpty else { studioSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findStudios(query: query, perPage: 20)
            studioSearchResults = result.studios
                .map { MediaStudio(id: $0.id, name: $0.name) }
        } catch {
            studioSearchResults = []
        }
    }

    // MARK: - Save

    /// Normalized snapshot of the current edit fields.
    private var currentSnapshot: EditSnapshot {
        EditSnapshot(
            title: editTitle,
            code: editCode,
            date: editDate,
            details: editDetails,
            creator: editCreator,
            rating100: editRating100,
            organized: editOrganized,
            urls: editUrls.filter { !$0.isEmpty },
            studioId: editStudio?.id,
            performerIds: editPerformers.map(\.id).sorted(),
            tagIds: editTags.map(\.id).sorted()
        )
    }

    /// Whether the edit fields differ from the last loaded/saved baseline.
    private var hasUnsavedChanges: Bool {
        guard let originalSnapshot else { return false }
        return currentSnapshot != originalSnapshot
    }

    /// Commit edits to the server. Returns true on success (or when there is
    /// nothing to save). The AppModel reference is captured by the caller while
    /// the SwiftUI environment is still valid, so this is safe to run from the
    /// sheet's dismissal path. No-op (returns true) when nothing changed.
    @discardableResult
    private func commitChanges(using model: AppModel) async -> Bool {
        guard hasUnsavedChanges else { return true }

        // Capture everything needed up front; the view may be tearing down.
        let savedRating = editRating100
        let savedSnapshot = currentSnapshot
        let notifySaved = onSaved
        let type = mediaType
        let title = editTitle.isEmpty ? nil : editTitle
        let code = editCode.isEmpty ? nil : editCode
        let date = editDate.isEmpty ? nil : editDate
        let details = editDetails.isEmpty ? nil : editDetails
        let creator = editCreator.isEmpty ? nil : editCreator
        let studioId = editStudio?.id
        let performerIds = editPerformers.map(\.id)
        let tagIds = editTags.map(\.id)
        let galleryIds = editGalleries.map(\.id)
        let urls = editUrls.filter { !$0.isEmpty }

        isSaving = true
        saveError = nil

        do {
            switch type {
            case .image(let id):
                try await model.apiClient.updateImage(
                    id: id, title: title, code: code, date: date,
                    details: details, photographer: creator, rating100: savedRating,
                    studioId: studioId, performerIds: performerIds, tagIds: tagIds,
                    galleryIds: galleryIds, urls: urls, organized: editOrganized
                )
                if let idx = model.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    model.galleryImages[idx].rating100 = savedRating
                }

            case .scene(let id):
                try await model.apiClient.updateScene(
                    id: id, title: title, code: code, date: date,
                    details: details, director: creator, rating100: savedRating,
                    studioId: studioId, performerIds: performerIds, tagIds: tagIds,
                    galleryIds: galleryIds, urls: urls, organized: editOrganized
                )
                if let idx = model.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    model.galleryVideos[idx].rating100 = savedRating
                }
            }

            isSaving = false
            originalSnapshot = savedSnapshot
            notifySaved?(savedRating)
            return true
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            return false
        }
    }

    // MARK: - O Counter

    private func incrementOCounter() async {
        isUpdatingOCounter = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                let newCount = try await client.incrementImageOCounter(imageId: id)
                imageDetail?.oCounter = newCount
                if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryImages[idx].oCounter = newCount
                }
            case .scene(let id):
                let newCount = try await client.incrementSceneOCounter(sceneId: id)
                sceneDetail?.oCounter = newCount
                if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryVideos[idx].oCounter = newCount
                }
            }
        } catch {}
        isUpdatingOCounter = false
    }

    private func decrementOCounter() async {
        isUpdatingOCounter = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                let newCount = try await client.decrementImageOCounter(imageId: id)
                imageDetail?.oCounter = newCount
                if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryImages[idx].oCounter = newCount
                }
            case .scene(let id):
                let newCount = try await client.decrementSceneOCounter(sceneId: id)
                sceneDetail?.oCounter = newCount
                if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryVideos[idx].oCounter = newCount
                }
            }
        } catch {}
        isUpdatingOCounter = false
    }

    // MARK: - Delete

    private func performDelete(deleteFile: Bool) async {
        guard MediaDeletion.isAvailable else { return }
        isDeleting = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                try await client.destroyImage(id: id, deleteFile: deleteFile)
            case .scene(let id):
                try await client.destroyScene(id: id, deleteFile: deleteFile)
            }
            onDelete?()
            dismiss()
        } catch {
            saveError = "Delete failed: \(error.localizedDescription)"
        }
        isDeleting = false
    }

    // MARK: - Formatting Helpers

    private func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        } else if bitrate >= 1_000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1_000)
        }
        return "\(bitrate) bps"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Copy-on-hold modifier

private extension View {
    /// Attaches a context menu with a "Copy" action that copies `value` to the pasteboard.
    /// On visionOS, the context menu is triggered by pinch-and-hold on the gaze-focused
    /// element, so we don't need to read tap coordinates (which drift with gaze).
    func copyOnHold(_ value: String) -> some View {
        #if os(tvOS)
        // No system pasteboard on tvOS. This whole sheet isn't part of the
        // tvOS root UI (see Hypnos/CLAUDE.md "tvOS"), so the modifier is a
        // no-op here rather than offering a Copy action with nothing to copy
        // to.
        self
        #else
        contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        #endif
    }
}

// MARK: - Flow Layout (for tag/performer chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), offsets)
    }
}
