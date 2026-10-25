/*
 Hypnos - tvOS Filters tab

 What `FiltersTabView` offers for the library in force, built the way the
 tvOS Settings tab is (`TVSettingsView`): a short page of rows that show
 their current value, each opening a page of its own. It edits the same
 state the other platforms' Filters tab does — `AppModel.currentFilter` /
 `currentVideoFilter` and the saved views — so nothing here is a second
 filter model, only a remote-shaped way to set it:

 - choices are full-width checkmarked rows, never a `Picker` (a picker
   pushed from inside the tab bar stalls on a blank page on tvOS, see
   "Root UI" in `hypnos-tvos-port.md`), and a row holds one action;
 - `Slider`, `DatePicker` and `Stepper` don't exist on tvOS: a rating is a
   row per star count, the Photos date range a row per span ("Last 30
   Days"), counts a number field;
 - multi-select dimensions (tags, studios, performers, galleries, groups,
   albums, people) are one list each, selected values first, Select to
   toggle, with the match rule (all of / any of / none of) above it.

 Changes apply when the tab is left (`TVRootView` reloads whichever grid's
 filter changed), as leaving the Filters tab does elsewhere; a saved view
 applies at once.
 */

#if os(tvOS)

import Photos
import SwiftUI

// MARK: - Shared shape of the two Stash criteria

/// A choice with a name: the sort fields, kinds and operators the rows list.
protocol TVNamedChoice: Hashable {
    var displayName: String { get }
}

extension ImageSortField: TVNamedChoice {}
extension SceneSortField: TVNamedChoice {}
extension PhotosSortField: TVNamedChoice {}
extension PhotosMediaKind: TVNamedChoice {}
extension SortDirection: TVNamedChoice {}
extension CriterionModifier: TVNamedChoice {}

/// The fields picture and video criteria have in common, so one editor
/// serves both (`ImageFilterCriteria`, `SceneFilterCriteria`).
protocol TVFilterCriteria: Equatable {
    associatedtype SortField: TVNamedChoice & CaseIterable where SortField.AllCases: RandomAccessCollection
    var searchTerm: String { get set }
    var selectedTags: [AutocompleteItem] { get set }
    var tagModifier: CriterionModifier { get set }
    var selectedStudios: [AutocompleteItem] { get set }
    var studioModifier: CriterionModifier { get set }
    var selectedPerformers: [AutocompleteItem] { get set }
    var performerModifier: CriterionModifier { get set }
    var ratingEnabled: Bool { get set }
    var ratingModifier: CriterionModifier { get set }
    var ratingValue: Int? { get set }
    var ratingRange: NumberRange { get set }
    var oCountEnabled: Bool { get set }
    var oCountModifier: CriterionModifier { get set }
    var oCountValue: Int? { get set }
    var oCountRange: NumberRange { get set }
    var sortField: SortField { get set }
    var sortDirection: SortDirection { get set }
    var randomSeed: Int? { get set }
    var photosCriteria: PhotosFilterCriteria { get set }
    /// Sorted by Random, which takes a seed so pages agree.
    var sortsRandomly: Bool { get }
    var hasActiveFilters: Bool { get }
    var hasActivePhotoLibraryFilters: Bool { get }
    mutating func clearFilters()
    mutating func clearPhotoLibraryFilters()
    mutating func shuffleRandomSort()
}

extension ImageFilterCriteria: TVFilterCriteria {
    var sortsRandomly: Bool { sortField == .random }
}

extension SceneFilterCriteria: TVFilterCriteria {
    var sortsRandomly: Bool { sortField == .random }
}

/// A page the Filters tab pushes.
enum TVFilterPage: Hashable {
    case savedViews
    case sort
    case dimension(TVFilterDimension)
    case rating
    case activity
    case photosSort
    case photosKind
    case photosDate
}

/// One multi-select filter dimension.
enum TVFilterDimension: String, Hashable {
    case galleries, groups, tags, studios, performers, albums, people

    var title: String {
        switch self {
        case .galleries: "Galleries"
        case .groups: "Groups"
        case .tags: "Tags"
        case .studios: "Studios"
        case .performers: "Performers"
        case .albums: "Albums"
        case .people: "People"
        }
    }

