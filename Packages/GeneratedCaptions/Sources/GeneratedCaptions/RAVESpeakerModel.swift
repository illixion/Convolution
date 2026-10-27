import CryptoKit
import Foundation
import Observation
import VergenceApple

/// Optional speaker labels. The Swift runtime is shipped in the app; only model
/// data is fetched. Pin the revision so model shapes and host configuration agree.
@MainActor @Observable
public final class RAVESpeakerModel {
    public static let shared = RAVESpeakerModel()
    public static let name = "Sortformer_v2.1.mlmodelc"
    public static let attribution = "Streaming Sortformer by NVIDIA; Core ML conversion by FluidInference. CC BY 4.0."
    public static let revision = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
    public private(set) var progress: Double?
    public private(set) var error: String?
    public private(set) var isInstalled = false
    public private(set) var activeSessions = 0
    public var isInUse: Bool { activeSessions > 0 }
    private var task: Task<Void, Never>?
    public var modelURL: URL { directory.appendingPathComponent(Self.name) }
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakerModels", isDirectory: true)
    }
    private init() { refresh() }
    public func refresh() { isInstalled = FileManager.default.fileExists(atPath: modelURL.appendingPathComponent(".installed").path) }
    public func cancel() { task?.cancel() }
    public func beginUsing() { activeSessions += 1 }
    public func endUsing() { activeSessions = max(0, activeSessions - 1) }
    public func delete() {
        guard task == nil, !isInUse else { return }
        do { try FileManager.default.removeItem(at: modelURL); refresh() }
        catch { self.error = error.localizedDescription }
    }
    public func download() {
        guard task == nil else { return }
        progress = 0
        error = nil
        task = Task {
            defer { progress = nil; task = nil }
            do { try await install(); refresh() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private struct Entry: Decodable {
        var type: String; var path: String; var size: Int64
        var lfs: LFS?
        struct LFS: Decodable { var oid: String }
    }
    private func install() async throws {
        let repo = "https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml"
        let prefix = "v3/palettized/\(Self.name)"
        let api = URL(string: "https://huggingface.co/api/models/FluidInference/diar-streaming-sortformer-coreml/tree/\(Self.revision)/\(prefix)?recursive=true&limit=1000")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let files = try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }
        guard !files.isEmpty, files.allSatisfy({ $0.path.hasPrefix(prefix + "/") && !$0.path.contains("..") }) else { throw URLError(.cannotParseResponse) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var completed: Int64 = 0
        for entry in files {
            try Task.checkCancellation()
            let base = completed
            let downloader = ModelFileDownloader(expectedBytes: entry.size) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.progress != nil else { return }
                    self.progress = Double(base) / Double(total) + fraction * Double(entry.size) / Double(total)
                }
            }
            let url = URL(string: "\(repo)/resolve/\(Self.revision)/\(entry.path)")!
            let temporary = try await downloader.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == Int(entry.size) else { throw URLError(.cannotDecodeContentData) }
            if let checksum = entry.lfs?.oid {
                let handle = try FileHandle(forReadingFrom: temporary)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else { throw URLError(.cannotDecodeContentData) }
            }
            let destination = staging.appendingPathComponent(String(entry.path.dropFirst(prefix.count + 1)))
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
            completed += entry.size
        }
        try Task.checkCancellation()
        try Data(Self.revision.utf8).write(to: staging.appendingPathComponent(".installed"))
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        if fm.fileExists(atPath: modelURL.path) { try fm.removeItem(at: modelURL) }
        try fm.moveItem(at: staging, to: modelURL)
    }
}
