/*
 Hypnos - Filters Tab View

 Filter and sort configuration with saved views management, for images and
 videos (scenes) alike, keyed off the last viewed content tab.

 The sections shown depend on which library is in force, because the two
 libraries answer entirely different questions. Stash knows about tags,
 performers, studios, ratings and galleries; PhotoKit knows about albums,
 favourites, media subtypes and dates, and about none of the former. Showing the
 Stash sections while browsing Photos — which is what this tab used to do
 unconditionally — offered filters that could not affect what was on screen, and
 populated their pickers by querying a server that might not even be configured.

 Saved views are shared by both: a view persists the whole criteria value, of
 which the applicable half is read. So a view saved while browsing Photos still
 carries any Stash criteria it was created alongside, and vice versa.
 */

import Photos
import SwiftUI

import RAVEUI
struct FiltersTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel
    @State private var showingSaveViewSheet = false
    @State private var newViewName = ""

    /// Whether we're filtering videos (scenes) or images
    private var isVideoFilter: Bool {
        windowModel.lastContentTab == .videos
    }

    /// Whether the photo library is what's being browsed, and so which set of
    /// filter dimensions applies.
    private var isPhotosLibrary: Bool {
        appModel.effectiveLibrarySource == .photos
    }

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                // Context indicator
                Section {
                    HStack {
                        Image(systemName: isVideoFilter ? "video" : "photo.stack")
                            .foregroundColor(.accentColor)
                        Text("Filtering \(isVideoFilter ? "Videos" : "Pictures")")
                            .font(.headline)
                        Spacer()
                        Label(appModel.effectiveLibrarySource.displayName,
                              systemImage: appModel.effectiveLibrarySource.symbolName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }

                // Saved Views Section
                Section("Saved Views") {
                    Button("Save Current Filters") {
                        newViewName = ""
                        showingSaveViewSheet = true
                    }

                    if isVideoFilter {
                        if appModel.visibleSavedVideoViews.isEmpty {
                            Text("No saved views")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(appModel.visibleSavedVideoViews) { view in
                                SavedVideoViewRow(
                                    view: view,
                                    isSelected: appModel.selectedSavedVideoView?.id == view.id,
                                    onApply: { appModel.applySavedVideoView(view) },
                                    onDeselect: { appModel.deselectVideoView() },
                                    onUpdate: { appModel.updateSavedVideoView(view, with: appModel.currentVideoFilter) },
                                    onSetDefault: { appModel.setDefaultVideoView(view) },
                                    onClearDefault: { appModel.clearDefaultVideoView() }
                                )
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    appModel.deleteSavedVideoView(appModel.visibleSavedVideoViews[index])
                                }
                            }
                        }
                    } else {
                        if appModel.visibleSavedViews.isEmpty {
                            Text("No saved views")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(appModel.visibleSavedViews) { view in
                                SavedViewRow(
                                    view: view,
                                    isSelected: appModel.selectedSavedView?.id == view.id,
                                    onApply: { appModel.applySavedView(view) },
                                    onDeselect: { appModel.deselectView() },
                                    onUpdate: { appModel.updateSavedView(view, with: appModel.currentFilter) },
                                    onSetDefault: { appModel.setDefaultView(view) },
                                    onClearDefault: { appModel.clearDefaultView() }
                                )
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    appModel.deleteSavedView(appModel.visibleSavedViews[index])
                                }
                            }
                        }
                    }
                }

                // Above the library-specific sections because it is the one
                // dimension both libraries share: "what have I converted", which
                // the app itself knows either way.
                Section {
                    Toggle("Converted to 3D Only",
                           isOn: isVideoFilter
                               ? $appModel.currentVideoFilter.showsOnlyConverted
                               : $appModel.currentFilter.showsOnlyConverted)
                } footer: {
                    Text(isVideoFilter
                         ? "Videos with a pre-processed depth track, ready to play in 3D immediately."
                         : "Photos you have previously converted to spatial 3D.")
                }

                // At tab level rather than inside the library sections, because
                // the converted flag above is shared and a Clear that left one
                // filter standing would be lying.
                if clearableFilters {
                    Section {
                        Button("Clear Filters", role: .destructive) {
                            clearFilters(appModel: appModel)
                        }
                    }
                }

                if isPhotosLibrary {
                    PhotosFilterSections(
                        criteria: isVideoFilter
                            ? $appModel.currentVideoFilter.photosCriteria
                            : $appModel.currentFilter.photosCriteria,
                        isVideoFilter: isVideoFilter
                    )
                } else {
                    stashSections(appModel: appModel)
                }
            }
            .navigationTitle(isVideoFilter ? "Video Filters" : "Picture Filters")
            .moreTabBackButton()
            .task {
                await appModel.loadAutocompleteData(isVideo: isVideoFilter)
            }
            .onDisappear {
                // Always apply the current filter when leaving the filter tab
                // This ensures any modifications (even with a saved view selected) are applied
                Task {
                    if isVideoFilter {
                        await appModel.loadInitialVideos()
                    } else {
                        await appModel.loadInitialGallery()
                    }
                }
            }
            .alert("Save View", isPresented: $showingSaveViewSheet) {
                TextField("View Name", text: $newViewName)
                Button("Save") {
                    let name = newViewName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        if isVideoFilter {
                            appModel.createSavedVideoView(name: name)
                        } else {
                            appModel.createSavedView(name: name)
                        }
                    }
                    newViewName = ""
                }
                Button("Cancel", role: .cancel) {
                    newViewName = ""
                }
            } message: {
                Text("Enter a name for the current \(isVideoFilter ? "video" : "picture") filter configuration.")
            }
        }
    }

    private var clearableFilters: Bool {
        if isPhotosLibrary {
            return isVideoFilter
                ? appModel.currentVideoFilter.hasActivePhotoLibraryFilters
                : appModel.currentFilter.hasActivePhotoLibraryFilters
        }
        return isVideoFilter
            ? appModel.currentVideoFilter.hasActiveFilters
            : appModel.currentFilter.hasActiveFilters
    }

    private func clearFilters(appModel: AppModel) {
        switch (isPhotosLibrary, isVideoFilter) {
        case (true, true):   appModel.currentVideoFilter.clearPhotoLibraryFilters()
        case (true, false):  appModel.currentFilter.clearPhotoLibraryFilters()
        case (false, true):  appModel.currentVideoFilter.clearFilters()
        case (false, false): appModel.currentFilter.clearFilters()
        }
    }

    // MARK: - Stash sections

    @ViewBuilder
    private func stashSections(appModel: AppModel) -> some View {
        @Bindable var appModel = appModel

        // Sort Section - different fields for images vs videos
        Section("Sort") {
            if isVideoFilter {
                Picker("Sort By", selection: $appModel.currentVideoFilter.sortField) {
                    ForEach(SceneSortField.allCases) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .onChange(of: appModel.currentVideoFilter.sortField) { _, newValue in
                    // Set random seed when Random is first selected to ensure consistent results
                    // until user explicitly presses Shuffle
                    if newValue == .random && appModel.currentVideoFilter.randomSeed == nil {
                        appModel.currentVideoFilter.shuffleRandomSort()
                    }
                }

                Picker("Direction", selection: $appModel.currentVideoFilter.sortDirection) {
                    ForEach(SortDirection.allCases) { direction in
                        Label(direction.displayName, systemImage: direction.icon)
                            .tag(direction)
                    }
                }

                // Shuffle button for random sort
                if appModel.currentVideoFilter.sortField == .random {
                    Button {
                        appModel.currentVideoFilter.shuffleRandomSort()
                    } label: {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Shuffle")
                        }
                    }
                }
            } else {
                Picker("Sort By", selection: $appModel.currentFilter.sortField) {
                    ForEach(ImageSortField.allCases) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .onChange(of: appModel.currentFilter.sortField) { _, newValue in
                    // Set random seed when Random is first selected to ensure consistent results
                    // until user explicitly presses Shuffle
                    if newValue == .random && appModel.currentFilter.randomSeed == nil {
                        appModel.currentFilter.shuffleRandomSort()
                    }
                }

                Picker("Direction", selection: $appModel.currentFilter.sortDirection) {
                    ForEach(SortDirection.allCases) { direction in
                        Label(direction.displayName, systemImage: direction.icon)
                            .tag(direction)
                    }
                }

                // Shuffle button for random sort
                if appModel.currentFilter.sortField == .random {
                    Button {
                        appModel.currentFilter.shuffleRandomSort()
                    } label: {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Shuffle")
                        }
                    }
                }
            }
        }

        // Search Section
        Section("Search") {
            if isVideoFilter {
                TextField("Search titles...", text: $appModel.currentVideoFilter.searchTerm)
                    .textFieldTapTarget()
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            } else {
                TextField("Search titles...", text: $appModel.currentFilter.searchTerm)
                    .textFieldTapTarget()
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
        }

        // Galleries hold images and groups hold scenes, so each tab gets the
        // one that applies rather than both showing a dimension that cannot
        // match anything.
        if isVideoFilter {
            MediaMultiSelectSection(
                title: "Groups",
                footer: "Stash groups collect scenes, the way galleries collect images.",
                emptyMessage: "This server has no groups.",
                options: appModel.availableGroups.map(\.filterOption),
                selection: $appModel.currentVideoFilter.selectedGroups,
                modifier: $appModel.currentVideoFilter.groupModifier
            )
        } else {
            Section("Galleries") {
                GalleryFilterView(isVideoFilter: isVideoFilter)
            }
        }

        Section("Tags") {
            TagFilterView(isVideoFilter: isVideoFilter)
        }

        Section("Studios") {
            StudioFilterView(isVideoFilter: isVideoFilter)
        }

        Section("Performers") {
            PerformerFilterView(isVideoFilter: isVideoFilter)
        }

        Section("Activity") {
            OCountFilterView(isVideoFilter: isVideoFilter)
        }

        Section("Rating") {
            RatingFilterView(isVideoFilter: isVideoFilter)
        }
    }
}