    /// Stash dimensions search the server as you type; the photo index's
    /// lists are complete already.
    var searchesServer: Bool {
        switch self {
        case .galleries, .tags, .studios, .performers: true
        case .groups, .albums, .people: false
        }
    }
}

// MARK: - Tab

struct TVFiltersTabView: View {
    @Environment(AppModel.self) private var appModel
    /// Which grid's filter is edited; starts on the last one browsed.
    @State private var isVideo: Bool

    init(startsWithVideos: Bool) {
        _isVideo = State(initialValue: startsWithVideos)
    }

    private var isPhotos: Bool { appModel.effectiveLibrarySource == .photos }

    var body: some View {
        NavigationStack {
            Group {
                if isVideo {
                    TVFilterEditor(criteria: Bindable(appModel).currentVideoFilter, isVideo: true)
                } else {
                    TVFilterEditor(criteria: Bindable(appModel).currentFilter, isVideo: false)
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Filtering", selection: $isVideo) {
                    Text("Pictures").tag(false)
                    Text("Videos").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
            }
        }
        .task(id: isVideo) {
            await appModel.loadAutocompleteData(isVideo: isVideo)
        }
    }
}

/// The page of rows for one kind's criteria, and the pages they open.
private struct TVFilterEditor<Criteria: TVFilterCriteria>: View {
    @Environment(AppModel.self) private var appModel
    @Binding var criteria: Criteria
    let isVideo: Bool

    private var isPhotos: Bool { appModel.effectiveLibrarySource == .photos }

