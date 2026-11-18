//
//  Gen3DClient.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D): the client for Gen3DServer, the private
//  image-to-3D gateway (`Gen3DServer/README.md` has the contract). The app only
//  ever speaks this engine-neutral contract, so no model is tied into the app
//  and a licence question is settled only if something ships.
//

#if HYPNOS_GEN3D

import DebugTrace
import Foundation

/// Where the gateway is, and the token that opens it.
enum Gen3DConfig {
    static let urlKey = "gen3dServerURL"
    static let engineKey = "gen3dEngine"
    static let defaultEngine = "trellis2"

    static var baseURL: URL? {
        let text = (HypnosDefaults.store.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return URL(string: text.contains("://") ? text : "http://" + text)
    }

    static var token: String? { KeychainStore.string(for: .gen3dToken) }

    static var engine: String {
        let stored = HypnosDefaults.store.string(forKey: engineKey) ?? ""
        return stored.isEmpty ? defaultEngine : stored
    }

    /// What the server is asked for. A phone-or-headset-sized asset: geometry,
    /// not texture, is most of a result's size (the 500k-triangle default made a
    /// 69 MB USDZ).
    static let optionsJSON = #"{"decimation_target":150000,"pipeline_type":"1024_cascade","texture_size":2048}"#
}

struct Gen3DJobStatus: Decodable, Sendable {
    struct Progress: Decodable, Sendable {
        let stage: String?
        let fraction: Double?
    }
    struct Result: Decodable, Sendable {
        let files: [String]
        let timings: [String: Double]?
    }
    let id: String
    let status: String
    let progress: Progress?
    let result: Result?
    let error: String?
}

enum Gen3DError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the server address and token in Settings → Developer → Generated 3D."
        case .http(401, _): return "The server rejected the token."
        case .http(let code, let body): return "The server answered \(code). \(body)"
        case .failed(let message): return message
        }
    }
}

struct Gen3DClient: Sendable {
    let base: URL
    let token: String

    init() throws {
        guard let base = Gen3DConfig.baseURL, let token = Gen3DConfig.token, !token.isEmpty else {
            throw Gen3DError.notConfigured
        }
        self.base = base
        self.token = token
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("v1").appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Gen3DError.failed("No HTTP response.") }
        guard (200...299).contains(http.statusCode) else {
            throw Gen3DError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// Submits the picture; returns the job id.
    func submit(image: Data, engine: String, optionsJSON: String) async throws -> String {
        let boundary = "gen3d-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("engine", engine)
        field("options", optionsJSON)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = request("jobs", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try check(response, data)
        return try JSONDecoder().decode(Gen3DJobStatus.self, from: data).id
    }

    func status(of id: String) async throws -> Gen3DJobStatus {
        let (data, response) = try await URLSession.shared.data(for: request("jobs/\(id)"))
        try check(response, data)
        return try JSONDecoder().decode(Gen3DJobStatus.self, from: data)
    }

    /// Downloads one of a finished job's files to `destination`.
    func download(job id: String, file: String, to destination: URL) async throws {
        var request = request("jobs/\(id)/files/\(file)")
        request.timeoutInterval = 600
        let (temp, response) = try await URLSession.shared.download(for: request)
        try check(response, Data())
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

#endif