// MARK: - Photos Filter Sections

/// The filter dimensions the photo index can answer.
///
/// Half of these have no expression in PhotoKit at any cost — filename is not a
/// `PHFetchOptions` predicate key, `fetchAssets(in:)` takes one collection, and
/// there is no random sort descriptor. They exist because the library is
/// mirrored locally; see `PhotosIndexQuery`.
struct PhotosFilterSections: View {
    @Environment(AppModel.self) private var appModel
    @Binding var criteria: PhotosFilterCriteria
    let isVideoFilter: Bool

    private var indexer: PhotosLibraryIndexer { PhotosLibraryIndexer.shared }
    private var mediaType: PHAssetMediaType { isVideoFilter ? .video : .image }
    private var noun: String { isVideoFilter ? "videos" : "photos" }

    private var albumOptions: [FilterOption] {
        appModel.availablePhotoAlbums.map { album in
            FilterOption(id: album.id,
                         name: album.name,
                         detail: "\(album.count)",
                         thumbnailURL: album.keyAssetId.flatMap(PhotosAssetURL.url(forLocalIdentifier:)),
                         isSecondary: album.isSmart)
        }
    }

    private var peopleOptions: [FilterOption] {
        appModel.availablePhotoPeople.map { person in
            FilterOption(id: person.id,
                         name: person.name,
                         detail: "\(person.count)",
                         thumbnailURL: person.keyAssetId.flatMap(PhotosAssetURL.url(forLocalIdentifier:)))
        }
    }