    var body: some View {
        List {
            Section {
                NavigationLink(value: TVFilterPage.savedViews) {
                    TVFilterValueRow(title: "Saved Views", value: selectedViewName ?? "None")
                }
            }
            Section("Search") {
                if isPhotos {
                    TextField("Search file names", text: $criteria.photosCriteria.searchTerm)
                } else {
                    TextField("Search titles", text: $criteria.searchTerm)
                }
            }
            if isPhotos {
                photosRows
            } else {
                stashRows
            }
            if isPhotos ? criteria.hasActivePhotoLibraryFilters : criteria.hasActiveFilters {
                Section {
                    Button("Clear Filters", role: .destructive) {
                        if isPhotos { criteria.clearPhotoLibraryFilters() } else { criteria.clearFilters() }
                    }
                }
            }
        }
        .navigationDestination(for: TVFilterPage.self) { page in
            pageView(page)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var stashRows: some View {
        Section("Sort") {
            NavigationLink(value: TVFilterPage.sort) {
                TVFilterValueRow(title: "Sort By",
                                 value: "\(criteria.sortField.displayName), \(criteria.sortDirection.displayName)")
            }
        }
        Section("Filters") {
            if isVideo {
                dimensionRow(.groups, selected: (criteria as? SceneFilterCriteria)?.selectedGroups ?? [])
            } else {
                dimensionRow(.galleries, selected: (criteria as? ImageFilterCriteria)?.selectedGalleries ?? [])
            }
            dimensionRow(.tags, selected: criteria.selectedTags)
            dimensionRow(.studios, selected: criteria.selectedStudios)
            dimensionRow(.performers, selected: criteria.selectedPerformers)
            NavigationLink(value: TVFilterPage.rating) {
                TVFilterValueRow(title: "Rating", value: criteria.ratingEnabled ? ratingSummary : "Any")
            }
            NavigationLink(value: TVFilterPage.activity) {
                TVFilterValueRow(title: "Activity", value: criteria.oCountEnabled ? activitySummary : "Any")
            }
        }
    }

    @ViewBuilder
    private var photosRows: some View {
        let photos = criteria.photosCriteria
        Section("Sort") {
            NavigationLink(value: TVFilterPage.photosSort) {
                TVFilterValueRow(title: "Sort By", value: photos.sortField.isDirectional
                    ? "\(photos.sortField.displayName), \(photos.sortDirection.displayName)"
                    : photos.sortField.displayName)
            }
        }
        Section("Filters") {
            dimensionRow(.albums, selected: photos.selectedAlbums)
            if !appModel.availablePhotoPeople.isEmpty {
                dimensionRow(.people, selected: photos.selectedPeople)
            }
            NavigationLink(value: TVFilterPage.photosKind) {
                TVFilterValueRow(title: "Kind", value: photos.kind.displayName)
            }
            Toggle("Favorites Only", isOn: $criteria.photosCriteria.favoritesOnly)
            NavigationLink(value: TVFilterPage.photosDate) {
                TVFilterValueRow(title: "Date", value: TVPhotosDateSpan.summary(of: photos))
            }
        }
    }

    private func dimensionRow(_ dimension: TVFilterDimension, selected: [AutocompleteItem]) -> some View {
        NavigationLink(value: TVFilterPage.dimension(dimension)) {
            TVFilterValueRow(title: dimension.title, value: Self.summary(selected))
        }
    }

    private static func summary(_ items: [AutocompleteItem]) -> String {
        switch items.count {
        case 0: "Any"
        case 1: items[0].name
        default: "\(items[0].name) and \(items.count - 1) more"
        }
    }

    private var selectedViewName: String? {
        isVideo ? appModel.selectedSavedVideoView?.name : appModel.selectedSavedView?.name
    }

    private var ratingSummary: String {
        let modifier = criteria.ratingModifier
        if modifier.requiresRange {
            return "\(modifier.displayName) \(criteria.ratingRange.min ?? 1)-\(criteria.ratingRange.max ?? 5) ★"
        }
        if modifier.requiresValue { return "\(modifier.displayName) \(criteria.ratingValue ?? 3) ★" }
        return modifier.displayName
    }

    private var activitySummary: String {
        let modifier = criteria.oCountModifier
        if modifier.requiresRange {
            return "\(modifier.displayName) \(criteria.oCountRange.min ?? 0)-\(criteria.oCountRange.max ?? 0)"
        }
        if modifier.requiresValue { return "\(modifier.displayName) \(criteria.oCountValue ?? 0)" }
        return modifier.displayName
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ page: TVFilterPage) -> some View {
        switch page {
        case .savedViews:
            TVSavedViewsPage(isVideo: isVideo)
        case .sort:
            List {
                TVChoiceSection(title: "Sort By", choices: Array(Criteria.SortField.allCases),
                                selection: $criteria.sortField)
                TVChoiceSection(title: "Direction", choices: SortDirection.allCases, selection: $criteria.sortDirection)
                if criteria.sortsRandomly {
                    Section {
                        Button("Shuffle", systemImage: "shuffle") { criteria.shuffleRandomSort() }
                    }
                }
            }
            .onChange(of: criteria.sortField) { _, _ in
                // A seed on first pick, so pages agree with each other until
                // the viewer shuffles.
                if criteria.sortsRandomly, criteria.randomSeed == nil { criteria.shuffleRandomSort() }
            }
        case .dimension(let dimension):
            TVFilterDimensionPage(dimension: dimension, isVideo: isVideo,
                                  selection: selectionBinding(dimension), modifier: modifierBinding(dimension))
        case .rating:
            TVNumberCriterionPage(title: "Rating", enabled: $criteria.ratingEnabled,
                                  modifier: $criteria.ratingModifier, value: $criteria.ratingValue,
                                  range: $criteria.ratingRange, stars: true)
        case .activity:
            TVNumberCriterionPage(title: "Activity", enabled: $criteria.oCountEnabled,
                                  modifier: $criteria.oCountModifier, value: $criteria.oCountValue,
                                  range: $criteria.oCountRange, stars: false)
        case .photosSort:
            List {
                TVChoiceSection(title: "Sort By", choices: PhotosSortField.allCases,
                                selection: $criteria.photosCriteria.sortField)
                if criteria.photosCriteria.sortField.isDirectional {
                    TVChoiceSection(title: "Direction", choices: SortDirection.allCases,
                                    selection: $criteria.photosCriteria.sortDirection)
                }
                if criteria.photosCriteria.sortField == .random {
                    Section {
                        Button("Shuffle", systemImage: "shuffle") { criteria.photosCriteria.shuffleRandomSort() }
                    }
                }
            }
            .onChange(of: criteria.photosCriteria.sortField) { _, field in
                if field == .random, criteria.photosCriteria.randomSeed == nil {
                    criteria.photosCriteria.shuffleRandomSort()
                }
            }
        case .photosKind:
            List {
                TVChoiceSection(title: "Kind", choices: PhotosMediaKind.options(for: isVideo ? .video : .image),
                                selection: $criteria.photosCriteria.kind)
            }
        case .photosDate:
            TVPhotosDatePage(criteria: $criteria.photosCriteria)
        }
    }

    private func selectionBinding(_ dimension: TVFilterDimension) -> Binding<[AutocompleteItem]> {
        switch dimension {
        case .tags: $criteria.selectedTags
        case .studios: $criteria.selectedStudios
        case .performers: $criteria.selectedPerformers
        case .albums: $criteria.photosCriteria.selectedAlbums
        case .people: $criteria.photosCriteria.selectedPeople
        case .galleries:
            Binding(get: { appModel.currentFilter.selectedGalleries },
                    set: { appModel.currentFilter.selectedGalleries = $0 })
        case .groups:
            Binding(get: { appModel.currentVideoFilter.selectedGroups },
                    set: { appModel.currentVideoFilter.selectedGroups = $0 })
        }
    }

    private func modifierBinding(_ dimension: TVFilterDimension) -> Binding<CriterionModifier> {
        switch dimension {
        case .tags: $criteria.tagModifier
        case .studios: $criteria.studioModifier
        case .performers: $criteria.performerModifier
        case .albums: $criteria.photosCriteria.albumModifier
        case .people: $criteria.photosCriteria.personModifier
        case .galleries:
            Binding(get: { appModel.currentFilter.galleryModifier },
                    set: { appModel.currentFilter.galleryModifier = $0 })
        case .groups:
            Binding(get: { appModel.currentVideoFilter.groupModifier },
                    set: { appModel.currentVideoFilter.groupModifier = $0 })
        }
    }
}

// MARK: - Rows

/// A row naming a setting and showing its value, which opens its page.
private struct TVFilterValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 24)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// One choice of several, as checkmarked rows.
private struct TVChoiceSection<Choice: TVNamedChoice>: View {
    let title: String
    let choices: [Choice]
    @Binding var selection: Choice

