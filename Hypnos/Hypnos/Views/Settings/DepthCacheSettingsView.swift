/*
 Hypnos - Depth Cache Settings

 Management UI for pre-processed fake-3D depth caches (Settings → AI 3D →
 Converted Videos): lists converted videos with the model that
 produced them and their on-disk size, with per-entry delete and Clear All.
 Entries from an older pipeline version are marked outdated — they no longer
 match at playback and can be re-converted.
 */

import RAVEMedia
import SwiftUI

struct DepthCacheSettingsView: View {
    @State private var entries: [DepthCacheStore.Entry] = []
    @State private var totalSize: Int64 = 0

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("No converted videos yet.")
                    .foregroundStyle(.secondary)
            } else {
                platformDisclosureGroup {
                    ForEach(entries, id: \.directory) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.meta.title ?? entry.meta.videoIdentity)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(DepthModelManager.displayName(for: entry.meta.modelName))
                                    Text(ByteCountFormatter.string(fromByteCount: DepthCacheStore.entrySize(entry), countStyle: .file))
                                    if entry.meta.version != DepthCacheStore.pipelineVersion {
                                        Text("outdated")
                                            .foregroundColor(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                DepthCacheStore.deleteEntry(at: entry.directory)
                                refresh()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button(role: .destructive) {
                        DepthCacheStore.deleteAll()
                        refresh()
                    } label: {
                        Label("Clear All Converted Videos", systemImage: "trash")
                    }
                } label: {
                    HStack {
                        Text("Converted 3D Videos")
                        Spacer()
                        Text("\(entries.count) · \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        entries = DepthCacheStore.allEntries()
        totalSize = DepthCacheStore.totalSize()
    }
}