    var body: some View {
        Section {
            TextField("Search file names...", text: $criteria.searchTerm)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        } header: {
            Text("Search")
        } footer: {
            // While the name pass is still running, search genuinely covers only
            // part of the library. Saying so beats letting it look like the
            // search is broken.
            if case .naming(let done, let total) = indexer.phase {
                Text("Reading file names from your library — \(done) of \(total) so far. Search covers the names read to this point.")
            } else {
                Text("Matches anywhere in the file name.")
            }
        }

        Section("Sort") {
            Picker("Sort By", selection: $criteria.sortField) {
                ForEach(PhotosSortField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .onChange(of: criteria.sortField) { _, newValue in
                // Seed the shuffle on first selection so pagination agrees with
                // itself until the user explicitly reshuffles.
                if newValue == .random && criteria.randomSeed == nil {
                    criteria.shuffleRandomSort()
                }
            }

            if criteria.sortField.isDirectional {
                Picker("Direction", selection: $criteria.sortDirection) {
                    ForEach(SortDirection.allCases) { direction in
                        Label(direction.displayName, systemImage: direction.icon)
                            .tag(direction)
                    }
                }
            }

            if criteria.sortField == .random {
                Button {
                    criteria.shuffleRandomSort()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }

            if criteria.sortField == .albumOrder && criteria.selectedAlbums.count != 1 {
                Text("An album's manual order only exists relative to one album. With none or several selected this follows the library's order instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        MediaMultiSelectSection(
            title: "Albums",
            footer: "Your own albums first, then the system's smart albums. Counts are for \(noun) only.",
            emptyMessage: "No albums contain \(noun).",
            options: albumOptions,
            isLoading: appModel.isLoadingPhotoAlbums,
            selection: $criteria.selectedAlbums,
            modifier: $criteria.albumModifier
        )

        // Hidden entirely rather than shown empty: PhotoKit exposes no people at
        // all, so until a face source exists this dimension has nothing to offer
        // and an empty section would read as a bug.
        if !peopleOptions.isEmpty {
            MediaMultiSelectSection(
                title: "People",
                footer: "Defaults to \"All of\", so picking two people finds \(noun) with both in them.",
                options: peopleOptions,
                selection: $criteria.selectedPeople,
                modifier: $criteria.personModifier
            )
        }

        Section("Kind") {
            Picker("Kind", selection: $criteria.kind) {
                ForEach(PhotosMediaKind.options(for: mediaType)) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        }

        Section("Favorites") {
            Toggle("Favorites Only", isOn: $criteria.favoritesOnly)
        }

        Section("Date") {
            Toggle("Filter by Date", isOn: $criteria.dateRangeEnabled)
                .onChange(of: criteria.dateRangeEnabled) { _, enabled in
                    // Seed a usable range on first enable, so the pickers do not
                    // open on a range that matches everything or nothing.
                    guard enabled else { return }
                    if criteria.startDate == nil {
                        criteria.startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())
                    }
                    if criteria.endDate == nil {
                        criteria.endDate = Self.endOfDay(for: Date())
                    }
                }

            // `DatePicker` doesn't exist on tvOS, and Filters isn't one of the
            // tabs the tvOS root UI offers in the first place (see
            // Hypnos/CLAUDE.md "tvOS") — this whole view is dead code there.
            #if !os(tvOS)
            if criteria.dateRangeEnabled {
                DatePicker("From", selection: startBinding, displayedComponents: .date)
                DatePicker("To", selection: endBinding, displayedComponents: .date)
            }
            #endif
        }

        Section {
            Button("Rebuild Library Index") {
                indexer.rebuild()
            }
        } footer: {
            Text(indexer.progressDescription
                 ?? "Rebuild if your library and what's shown here have drifted apart.")
        }
    }

    // MARK: - Date bindings

    private var startBinding: Binding<Date> {
        Binding(
            get: { criteria.startDate ?? Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date() },
            set: { criteria.startDate = Calendar.current.startOfDay(for: $0) }
        )
    }

    /// Writes the *end* of the chosen day. A date picker yields midnight, and
    /// comparing `creationDate <= midnight` would exclude everything shot on the
    /// day the user just asked to include.
    private var endBinding: Binding<Date> {
        Binding(
            get: { criteria.endDate ?? Self.endOfDay(for: Date()) },
            set: { criteria.endDate = Self.endOfDay(for: $0) }
        )
    }

    private static func endOfDay(for date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}

// MARK: - Saved View Row

struct SavedViewRow: View {
    let view: SavedView
    let isSelected: Bool
    let onApply: () -> Void
    let onDeselect: () -> Void
    let onUpdate: () -> Void
    let onSetDefault: () -> Void
    let onClearDefault: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(view.name)
                    if view.isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                Text(filterSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(view.isDefault ? "Unset Default" : "Set Default") {
                if view.isDefault {
                    onClearDefault()
                } else {
                    onSetDefault()
                }
            }
            .buttonStyle(.borderless)
            Button("Update") {
                onUpdate()
            }
            .buttonStyle(.borderless)
            Button(isSelected ? "Deselect" : "Apply") {
                if isSelected {
                    onDeselect()
                } else {
                    onApply()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !view.filter.searchTerm.isEmpty {
            parts.append("Search: \(view.filter.searchTerm)")
        }
        if !view.filter.selectedTags.isEmpty {
            parts.append("\(view.filter.selectedTags.count) tags")
        }
        if !view.filter.selectedStudios.isEmpty {
            parts.append("\(view.filter.selectedStudios.count) studios")
        }
        if !view.filter.selectedPerformers.isEmpty {
            parts.append("\(view.filter.selectedPerformers.count) performers")
        }
        if !view.filter.selectedGalleries.isEmpty {
            parts.append("\(view.filter.selectedGalleries.count) galleries")
        }
        if view.filter.ratingEnabled {
            parts.append("Rating filter")
        }
        if view.filter.oCountEnabled {
            parts.append("Activity filter")
        }
        parts.append("\(view.filter.sortField.displayName) \(view.filter.sortDirection.displayName)")
        return parts.joined(separator: " | ")
    }
}

// MARK: - Saved Video View Row

struct SavedVideoViewRow: View {
    let view: SavedVideoView
    let isSelected: Bool
    let onApply: () -> Void
    let onDeselect: () -> Void
    let onUpdate: () -> Void
    let onSetDefault: () -> Void
    let onClearDefault: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(view.name)
                    if view.isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                Text(filterSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(view.isDefault ? "Unset Default" : "Set Default") {
                if view.isDefault {
                    onClearDefault()
                } else {
                    onSetDefault()
                }
            }
            .buttonStyle(.borderless)
            Button("Update") {
                onUpdate()
            }
            .buttonStyle(.borderless)
            Button(isSelected ? "Deselect" : "Apply") {
                if isSelected {
                    onDeselect()
                } else {
                    onApply()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !view.filter.searchTerm.isEmpty {
            parts.append("Search: \(view.filter.searchTerm)")
        }
        if !view.filter.selectedTags.isEmpty {
            parts.append("\(view.filter.selectedTags.count) tags")
        }
        if !view.filter.selectedStudios.isEmpty {
            parts.append("\(view.filter.selectedStudios.count) studios")
        }
        if !view.filter.selectedPerformers.isEmpty {
            parts.append("\(view.filter.selectedPerformers.count) performers")
        }
        if !view.filter.selectedGalleries.isEmpty {
            parts.append("\(view.filter.selectedGalleries.count) galleries")
        }
        if view.filter.ratingEnabled {
            parts.append("Rating filter")
        }
        if view.filter.oCountEnabled {
            parts.append("Activity filter")
        }
        parts.append("\(view.filter.sortField.displayName) \(view.filter.sortDirection.displayName)")
        return parts.joined(separator: " | ")
    }
}

// MARK: - Gallery Filter View

struct GalleryFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    let isVideoFilter: Bool

    private var selectedGalleries: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedGalleries : appModel.currentFilter.selectedGalleries
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.galleryModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Match", selection: $appModel.currentFilter.galleryModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            }

            // Search field
            TextField("Search galleries...", text: $searchText)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchGalleries(query: newValue)
                    }
                }

            // Selected galleries
            if !selectedGalleries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedGalleries) { gallery in
                            SelectedItemChip(name: gallery.name) {
                                if isVideoFilter {
                                    appModel.currentVideoFilter.selectedGalleries.removeAll { $0.id == gallery.id }
                                } else {
                                    appModel.currentFilter.selectedGalleries.removeAll { $0.id == gallery.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available galleries
            if appModel.isLoadingGalleries {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedGalleries.map { $0.id })
                let availableToSelect = appModel.availableGalleries.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { gallery in
                                Button {
                                    if isVideoFilter {
                                        appModel.currentVideoFilter.selectedGalleries.append(gallery)
                                    } else {
                                        appModel.currentFilter.selectedGalleries.append(gallery)
                                    }
                                } label: {
                                    Text(gallery.name)
                                        .font(.body)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tag Filter View

struct TagFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    let isVideoFilter: Bool

    private var selectedTags: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedTags : appModel.currentFilter.selectedTags
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.tagModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Match", selection: $appModel.currentFilter.tagModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            }

            // Search field
            TextField("Search tags...", text: $searchText)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchTags(query: newValue)
                    }
                }

            // Selected tags
            if !selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedTags) { tag in
                            SelectedItemChip(name: tag.name) {
                                if isVideoFilter {
                                    appModel.currentVideoFilter.selectedTags.removeAll { $0.id == tag.id }
                                } else {
                                    appModel.currentFilter.selectedTags.removeAll { $0.id == tag.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available tags
            if appModel.isLoadingTags {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedTags.map { $0.id })
                let availableToSelect = appModel.availableTags.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { tag in
                                Button {
                                    if isVideoFilter {
                                        appModel.currentVideoFilter.selectedTags.append(tag)
                                    } else {
                                        appModel.currentFilter.selectedTags.append(tag)
                                    }
                                } label: {
                                    Text(tag.name)
                                        .font(.body)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Studio Filter View

struct StudioFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    let isVideoFilter: Bool

    private var selectedStudios: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedStudios : appModel.currentFilter.selectedStudios
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.studioModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Match", selection: $appModel.currentFilter.studioModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            }

            // Search field
            TextField("Search studios...", text: $searchText)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchStudios(query: newValue)
                    }
                }

            // Selected studios
            if !selectedStudios.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedStudios) { studio in
                            SelectedItemChip(name: studio.name) {
                                if isVideoFilter {
                                    appModel.currentVideoFilter.selectedStudios.removeAll { $0.id == studio.id }
                                } else {
                                    appModel.currentFilter.selectedStudios.removeAll { $0.id == studio.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available studios
            if appModel.isLoadingStudios {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedStudios.map { $0.id })
                let availableToSelect = appModel.availableStudios.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { studio in
                                Button {
                                    if isVideoFilter {
                                        appModel.currentVideoFilter.selectedStudios.append(studio)
                                    } else {
                                        appModel.currentFilter.selectedStudios.append(studio)
                                    }
                                } label: {
                                    Text(studio.name)
                                        .font(.body)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Performer Filter View

struct PerformerFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    let isVideoFilter: Bool

    private var selectedPerformers: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedPerformers : appModel.currentFilter.selectedPerformers
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.performerModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Match", selection: $appModel.currentFilter.performerModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            }

            // Search field
            TextField("Search performers...", text: $searchText)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchPerformers(query: newValue)
                    }
                }

            // Selected performers
            if !selectedPerformers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedPerformers) { performer in
                            SelectedItemChip(name: performer.name) {
                                if isVideoFilter {
                                    appModel.currentVideoFilter.selectedPerformers.removeAll { $0.id == performer.id }
                                } else {
                                    appModel.currentFilter.selectedPerformers.removeAll { $0.id == performer.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available performers
            if appModel.isLoadingPerformers {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedPerformers.map { $0.id })
                let availableToSelect = appModel.availablePerformers.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { performer in
                                Button {
                                    if isVideoFilter {
                                        appModel.currentVideoFilter.selectedPerformers.append(performer)
                                    } else {
                                        appModel.currentFilter.selectedPerformers.append(performer)
                                    }
                                } label: {
                                    Text(performer.name)
                                        .font(.body)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Selected Item Chip

struct SelectedItemChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.body)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(12)
    }
}

// MARK: - O Count Filter View

struct OCountFilterView: View {
    @Environment(AppModel.self) private var appModel
    let isVideoFilter: Bool

    private var oCountEnabled: Bool {
        isVideoFilter ? appModel.currentVideoFilter.oCountEnabled : appModel.currentFilter.oCountEnabled
    }

    private var oCountModifier: CriterionModifier {
        isVideoFilter ? appModel.currentVideoFilter.oCountModifier : appModel.currentFilter.oCountModifier
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            if isVideoFilter {
                Toggle("Enable Filter", isOn: $appModel.currentVideoFilter.oCountEnabled)
            } else {
                Toggle("Enable Filter", isOn: $appModel.currentFilter.oCountEnabled)
            }

            if oCountEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if isVideoFilter {
                        Picker("Condition", selection: $appModel.currentVideoFilter.oCountModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("Condition", selection: $appModel.currentFilter.oCountModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if oCountModifier.requiresRange {
                    HStack {
                        if isVideoFilter {
                            TextField("Min", value: $appModel.currentVideoFilter.oCountRange.min, format: .number)
                                .textFieldTapTarget()
                                .roundedTextFieldStyle()
                                .frame(width: 80)
                            Text("to")
                            TextField("Max", value: $appModel.currentVideoFilter.oCountRange.max, format: .number)
                                .textFieldTapTarget()
                                .roundedTextFieldStyle()
                                .frame(width: 80)
                        } else {
                            TextField("Min", value: $appModel.currentFilter.oCountRange.min, format: .number)
                                .textFieldTapTarget()
                                .roundedTextFieldStyle()
                                .frame(width: 80)
                            Text("to")
                            TextField("Max", value: $appModel.currentFilter.oCountRange.max, format: .number)
                                .textFieldTapTarget()
                                .roundedTextFieldStyle()
                                .frame(width: 80)
                        }
                    }
                } else if oCountModifier.requiresValue {
                    if isVideoFilter {
                        TextField("Value", value: $appModel.currentVideoFilter.oCountValue, format: .number)
                            .textFieldTapTarget()
                            .roundedTextFieldStyle()
                            .frame(width: 100)
                    } else {
                        TextField("Value", value: $appModel.currentFilter.oCountValue, format: .number)
                            .textFieldTapTarget()
                            .roundedTextFieldStyle()
                            .frame(width: 100)
                    }
                }
            }
        }
    }
}

// MARK: - Rating Filter View

struct RatingFilterView: View {
    @Environment(AppModel.self) private var appModel
    let isVideoFilter: Bool

    private var ratingEnabled: Bool {
        isVideoFilter ? appModel.currentVideoFilter.ratingEnabled : appModel.currentFilter.ratingEnabled
    }

    private var ratingModifier: CriterionModifier {
        isVideoFilter ? appModel.currentVideoFilter.ratingModifier : appModel.currentFilter.ratingModifier
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            if isVideoFilter {
                Toggle("Enable Filter", isOn: $appModel.currentVideoFilter.ratingEnabled)
            } else {
                Toggle("Enable Filter", isOn: $appModel.currentFilter.ratingEnabled)
            }

            if ratingEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if isVideoFilter {
                        Picker("Condition", selection: $appModel.currentVideoFilter.ratingModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("Condition", selection: $appModel.currentFilter.ratingModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if ratingModifier.requiresRange {
                    if isVideoFilter {
                        HStack {
                            Text("Min:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingRange.min ?? 1 },
                                set: { appModel.currentVideoFilter.ratingRange.min = $0 }
                            ))
                        }
                        HStack {
                            Text("Max:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingRange.max ?? 5 },
                                set: { appModel.currentVideoFilter.ratingRange.max = $0 }
                            ))
                        }
                    } else {
                        HStack {
                            Text("Min:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingRange.min ?? 1 },
                                set: { appModel.currentFilter.ratingRange.min = $0 }
                            ))
                        }
                        HStack {
                            Text("Max:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingRange.max ?? 5 },
                                set: { appModel.currentFilter.ratingRange.max = $0 }
                            ))
                        }
                    }
                } else if ratingModifier.requiresValue {
                    if isVideoFilter {
                        HStack {
                            Text("Rating:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingValue ?? 3 },
                                set: { appModel.currentVideoFilter.ratingValue = $0 }
                            ))
                        }
                    } else {
                        HStack {
                            Text("Rating:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingValue ?? 3 },
                                set: { appModel.currentFilter.ratingValue = $0 }
                            ))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Star Rating Picker

struct StarRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundColor(star <= rating ? .yellow : .gray)
                    .onTapGesture {
                        rating = star
                    }
            }
        }
    }
}