    /// The operators' names are lowercase for use mid-sentence elsewhere.
    static func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    var body: some View {
        Section(title) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    selection = choice
                } label: {
                    TVCheckRow(title: Self.capitalized(choice.displayName), isChecked: choice == selection)
                }
            }
        }
    }
}

private struct TVCheckRow: View {
    let title: String
    var detail: String?
    let isChecked: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 24)
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Image(systemName: "checkmark")
                .opacity(isChecked ? 1 : 0)
                .accessibilityHidden(!isChecked)
        }
    }
}

// MARK: - Pages

/// Saved views: Select applies (or, on the applied one, clears) a view;
/// holding Select offers Update, Default and Delete.
private struct TVSavedViewsPage: View {
    @Environment(AppModel.self) private var appModel
    let isVideo: Bool
    @State private var savingView = false
    @State private var newViewName = ""

    var body: some View {
        List {
            Section {
                Button("Save Current Filters…", systemImage: "plus") {
                    newViewName = ""
                    savingView = true
                }
            }
            Section {
                if isVideo {
                    if appModel.visibleSavedVideoViews.isEmpty { emptyRow }
                    ForEach(appModel.visibleSavedVideoViews) { view in
                        row(name: view.name, isDefault: view.isDefault,
                            isSelected: appModel.selectedSavedVideoView?.id == view.id,
                            apply: { appModel.applySavedVideoView(view) },
                            deselect: { appModel.deselectVideoView() },
                            update: { appModel.updateSavedVideoView(view, with: appModel.currentVideoFilter) },
                            toggleDefault: {
                                view.isDefault ? appModel.clearDefaultVideoView() : appModel.setDefaultVideoView(view)
                            },
                            delete: { appModel.deleteSavedVideoView(view) })
                    }
                } else {
                    if appModel.visibleSavedViews.isEmpty { emptyRow }
                    ForEach(appModel.visibleSavedViews) { view in
                        row(name: view.name, isDefault: view.isDefault,
                            isSelected: appModel.selectedSavedView?.id == view.id,
                            apply: { appModel.applySavedView(view) },
                            deselect: { appModel.deselectView() },
                            update: { appModel.updateSavedView(view, with: appModel.currentFilter) },
                            toggleDefault: {
                                view.isDefault ? appModel.clearDefaultView() : appModel.setDefaultView(view)
                            },
                            delete: { appModel.deleteSavedView(view) })
                    }
                }
            } footer: {
                Text("Select a view to apply it, and the applied one to clear it. Hold Select for more.")
            }
        }
        // Here rather than on the Filters page: an alert attached to a page
        // covered by this one never shows.
        .alert("Save View", isPresented: $savingView) {
            TextField("View Name", text: $newViewName)
            Button("Save", action: save)
            Button("Cancel", role: .cancel) { newViewName = "" }
        } message: {
            Text("A name for the current \(isVideo ? "video" : "picture") filters.")
        }
    }

