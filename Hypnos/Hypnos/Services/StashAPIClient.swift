/*
 Hypnos - Stash API Client

 GraphQL client for communicating with Stash server.
 */

import DebugTrace
import Foundation

/// Configuration for Stash server connection
struct StashServerConfig {
    var serverURL: URL
    var apiKey: String?

    static var `default`: StashServerConfig {
        StashServerConfig(
            serverURL: URL(string: "http://localhost:9999")!,
            apiKey: nil
        )
    }
}

/// GraphQL response wrapper
struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable, Error {
    let message: String
    let locations: [GraphQLErrorLocation]?
    let path: [String]?
}

struct GraphQLErrorLocation: Decodable {
    let line: Int
    let column: Int
}

/// Stash API Client for GraphQL queries
actor StashAPIClient {
    private var config: StashServerConfig
    private let session: URLSession

    init(config: StashServerConfig = .default) {
        self.config = config
        self.session = URLSession.shared
    }

    func updateConfig(_ newConfig: StashServerConfig) {
        self.config = newConfig
    }

    var graphQLEndpoint: URL {
        config.serverURL.appendingPathComponent("graphql")
    }

    // MARK: - Generic GraphQL Query

    func query<T: Decodable>(_ query: String, variables: [String: Any]? = nil) async throws -> T {
        let endpoint = graphQLEndpoint
        AppLogger.stashAPI.debug("Making request to: \(endpoint, privacy: .private)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            // Mirrors `AppModel.updateStashMediaCredential`'s two cases: a
            // plain Stash API key authenticates via Stash's own `ApiKey`
            // header (`pkg/session.ApiKeyHeader` in Stash's source — verified
            // against a real instance that `Authorization: Bearer <key>` gets
            // a flat 401 there, which is exactly what silently broke this
            // client against any Stash requiring login, even though the
            // media/stream paths kept working via the `?apikey=` query
            // param). A `Bearer …`-prefixed value is the manual escape hatch
            // for a reverse proxy in front of Stash (Cloudflare Access,
            // Authelia, …) that wants a real `Authorization: Bearer` token;
            // that one is sent verbatim, not reinterpreted as a Stash key.
            if apiKey.lowercased().hasPrefix("bearer ") {
                request.setValue(apiKey, forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(apiKey, forHTTPHeaderField: "ApiKey")
            }
            AppLogger.stashAPI.debug("Using API key authentication")
        }

        var body: [String: Any] = ["query": query]
        if let variables = variables {
            body["variables"] = variables
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        AppLogger.stashAPI.debug("Request body: \(String(data: bodyData, encoding: .utf8) ?? "nil", privacy: .private)")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.stashAPI.error("Invalid response type")
                throw StashAPIError.invalidResponse
            }

            AppLogger.stashAPI.debug("Response status: \(httpResponse.statusCode, privacy: .public)")

            guard (200...299).contains(httpResponse.statusCode) else {
                AppLogger.stashAPI.error("HTTP error: \(httpResponse.statusCode, privacy: .public)")
                if let responseString = String(data: data, encoding: .utf8) {
                    AppLogger.stashAPI.debug("Response body: \(responseString, privacy: .private)")
                }
                throw StashAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            if let responseString = String(data: data, encoding: .utf8) {
                AppLogger.stashAPI.debug("Response: \(responseString.prefix(500), privacy: .private)...")
            }

            let decoder = JSONDecoder()
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                AppLogger.stashAPI.error("GraphQL errors: \(errors.map { $0.message })")
                throw StashAPIError.graphQLErrors(errors)
            }

            guard let responseData = graphQLResponse.data else {
                AppLogger.stashAPI.error("No data in response")
                throw StashAPIError.noData
            }

            AppLogger.stashAPI.debug("Query successful")
            return responseData
        } catch let error as StashAPIError {
            throw error
        } catch {
            AppLogger.stashAPI.error("Network error: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            throw error
        }
    }

    // MARK: - Image Queries

    struct FindImagesResponse: Decodable {
        let findImages: FindImagesResult
    }

    struct FindImagesResult: Decodable {
        let count: Int
        let images: [StashImage]
    }

    struct StashImage: Decodable {
        let id: String
        let title: String?
        let rating100: Int?
        let o_counter: Int?
        let paths: StashImagePaths
        let files: [StashImageFile]?
        let visual_files: [StashVisualFile]?
    }

    struct StashImagePaths: Decodable {
        let thumbnail: String?
        let image: String?
    }

    struct StashImageFile: Decodable {
        let width: Int?
        let height: Int?
    }

    struct StashVisualFile: Decodable {
        let typename: String?
        let path: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case path
        }
    }

    func findImages(page: Int, perPage: Int, query: String? = nil) async throws -> FindImagesResult {
        try await findImages(page: page, perPage: perPage, filter: nil, query: query)
    }

    /// - Parameter ids: When non-nil, restricts the query to these image ids.
    ///   The server still applies `filter` for paging and sort, so this composes
    ///   with everything else rather than replacing it. Used by the Converted to
    ///   3D filter, whose set is known locally and cannot be expressed as an
    ///   `ImageFilterType` at all.
    func findImages(page: Int, perPage: Int, filter: ImageFilterCriteria?, query: String? = nil, ids: [String]? = nil) async throws -> FindImagesResult {
        let graphQLQuery = """
        query FindImages($filter: FindFilterType, $image_filter: ImageFilterType, $ids: [ID!]) {
            findImages(filter: $filter, image_filter: $image_filter, ids: $ids) {
                count
                images {
                    id
                    title
                    rating100
                    o_counter
                    paths {
                        thumbnail
                        image
                    }
                    files {
                        width
                        height
                    }
                    visual_files {
                        __typename
                        ... on ImageFile {
                            path
                        }
                        ... on VideoFile {
                            path
                        }
                    }
                }
            }
        }
        """

        // Build FindFilterType
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage
        ]

        // Apply sort from filter or use defaults
        if let filter = filter {
            // Handle random sort with seed
            if filter.sortField == .random {
                let seed = filter.randomSeed ?? Int.random(in: 10_000_000..<100_000_000)
                filterVariables["sort"] = "random_\(seed)"
            } else {
                filterVariables["sort"] = filter.sortField.rawValue
            }
            filterVariables["direction"] = filter.sortDirection.rawValue

            // Search term goes in FindFilterType.q
            if !filter.searchTerm.isEmpty {
                filterVariables["q"] = filter.searchTerm
            }
        } else {
            filterVariables["sort"] = "created_at"
            filterVariables["direction"] = "DESC"

            if let query = query, !query.isEmpty {
                filterVariables["q"] = query
            }
        }

        var variables: [String: Any] = ["filter": filterVariables]
        if let ids {
            variables["ids"] = ids
        }

        // Build ImageFilterType if we have filter criteria
        if let filter = filter, filter.hasActiveFilters {
            var imageFilter: [String: Any] = [:]

            // Gallery filter
            if !filter.galleryIds.isEmpty {
                imageFilter["galleries"] = [
                    "value": filter.galleryIds,
                    "modifier": filter.galleryModifier.rawValue
                ]
            }

            // O Count filter
            if filter.oCountEnabled {
                var oCountCriterion: [String: Any] = [
                    "modifier": filter.oCountModifier.rawValue
                ]
                if filter.oCountModifier.requiresRange {
                    oCountCriterion["value"] = filter.oCountRange.min ?? 0
                    oCountCriterion["value2"] = filter.oCountRange.max ?? 0
                } else if filter.oCountModifier.requiresValue, let value = filter.oCountValue {
                    oCountCriterion["value"] = value
                }
                imageFilter["o_counter"] = oCountCriterion
            }

            // Rating filter (uses rating100 in API, 1-100 scale)
            if filter.ratingEnabled {
                var ratingCriterion: [String: Any] = [
                    "modifier": filter.ratingModifier.rawValue
                ]
                if filter.ratingModifier.requiresRange {
                    ratingCriterion["value"] = ImageFilterCriteria.ratingToAPI(filter.ratingRange.min ?? 1)
                    ratingCriterion["value2"] = ImageFilterCriteria.ratingToAPI(filter.ratingRange.max ?? 5)
                } else if filter.ratingModifier.requiresValue, let value = filter.ratingValue {
                    ratingCriterion["value"] = ImageFilterCriteria.ratingToAPI(value)
                }
                imageFilter["rating100"] = ratingCriterion
            }

            // Tags filter
            if !filter.tagIds.isEmpty {
                imageFilter["tags"] = [
                    "value": filter.tagIds,
                    "modifier": filter.tagModifier.rawValue
                ]
            }

            // Studios filter
            if !filter.studioIds.isEmpty {
                imageFilter["studios"] = [
                    "value": filter.studioIds,
                    "modifier": filter.studioModifier.rawValue
                ]
            }

            // Performers filter
            if !filter.performerIds.isEmpty {
                imageFilter["performers"] = [
                    "value": filter.performerIds,
                    "modifier": filter.performerModifier.rawValue
                ]
            }

            if !imageFilter.isEmpty {
                variables["image_filter"] = imageFilter
            }
        }

        let response: FindImagesResponse = try await self.query(graphQLQuery, variables: variables)
        return response.findImages
    }

    struct FindImageByIDResponse: Decodable {
        let findImage: StashImage?
    }

    /// Fetch a single image by its Stash ID (used by the `hypnos://image?id=`
    /// callback). Mirrors the field selection of `findImages` so the result can be
    /// mapped by the same `GraphQLImageSource.makeGalleryImage(from:)`.
    func findImage(id: String) async throws -> StashImage? {
        let graphQLQuery = """
        query FindImage($id: ID!) {
            findImage(id: $id) {
                id
                title
                rating100
                o_counter
                paths {
                    thumbnail
                    image
                }
                files {
                    width
                    height
                }
                visual_files {
                    __typename
                    ... on ImageFile {
                        path
                    }
                    ... on VideoFile {
                        path
                    }
                }
            }
        }
        """
        let response: FindImageByIDResponse = try await self.query(graphQLQuery, variables: ["id": id])
        return response.findImage
    }

    // MARK: - Gallery Queries (for autocomplete)

    struct FindGalleriesResponse: Decodable {
        let findGalleries: FindGalleriesResult
    }

    struct FindGalleriesResult: Decodable {
        let count: Int
        let galleries: [StashGallery]
    }

    struct StashGallery: Decodable {
        let id: String
        let title: String?
        let folder: StashGalleryFolder?
        let files: [StashGalleryFile]?
        /// Optional despite being non-null in the schema, so an older server
        /// that omits it decodes rather than failing the whole query.
        let image_count: Int?
        let cover: StashGalleryCover?

        /// The name to show for a gallery.
        ///
        /// Stash galleries frequently have no title — a folder-based gallery
        /// carries its identity in the path — so the name is derived, in
        /// descending order of how much the user would recognise it: the title,
        /// the folder's own name, the directory containing the first file, and
        /// finally the id, which at least identifies it uniquely.
        ///
        /// Lives on the model because both the filter autocomplete and the
        /// Albums browser need it and had no business each deriving it.
        var displayName: String {
            if let title, !title.isEmpty {
                return title
            }
            if let lastComponent = folder?.path.components(separatedBy: "/").last,
               !lastComponent.isEmpty {
                return lastComponent
            }
            if let firstFile = files?.first {
                let components = firstFile.path.components(separatedBy: "/")
                if components.count >= 2 {
                    return components[components.count - 2]
                }
                if let fileName = components.last, !fileName.isEmpty {
                    return fileName
                }
            }
            return "Gallery \(id)"
        }
    }

    struct StashGalleryFolder: Decodable {
        let path: String
    }

    struct StashGalleryFile: Decodable {
        let path: String
    }

    struct StashGalleryCover: Decodable {
        let paths: StashGalleryCoverPaths?
    }

    struct StashGalleryCoverPaths: Decodable {
        let thumbnail: String?
    }

    func findGalleries(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindGalleriesResult {
        let graphQLQuery = """
        query FindGalleries($filter: FindFilterType) {
            findGalleries(filter: $filter) {
                count
                galleries {
                    id
                    title
                    folder {
                        path
                    }
                    files {
                        path
                    }
                    image_count
                    cover {
                        paths {
                            thumbnail
                        }
                    }
                }
            }
        }
        """

        // Determine page size: use larger limit when searching to ensure comprehensive results
        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
            "sort": "title",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindGalleriesResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findGalleries
    }

    // MARK: - Group Queries

    struct FindGroupsResponse: Decodable {
        let findGroups: FindGroupsResult
    }

    struct FindGroupsResult: Decodable {
        let count: Int
        let groups: [StashGroup]
    }

    struct StashGroup: Decodable {
        let id: String
        let name: String
        /// Optional despite being non-null in the schema, so an older server that
        /// omits it decodes rather than failing the whole query.
        let scene_count: Int?
        let front_image_path: String?
    }

    /// Groups are Stash's containers for *scenes* — what galleries are for
    /// images. The Albums browser needs them for the Videos side to exist at all.
    func findGroups(query: String? = nil, page: Int = 1, perPage: Int = 100) async throws -> FindGroupsResult {
        let graphQLQuery = """
        query FindGroups($filter: FindFilterType) {
            findGroups(filter: $filter) {
                count
                groups {
                    id
                    name
                    scene_count
                    front_image_path
                }
            }
        }
        """

        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage,
            "sort": "name",
            "direction": "ASC"
        ]
        if let query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindGroupsResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findGroups
    }

    // MARK: - Tag Queries (for autocomplete)

    struct FindTagsResponse: Decodable {
        let findTags: FindTagsResult
    }

    struct FindTagsResult: Decodable {
        let count: Int
        let tags: [StashTag]
    }

    struct StashTag: Decodable {
        let id: String
        let name: String
    }

    func findTags(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindTagsResult {
        let graphQLQuery = """
        query FindTags($filter: FindFilterType) {
            findTags(filter: $filter) {
                count
                tags {
                    id
                    name
                }
            }
        }
        """

        // Determine page size: use larger limit when searching to ensure comprehensive results
        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
            "sort": "name",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindTagsResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findTags
    }

    // MARK: - Studio Queries (for autocomplete)

    struct FindStudiosResponse: Decodable {
        let findStudios: FindStudiosResult
    }

    struct FindStudiosResult: Decodable {
        let count: Int
        let studios: [StashStudio]
    }

    struct StashStudio: Decodable {
        let id: String
        let name: String
    }

    func findStudios(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindStudiosResult {
        let graphQLQuery = """
        query FindStudios($filter: FindFilterType) {
            findStudios(filter: $filter) {
                count
                studios {
                    id
                    name
                }
            }
        }
        """

        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
            "sort": "name",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindStudiosResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findStudios
    }

    // MARK: - Performer Queries (for autocomplete)

    struct FindPerformersResponse: Decodable {
        let findPerformers: FindPerformersResult
    }

    struct FindPerformersResult: Decodable {
        let count: Int
        let performers: [StashPerformer]
    }

    struct StashPerformer: Decodable {
        let id: String
        let name: String
    }

    func findPerformers(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindPerformersResult {
        let graphQLQuery = """
        query FindPerformers($filter: FindFilterType) {
            findPerformers(filter: $filter) {
                count
                performers {
                    id
                    name
                }
            }
        }
        """

        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
            "sort": "name",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindPerformersResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findPerformers
    }

    // MARK: - Scene/Video Queries

    struct FindScenesResponse: Decodable {
        let findScenes: FindScenesResult
    }

    struct FindScenesResult: Decodable {
        let count: Int
        let scenes: [StashScene]
    }

    struct StashScene: Decodable {
        let id: String
        let title: String?
        let details: String?
        let date: String?
        let rating100: Int?
        let o_counter: Int?
        let paths: StashScenePaths
        let files: [StashSceneFile]?
        let tags: [StashSceneTag]?
        let sceneStreams: [StashSceneStreamEndpoint]?
    }

    struct StashSceneTag: Decodable {
        let id: String
        let name: String
    }

    struct StashScenePaths: Decodable {
        let screenshot: String?
        let stream: String?
        /// Short auto-generated scene preview clip (`/scene/{id}/preview`),
        /// used for the gallery long-press quick look.
        let preview: String?
    }

    struct StashSceneFile: Decodable {
        let path: String?
        let width: Int?
        let height: Int?
        let duration: Double?
    }

    struct StashSceneStreamEndpoint: Decodable {
        let url: String
        let mime_type: String?
        let label: String?
    }

    func findScenes(page: Int, perPage: Int, query: String? = nil) async throws -> FindScenesResult {
        try await findScenes(page: page, perPage: perPage, filter: nil, query: query)
    }

    /// - Parameter ids: When non-nil, restricts the query to these scene ids.
    ///   See `findImages(page:perPage:filter:query:ids:)`.
    func findScenes(page: Int, perPage: Int, filter: SceneFilterCriteria?, query: String? = nil, ids: [String]? = nil) async throws -> FindScenesResult {
        let graphQLQuery = """
        query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType, $ids: [ID!]) {
            findScenes(filter: $filter, scene_filter: $scene_filter, ids: $ids) {
                count
                scenes {
                    id
                    title
                    details
                    date
                    rating100
                    o_counter
                    paths {
                        screenshot
                        stream
                        preview
                    }
                    files {
                        path
                        width
                        height
                        duration
                    }
                    tags {
                        id
                        name
                    }
                    sceneStreams {
                        url
                        mime_type
                        label
                    }
                }
            }
        }
        """

        // Build FindFilterType
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage
        ]

        // Apply sort from filter or use defaults
        if let filter = filter {
            // Handle random sort with seed
            if filter.sortField == .random {
                let seed = filter.randomSeed ?? Int.random(in: 10_000_000..<100_000_000)
                filterVariables["sort"] = "random_\(seed)"
            } else {
                filterVariables["sort"] = filter.sortField.rawValue
            }
            filterVariables["direction"] = filter.sortDirection.rawValue

            // Search term goes in FindFilterType.q
            if !filter.searchTerm.isEmpty {
                filterVariables["q"] = filter.searchTerm
            }
        } else {
            filterVariables["sort"] = "created_at"
            filterVariables["direction"] = "DESC"

            if let query = query, !query.isEmpty {
                filterVariables["q"] = query
            }
        }

        var variables: [String: Any] = ["filter": filterVariables]
        if let ids {
            variables["ids"] = ids
        }

        // Build SceneFilterType if we have filter criteria
        if let filter = filter, filter.hasActiveFilters {
            var sceneFilter: [String: Any] = [:]

            // Gallery filter (scenes use 'galleries' field like images)
            if !filter.galleryIds.isEmpty {
                sceneFilter["galleries"] = [
                    "value": filter.galleryIds,
                    "modifier": filter.galleryModifier.rawValue
                ]
            }

            // O Count filter
            if filter.oCountEnabled {
                var oCountCriterion: [String: Any] = [
                    "modifier": filter.oCountModifier.rawValue
                ]
                if filter.oCountModifier.requiresRange {
                    oCountCriterion["value"] = filter.oCountRange.min ?? 0
                    oCountCriterion["value2"] = filter.oCountRange.max ?? 0
                } else if filter.oCountModifier.requiresValue, let value = filter.oCountValue {
                    oCountCriterion["value"] = value
                }
                sceneFilter["o_counter"] = oCountCriterion
            }

            // Rating filter (uses rating100 in API, 1-100 scale)
            if filter.ratingEnabled {
                var ratingCriterion: [String: Any] = [
                    "modifier": filter.ratingModifier.rawValue
                ]
                if filter.ratingModifier.requiresRange {
                    ratingCriterion["value"] = SceneFilterCriteria.ratingToAPI(filter.ratingRange.min ?? 1)
                    ratingCriterion["value2"] = SceneFilterCriteria.ratingToAPI(filter.ratingRange.max ?? 5)
                } else if filter.ratingModifier.requiresValue, let value = filter.ratingValue {
                    ratingCriterion["value"] = SceneFilterCriteria.ratingToAPI(value)
                }
                sceneFilter["rating100"] = ratingCriterion
            }

            // Tags filter
            if !filter.tagIds.isEmpty {
                sceneFilter["tags"] = [
                    "value": filter.tagIds,
                    "modifier": filter.tagModifier.rawValue
                ]
            }

            // Groups filter. HierarchicalMultiCriterionInput also accepts a
            // `depth`, left unset so sub-groups are not pulled in implicitly —
            // opening a group should show that group.
            if !filter.groupIds.isEmpty {
                sceneFilter["groups"] = [
                    "value": filter.groupIds,
                    "modifier": filter.groupModifier.rawValue
                ]
            }

            // Studios filter
            if !filter.studioIds.isEmpty {
                sceneFilter["studios"] = [
                    "value": filter.studioIds,
                    "modifier": filter.studioModifier.rawValue
                ]
            }

            // Performers filter
            if !filter.performerIds.isEmpty {
                sceneFilter["performers"] = [
                    "value": filter.performerIds,
                    "modifier": filter.performerModifier.rawValue
                ]
            }

            if !sceneFilter.isEmpty {
                variables["scene_filter"] = sceneFilter
            }
        }

        let response: FindScenesResponse = try await self.query(graphQLQuery, variables: variables)
        return response.findScenes
    }

    struct FindSceneByIDResponse: Decodable {
        let findScene: StashScene?
    }

    /// Fetch a single scene by its Stash ID (used by the `hypnos://scene?id=`
    /// callback). Mirrors the field selection of `findScenes` so the result can be
    /// mapped by the same `GraphQLVideoSource.makeGalleryVideo(from:allowTranscoding:)`.
    func findScene(id: String) async throws -> StashScene? {
        let graphQLQuery = """
        query FindScene($id: ID!) {
            findScene(id: $id) {
                id
                title
                details
                date
                rating100
                o_counter
                paths {
                    screenshot
                    stream
                    preview
                }
                files {
                    path
                    width
                    height
                    duration
                }
                tags {
                    id
                    name
                }
                sceneStreams {
                    url
                    mime_type
                    label
                }
            }
        }
        """
        let response: FindSceneByIDResponse = try await self.query(graphQLQuery, variables: ["id": id])
        return response.findScene
    }

    // MARK: - Image Mutations

    struct ImageUpdateResponse: Decodable {
        let imageUpdate: ImageUpdateResult
    }

    struct ImageUpdateResult: Decodable {
        let id: String
        let rating100: Int?
    }

    func updateImageRating(imageId: String, rating100: Int?) async throws {
        let mutation = """
        mutation ImageUpdate($input: ImageUpdateInput!) {
            imageUpdate(input: $input) {
                id
                rating100
            }
        }
        """

        var input: [String: Any] = ["id": imageId]
        if let rating100 = rating100 {
            input["rating100"] = rating100
        } else {
            input["rating100"] = NSNull()
        }

        let _: ImageUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    struct ImageIncrementOResponse: Decodable {
        let imageIncrementO: Int
    }

    struct ImageDecrementOResponse: Decodable {
        let imageDecrementO: Int
    }

    func incrementImageOCounter(imageId: String) async throws -> Int {
        let mutation = """
        mutation ImageIncrementO($id: ID!) {
            imageIncrementO(id: $id)
        }
        """

        let response: ImageIncrementOResponse = try await self.query(mutation, variables: ["id": imageId])
        return response.imageIncrementO
    }

    func decrementImageOCounter(imageId: String) async throws -> Int {
        let mutation = """
        mutation ImageDecrementO($id: ID!) {
            imageDecrementO(id: $id)
        }
        """

        let response: ImageDecrementOResponse = try await self.query(mutation, variables: ["id": imageId])
        return response.imageDecrementO
    }

    // MARK: - Scene/Video Mutations

    struct SceneUpdateResponse: Decodable {
        let sceneUpdate: SceneUpdateResult
    }

    struct SceneUpdateResult: Decodable {
        let id: String
        let rating100: Int?
    }

    func updateSceneRating(sceneId: String, rating100: Int?) async throws {
        let mutation = """
        mutation SceneUpdate($input: SceneUpdateInput!) {
            sceneUpdate(input: $input) {
                id
                rating100
            }
        }
        """

        var input: [String: Any] = ["id": sceneId]
        if let rating100 = rating100 {
            input["rating100"] = rating100
        } else {
            input["rating100"] = NSNull()
        }

        let _: SceneUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    struct SceneIncrementOResponse: Decodable {
        let sceneIncrementO: Int
    }

    struct SceneDecrementOResponse: Decodable {
        let sceneDecrementO: Int
    }

    func incrementSceneOCounter(sceneId: String) async throws -> Int {
        let mutation = """
        mutation SceneIncrementO($id: ID!) {
            sceneIncrementO(id: $id)
        }
        """

        let response: SceneIncrementOResponse = try await self.query(mutation, variables: ["id": sceneId])
        return response.sceneIncrementO
    }

    func decrementSceneOCounter(sceneId: String) async throws -> Int {
        let mutation = """
        mutation SceneDecrementO($id: ID!) {
            sceneDecrementO(id: $id)
        }
        """

        let response: SceneDecrementOResponse = try await self.query(mutation, variables: ["id": sceneId])
        return response.sceneDecrementO
    }

    // MARK: - Image Detail Query

    private struct FindImageResponse: Decodable {
        let findImage: StashImageDetail?
    }

    struct StashImageDetail: Decodable {
        let id: String
        let title: String?
        let code: String?
        let date: String?
        let details: String?
        let photographer: String?
        let rating100: Int?
        let o_counter: Int?
        let organized: Bool
        let urls: [String]?
        let created_at: String?
        let updated_at: String?
        let visual_files: [StashImageDetailFile]?
        let studio: StashStudioRef?
        let performers: [StashPerformerRef]?
        let tags: [StashTagRef]?
        let galleries: [StashGalleryRef]?
    }

    struct StashImageDetailFile: Decodable {
        let typename: String?
        let id: String?
        let path: String?
        let size: Int64?
        let format: String?
        let width: Int?
        let height: Int?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, path, size, format, width, height
        }
    }

    struct StashStudioRef: Decodable {
        let id: String
        let name: String
    }

    struct StashPerformerRef: Decodable {
        let id: String
        let name: String
    }

    struct StashTagRef: Decodable {
        let id: String
        let name: String
    }

    struct StashGalleryRef: Decodable {
        let id: String
        let title: String?
    }

    struct StashGroupRef: Decodable {
        let group: StashGroupInfo
    }

    struct StashGroupInfo: Decodable {
        let id: String
        let name: String
    }

    func fetchImageDetail(id: String) async throws -> ImageDetail {
        let graphQLQuery = """
        query FindImage($id: ID!) {
            findImage(id: $id) {
                id
                title
                code
                date
                details
                photographer
                rating100
                o_counter
                organized
                urls
                created_at
                updated_at
                visual_files {
                    __typename
                    ... on ImageFile {
                        id
                        path
                        size
                        format
                        width
                        height
                    }
                    ... on VideoFile {
                        id
                        path
                        size
                        format
                        width
                        height
                    }
                }
                studio {
                    id
                    name
                }
                performers {
                    id
                    name
                }
                tags {
                    id
                    name
                }
                galleries {
                    id
                    title
                }
            }
        }
        """

        let response: FindImageResponse = try await self.query(graphQLQuery, variables: ["id": id])
        guard let image = response.findImage else {
            throw StashAPIError.noData
        }

        let file = image.visual_files?.first
        return ImageDetail(
            id: image.id,
            title: image.title,
            code: image.code,
            date: image.date,
            details: image.details,
            photographer: image.photographer,
            rating100: image.rating100,
            oCounter: image.o_counter,
            organized: image.organized,
            urls: image.urls ?? [],
            filePath: file?.path,
            fileSize: file?.size,
            format: file?.format,
            width: file?.width,
            height: file?.height,
            studio: image.studio.map { MediaStudio(id: $0.id, name: $0.name) },
            performers: image.performers?.map { MediaPerformer(id: $0.id, name: $0.name) } ?? [],
            tags: image.tags?.map { MediaTag(id: $0.id, name: $0.name) } ?? [],
            galleries: image.galleries?.map { MediaGalleryRef(id: $0.id, title: $0.title) } ?? [],
            createdAt: image.created_at,
            updatedAt: image.updated_at
        )
    }

    // MARK: - Scene Detail Query

    private struct FindSceneResponse: Decodable {
        let findScene: StashSceneDetail?
    }

    struct StashSceneDetail: Decodable {
        let id: String
        let title: String?
        let code: String?
        let date: String?
        let details: String?
        let director: String?
        let rating100: Int?
        let o_counter: Int?
        let organized: Bool
        let urls: [String]?
        let created_at: String?
        let updated_at: String?
        let play_count: Int?
        let play_duration: Double?
        let files: [StashSceneDetailFile]?
        let studio: StashStudioRef?
        let performers: [StashPerformerRef]?
        let tags: [StashTagRef]?
        let galleries: [StashGalleryRef]?
        let groups: [StashGroupRef]?
    }

    struct StashSceneDetailFile: Decodable {
        let id: String?
        let path: String?
        let size: Int64?
        let format: String?
        let width: Int?
        let height: Int?
        let duration: Double?
        let video_codec: String?
        let audio_codec: String?
        let frame_rate: Double?
        let bit_rate: Int?
    }

    func fetchSceneDetail(id: String) async throws -> SceneDetail {
        let graphQLQuery = """
        query FindScene($id: ID!) {
            findScene(id: $id) {
                id
                title
                code
                date
                details
                director
                rating100
                o_counter
                organized
                urls
                created_at
                updated_at
                play_count
                play_duration
                files {
                    id
                    path
                    size
                    format
                    width
                    height
                    duration
                    video_codec
                    audio_codec
                    frame_rate
                    bit_rate
                }
                studio {
                    id
                    name
                }
                performers {
                    id
                    name
                }
                tags {
                    id
                    name
                }
                galleries {
                    id
                    title
                }
                groups {
                    group {
                        id
                        name
                    }
                }
            }
        }
        """

        let response: FindSceneResponse = try await self.query(graphQLQuery, variables: ["id": id])
        guard let scene = response.findScene else {
            throw StashAPIError.noData
        }

        let file = scene.files?.first
        return SceneDetail(
            id: scene.id,
            title: scene.title,
            code: scene.code,
            date: scene.date,
            details: scene.details,
            director: scene.director,
            rating100: scene.rating100,
            oCounter: scene.o_counter,
            organized: scene.organized,
            urls: scene.urls ?? [],
            filePath: file?.path,
            fileSize: file?.size,
            format: file?.format,
            width: file?.width,
            height: file?.height,
            duration: file?.duration,
            videoCodec: file?.video_codec,
            audioCodec: file?.audio_codec,
            frameRate: file?.frame_rate,
            bitrate: file?.bit_rate,
            studio: scene.studio.map { MediaStudio(id: $0.id, name: $0.name) },
            performers: scene.performers?.map { MediaPerformer(id: $0.id, name: $0.name) } ?? [],
            tags: scene.tags?.map { MediaTag(id: $0.id, name: $0.name) } ?? [],
            galleries: scene.galleries?.map { MediaGalleryRef(id: $0.id, title: $0.title) } ?? [],
            groups: scene.groups?.map { MediaGroupRef(id: $0.group.id, name: $0.group.name) } ?? [],
            playCount: scene.play_count,
            playDuration: scene.play_duration,
            createdAt: scene.created_at,
            updatedAt: scene.updated_at
        )
    }

    // MARK: - Full Image Update

    func updateImage(id: String, title: String? = nil, code: String? = nil, date: String? = nil,
                     details: String? = nil, photographer: String? = nil, rating100: Int? = nil,
                     studioId: String? = nil, performerIds: [String]? = nil, tagIds: [String]? = nil,
                     galleryIds: [String]? = nil, urls: [String]? = nil, organized: Bool? = nil) async throws {
        let mutation = """
        mutation ImageUpdate($input: ImageUpdateInput!) {
            imageUpdate(input: $input) {
                id
            }
        }
        """

        var input: [String: Any] = ["id": id]
        if let title { input["title"] = title }
        if let code { input["code"] = code }
        if let date { input["date"] = date }
        if let details { input["details"] = details }
        if let photographer { input["photographer"] = photographer }
        if let rating100 { input["rating100"] = rating100 }
        if let studioId { input["studio_id"] = studioId }
        if let performerIds { input["performer_ids"] = performerIds }
        if let tagIds { input["tag_ids"] = tagIds }
        if let galleryIds { input["gallery_ids"] = galleryIds }
        if let urls { input["urls"] = urls }
        if let organized { input["organized"] = organized }

        let _: ImageUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    // MARK: - Full Scene Update

    func updateScene(id: String, title: String? = nil, code: String? = nil, date: String? = nil,
                     details: String? = nil, director: String? = nil, rating100: Int? = nil,
                     studioId: String? = nil, performerIds: [String]? = nil, tagIds: [String]? = nil,
                     galleryIds: [String]? = nil, urls: [String]? = nil, organized: Bool? = nil) async throws {
        let mutation = """
        mutation SceneUpdate($input: SceneUpdateInput!) {
            sceneUpdate(input: $input) {
                id
            }
        }
        """

        var input: [String: Any] = ["id": id]
        if let title { input["title"] = title }
        if let code { input["code"] = code }
        if let date { input["date"] = date }
        if let details { input["details"] = details }
        if let director { input["director"] = director }
        if let rating100 { input["rating100"] = rating100 }
        if let studioId { input["studio_id"] = studioId }
        if let performerIds { input["performer_ids"] = performerIds }
        if let tagIds { input["tag_ids"] = tagIds }
        if let galleryIds { input["gallery_ids"] = galleryIds }
        if let urls { input["urls"] = urls }
        if let organized { input["organized"] = organized }

        let _: SceneUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    // MARK: - Delete Operations

    private struct DestroyResponse: Decodable {
        // imageDestroy/sceneDestroy return Boolean
    }

    private struct ImageDestroyResponse: Decodable {
        let imageDestroy: Bool
    }

    private struct SceneDestroyResponse: Decodable {
        let sceneDestroy: Bool
    }

    private struct ImagesDestroyResponse: Decodable {
        let imagesDestroy: Bool
    }

    private struct ScenesDestroyResponse: Decodable {
        let scenesDestroy: Bool
    }

    func destroyImage(id: String, deleteFile: Bool = false, deleteGenerated: Bool = true) async throws {
        let mutation = """
        mutation ImageDestroy($input: ImageDestroyInput!) {
            imageDestroy(input: $input)
        }
        """

        let input: [String: Any] = [
            "id": id,
            "delete_file": deleteFile,
            "delete_generated": deleteGenerated
        ]

        let _: ImageDestroyResponse = try await self.query(mutation, variables: ["input": input])
    }

    func destroyScene(id: String, deleteFile: Bool = false, deleteGenerated: Bool = true) async throws {
        let mutation = """
        mutation SceneDestroy($input: SceneDestroyInput!) {
            sceneDestroy(input: $input)
        }
        """

        let input: [String: Any] = [
            "id": id,
            "delete_file": deleteFile,
            "delete_generated": deleteGenerated
        ]

        let _: SceneDestroyResponse = try await self.query(mutation, variables: ["input": input])
    }

    func destroyImages(ids: [String], deleteFile: Bool = false, deleteGenerated: Bool = true) async throws {
        let mutation = """
        mutation ImagesDestroy($input: ImagesDestroyInput!) {
            imagesDestroy(input: $input)
        }
        """

        let input: [String: Any] = [
            "ids": ids,
            "delete_file": deleteFile,
            "delete_generated": deleteGenerated
        ]

        let _: ImagesDestroyResponse = try await self.query(mutation, variables: ["input": input])
    }

    func destroyScenes(ids: [String], deleteFile: Bool = false, deleteGenerated: Bool = true) async throws {
        let mutation = """
        mutation ScenesDestroy($input: ScenesDestroyInput!) {
            scenesDestroy(input: $input)
        }
        """

        let input: [String: Any] = [
            "ids": ids,
            "delete_file": deleteFile,
            "delete_generated": deleteGenerated
        ]

        let _: ScenesDestroyResponse = try await self.query(mutation, variables: ["input": input])
    }
}

/// Errors that can occur when using the Stash API
enum StashAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case graphQLErrors([GraphQLError])
    case noData
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .graphQLErrors(let errors):
            return "GraphQL errors: \(errors.map { $0.message }.joined(separator: ", "))"
        case .noData:
            return "No data in response"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
