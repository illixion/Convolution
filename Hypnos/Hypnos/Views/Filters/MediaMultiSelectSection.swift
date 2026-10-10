/*
 Hypnos - Media Multi-Select Filter Section

 One multi-select filter dimension: selected values as chips, an operator, and a
 searchable list of what else can be picked.

 Written once for albums and people rather than per dimension. The Stash filters
 next door are four near-identical copies of this interaction (galleries, tags,
 studios, performers) that have already drifted apart in small ways, and the
 photo-library side is not going to add two more.

 Chips carry a thumbnail when the dimension can supply one — an album shows its
 first photo, and a person will show their face once there is a source for faces.
 A name alone is a poor way to recognise either.
 */

import Photos
import SwiftUI
import RAVEUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// One pickable value, flattened from whatever the dimension's own model is so
/// this view stays non-generic.
struct FilterOption: Identifiable, Hashable {
    let id: String
    let name: String
    /// Trailing detail, typically a count.
    let detail: String?
    /// A cover to draw, when the dimension has one. Any URL
    /// `ImageLoader.loadThumbnail(from:)` resolves.
    let thumbnailURL: URL?
    /// Sorted after the primary group and separated from it — user albums come
    /// before the system's smart albums.
    let isSecondary: Bool

    init(id: String,
         name: String,
         detail: String? = nil,
         thumbnailURL: URL? = nil,
         isSecondary: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.thumbnailURL = thumbnailURL
        self.isSecondary = isSecondary
    }
}

struct MediaMultiSelectSection: View {
    let title: String
    var footer: String?
    var emptyMessage: String = "Nothing to choose from."
    let options: [FilterOption]
    var isLoading: Bool = false
    @Binding var selection: [AutocompleteItem]
    @Binding var modifier: CriterionModifier

    /// Above this many options the list gets a filter field of its own.
    private static let searchThreshold = 8

    @State private var query = ""

    private var filteredOptions: [FilterOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var coversById: [String: URL] {
        Dictionary(options.compactMap { option in
            option.thumbnailURL.map { (option.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        Section {
            if !selection.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(selection) { item in
                        MediaFilterChip(name: item.name,
                                        coverURL: coversById[item.id]) {
                            selection.removeAll { $0.id == item.id }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Only meaningful with more than one value: "any of" and "all of"
                // describe the same set when there is a single member.
                if selection.count > 1 {
                    Picker("Match", selection: $modifier) {
                        ForEach(CriterionModifier.multiModifiers) { option in
                            Text(matchLabel(for: option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
            } else if options.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                if options.count > Self.searchThreshold {
                    TextField("Filter this list...", text: $query)
                        .textFieldTapTarget()
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }

                ForEach(filteredOptions) { option in
                    optionRow(option)
                }

                if filteredOptions.isEmpty {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: FilterOption) -> some View {
        let isSelected = selection.contains { $0.id == option.id }
        Button {
            if isSelected {
                selection.removeAll { $0.id == option.id }
            } else {
                selection.append(AutocompleteItem(id: option.id, name: option.name))
            }
        } label: {
            HStack(spacing: 12) {
                MediaThumbnail(url: option.thumbnailURL, side: 32)
                Text(option.name)
                    .foregroundStyle(option.isSecondary ? .secondary : .primary)
                Spacer()
                if let detail = option.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The operators, named for what they mean here rather than in Stash's
    /// vocabulary — "includes all" is accurate and unreadable.
    private func matchLabel(for modifier: CriterionModifier) -> String {
        switch modifier {
        case .includesAll: return "All of"
        case .includes: return "Any of"
        case .excludes: return "None of"
        default: return modifier.displayName
        }
    }
}

// MARK: - Chip

struct MediaFilterChip: View {
    let name: String
    var coverURL: URL?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MediaThumbnail(url: coverURL, side: 28)
            Text(name)
                .font(.body)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(12)
    }
}