    private func save() {
        let name = newViewName.trimmingCharacters(in: .whitespacesAndNewlines)
        newViewName = ""
        guard !name.isEmpty else { return }
        if isVideo { appModel.createSavedVideoView(name: name) } else { appModel.createSavedView(name: name) }
    }

    private var emptyRow: some View {
        Text("No saved views").foregroundStyle(.secondary)
    }

    private func row(name: String, isDefault: Bool, isSelected: Bool,
                     apply: @escaping () -> Void, deselect: @escaping () -> Void,
                     update: @escaping () -> Void, toggleDefault: @escaping () -> Void,
                     delete: @escaping () -> Void) -> some View {
        Button {
            isSelected ? deselect() : apply()
        } label: {
            TVCheckRow(title: name, detail: isDefault ? "Default" : nil, isChecked: isSelected)
        }
        .contextMenu {
            Button("Update with Current Filters", systemImage: "arrow.triangle.2.circlepath", action: update)
            Button(isDefault ? "Unset Default" : "Set as Default", systemImage: isDefault ? "star.slash" : "star",
                   action: toggleDefault)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

/// One multi-select dimension: the match rule, a search for the server's
/// longer lists, and every value with a checkmark on the chosen ones (those
/// first, so a long list never hides what is in force).
private struct TVFilterDimensionPage: View {
    @Environment(AppModel.self) private var appModel
    let dimension: TVFilterDimension
    let isVideo: Bool
    @Binding var selection: [AutocompleteItem]
    @Binding var modifier: CriterionModifier
    @State private var query = ""

    private var available: [AutocompleteItem] {
        switch dimension {
        case .galleries: appModel.availableGalleries
        case .tags: appModel.availableTags
        case .studios: appModel.availableStudios
        case .performers: appModel.availablePerformers
        case .groups: appModel.availableGroups.map(\.filterItem)
        case .albums: appModel.availablePhotoAlbums.map { AutocompleteItem(id: $0.id, name: $0.name) }
        case .people: appModel.availablePhotoPeople.map { AutocompleteItem(id: $0.id, name: $0.name) }
        }
    }

    private var isLoading: Bool {
        switch dimension {
        case .galleries: appModel.isLoadingGalleries
        case .tags: appModel.isLoadingTags
        case .studios: appModel.isLoadingStudios
        case .performers: appModel.isLoadingPerformers
        case .albums, .people: appModel.isLoadingPhotoAlbums
        case .groups: false
        }
    }

    /// The chosen values, then the rest matching the search.
    private var rows: [AutocompleteItem] {
        let chosen = Set(selection.map(\.id))
        var others = available.filter { !chosen.contains($0.id) }
        if !dimension.searchesServer, !query.isEmpty {
            others = others.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return selection + others
    }

    var body: some View {
        List {
            TVChoiceSection(title: "Match", choices: CriterionModifier.multiModifiers, selection: $modifier)
            Section {
                TextField("Search \(dimension.title.lowercased())", text: $query)
                if isLoading, available.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    Text("Nothing to choose from.").foregroundStyle(.secondary)
                }
                ForEach(rows) { item in
                    let isChosen = selection.contains { $0.id == item.id }
                    Button {
                        if isChosen {
                            selection.removeAll { $0.id == item.id }
                        } else {
                            selection.append(item)
                        }
                    } label: {
                        TVCheckRow(title: item.name, isChecked: isChosen)
                    }
                }
            } header: {
                Text(dimension.title)
            }
        }
        .navigationTitle(dimension.title)
        .task(id: query) {
            guard dimension.searchesServer else { return }
            // A short pause, so each letter typed isn't its own query.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            switch dimension {
            case .galleries: await appModel.searchGalleries(query: query)
            case .tags: await appModel.searchTags(query: query)
            case .studios: await appModel.searchStudios(query: query)
            case .performers: await appModel.searchPerformers(query: query)
            case .groups, .albums, .people: break
            }
        }
    }
}

/// A numeric criterion (rating in stars, activity as a count): on or off,
/// its condition, and the value or range it compares with.
private struct TVNumberCriterionPage: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var modifier: CriterionModifier
    @Binding var value: Int?
    @Binding var range: NumberRange
    /// Values are 1-5 stars, chosen from rows; otherwise typed counts.
    let stars: Bool

    var body: some View {
        List {
            Section {
                Toggle("Filter by \(title)", isOn: $enabled)
            }
            if enabled {
                TVChoiceSection(title: "Condition", choices: CriterionModifier.numberModifiers, selection: $modifier)
                if modifier.requiresRange {
                    valueSection("From", value: $range.min, fallback: stars ? 1 : 0)
                    valueSection("To", value: $range.max, fallback: stars ? 5 : 0)
                } else if modifier.requiresValue {
                    valueSection(stars ? "Stars" : "Count", value: $value, fallback: stars ? 3 : 0)
                }
            }
        }
        .navigationTitle(title)
    }

    @ViewBuilder
    private func valueSection(_ heading: String, value: Binding<Int?>, fallback: Int) -> some View {
        Section(heading) {
            if stars {
                ForEach(1 ... 5, id: \.self) { count in
                    Button {
                        value.wrappedValue = count
                    } label: {
                        TVCheckRow(title: String(repeating: "★", count: count) + String(repeating: "☆", count: 5 - count),
                                   isChecked: (value.wrappedValue ?? fallback) == count)
                    }
                }
            } else {
                TextField(heading, value: value, format: .number)
                    .keyboardType(.numberPad)
            }
        }
    }
}

/// The Photos date filter as spans ending today: there is no date picker
/// on tvOS to choose arbitrary days with.
enum TVPhotosDateSpan: CaseIterable, Hashable {
    case week, month, threeMonths, year, fiveYears

    var title: String {
        switch self {
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .threeMonths: "Last 3 Months"
        case .year: "Last Year"
        case .fiveYears: "Last 5 Years"
        }
    }

    private var start: DateComponents {
        switch self {
        case .week: DateComponents(day: -7)
        case .month: DateComponents(day: -30)
        case .threeMonths: DateComponents(month: -3)
        case .year: DateComponents(year: -1)
        case .fiveYears: DateComponents(year: -5)
        }
    }

    /// The range this span sets: from the start of its first day to the end
    /// of today, as the other platforms' date pickers store a range.
    func range(now: Date = .now) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: self.start, to: today) ?? today
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: today) ?? now
        return (start, end)
    }

    /// The span a criteria's range was set from, if it still matches one.
    static func matching(_ criteria: PhotosFilterCriteria) -> TVPhotosDateSpan? {
        guard let start = criteria.startDate else { return nil }
        let calendar = Calendar.current
        return allCases.first { calendar.isDate($0.range().start, inSameDayAs: start) }
    }

    static func summary(of criteria: PhotosFilterCriteria) -> String {
        guard criteria.dateRangeEnabled else { return "Any" }
        if let span = matching(criteria) { return span.title }
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return [criteria.startDate, criteria.endDate].compactMap { $0?.formatted(format) }.joined(separator: " – ")
    }
}

private struct TVPhotosDatePage: View {
    @Binding var criteria: PhotosFilterCriteria

    var body: some View {
        List {
            Section {
                Button {
                    criteria.dateRangeEnabled = false
                } label: {
                    TVCheckRow(title: "Any Date", isChecked: !criteria.dateRangeEnabled)
                }
                ForEach(TVPhotosDateSpan.allCases, id: \.self) { span in
                    Button {
                        let range = span.range()
                        criteria.startDate = range.start
                        criteria.endDate = range.end
                        criteria.dateRangeEnabled = true
                    } label: {
                        TVCheckRow(title: span.title,
                                   isChecked: criteria.dateRangeEnabled && TVPhotosDateSpan.matching(criteria) == span)
                    }
                }
                // A range set elsewhere (a saved view from another device)
                // that is none of the spans: shown, and kept until changed.
                if criteria.dateRangeEnabled, TVPhotosDateSpan.matching(criteria) == nil {
                    TVCheckRow(title: TVPhotosDateSpan.summary(of: criteria), isChecked: true)
                }
            } footer: {
                Text("Pictures and videos taken in that span, up to today.")
            }
        }
        .navigationTitle("Date")
    }
}

#endif
