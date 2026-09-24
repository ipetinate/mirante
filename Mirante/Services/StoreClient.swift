import Foundation

/// Errors surfaced by `StoreClient`.
enum StoreError: LocalizedError {
    case notConfigured
    case missingToken
    case server(Int, String)
    case badResponse
    case malformedManifest
    case notFound

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "The store isn't configured yet. Set the repository owner and publisher handle in the Store settings.")
        case .missingToken:
            return String(localized: "A GitHub token is required to publish. Add one in the Store settings (only needed for publishing, not for browsing).")
        case .server(let code, let message):
            return String(localized: "GitHub responded \(code). \(message)")
        case .badResponse:
            return String(localized: "The store returned an unexpected response.")
        case .malformedManifest:
            return String(localized: "The store's index.json could not be read.")
        case .notFound:
            return String(localized: "The store repository was not found, or no faces are published yet.")
        }
    }
}

/// Talks to a GitHub-hosted watchface store. Reading (manifest, binaries,
/// previews) works against the public raw endpoints without auth; publishing
/// uses the contents API with a token stored in `StoreConfigStore`.
struct StoreClient {
    /// Injectable so tests can stub the network. Defaults to the shared one.
    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Structure

    /// A store is a GitHub repository on branch `branch` with this layout:
    ///
    ///     index.json                      # StoreManifest (kept in sync here)
    ///     faces/<publisher>/<slug>/
    ///         face.fprj                   # source project, written by the app
    ///         metadata.json               # StoreFace entry, written by the app
    ///         preview.png                 # cover, rendered by the app
    ///         face.bin                    # compiled binary, written by CI
    ///
    /// `index.json` is the single source of truth the app reads.

    // MARK: - URLs

    private func rawURL(_ config: StoreConfig, path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(config.owner)/\(config.repository)/\(config.branch)/\(path)")!
    }

    private func apiContentsURL(_ config: StoreConfig, path: String) -> URL {
        URL(string: "https://api.github.com/repos/\(config.owner)/\(config.repository)/contents/\(path)")!
    }

    // MARK: - Fetching (public)

    /// Downloads and decodes the store manifest `index.json`.
    func fetchManifest(_ config: StoreConfig) async throws -> StoreManifest {
        var request = URLRequest(url: rawURL(config, path: "index.json"))
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(from: request.url!)
        guard let http = response as? HTTPURLResponse else { throw StoreError.badResponse }
        if http.statusCode == 404 { throw StoreError.notFound }
        guard (200...299).contains(http.statusCode) else {
            throw StoreError.server(http.statusCode, http.statusCode == 403
                ? "Rate-limited or blocked by GitHub."
                : HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        guard let manifest = try? StoreJSON.decoder.decode(StoreManifest.self, from: data) else {
            throw StoreError.malformedManifest
        }
        return manifest
    }

    /// Downloads a binary (compiled face) or preview from a raw path.
    func download(path: String, config: StoreConfig) async throws -> Data {
        let url = rawURL(config, path: path)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StoreError.badResponse
        }
        return data
    }

    // MARK: - Publishing (authenticated)

    /// Publishes a face: writes the source `.fprj`, `metadata.json` and
    /// `preview.png` into `faces/<publisher>/<slug>/`, then updates
    /// `index.json` so the face shows up in the app immediately with
    /// `compiled: false` (the store CI compiles `face.bin` and flips it).
    func publish(
        face: StoreFace,
        fprjData: Data,
        metadataData: Data,
        previewData: Data,
        config: StoreConfig,
        token: String
    ) async throws {
        guard config.isConfigured else { throw StoreError.notConfigured }
        let fprjPath = "\(face.sourcePath)"
        let metaPath = "\(face.directory)/metadata.json"
        let previewPath = face.previewPath ?? "\(face.directory)/preview.png"

        // Write the three derived files first, then the manifest.
        try await writeFile(path: fprjPath, data: fprjData, message: "Publish \(face.name) — \(face.version) (source)", config: config, token: token)
        try await writeFile(path: metaPath, data: metadataData, message: "Publish \(face.name) — \(face.version) (metadata)", config: config, token: token)
        try await writeFile(path: previewPath, data: previewData, message: "Publish \(face.name) — \(face.version) (preview)", config: config, token: token)

        var manifest = (try? await fetchManifest(config)) ?? StoreManifest(schemaVersion: 1, generatedAt: Date(), publisher: nil, faces: [])
        manifest.faces.removeAll { $0.id == face.id }
        manifest.faces.append(face)
        manifest.generatedAt = Date()
        manifest.publisher = StoreAuthor(handle: config.publisherHandle, name: config.publisherName)
        manifest.faces.sort { $0.updatedAt > $1.updatedAt }
        let manifestData = try StoreJSON.encoder.encode(manifest)
        try await writeFile(path: "index.json", data: manifestData, message: "Publish \(face.name) — update index.json", config: config, token: token)
    }

    /// Creates or updates one file in the repository via the contents API.
    private func writeFile(path: String, data: Data, message: String, config: StoreConfig, token: String) async throws {
        var body: [String: Any] = [
            "message": message,
            "branch": config.branch,
            "content": data.base64EncodedString(),
        ]
        // Updating an existing path requires its current sha.
        if let sha = try? await existingSHA(path: path, config: config, token: token) {
            body["sha"] = sha
        }
        var request = URLRequest(url: apiContentsURL(config, path: path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StoreError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw StoreError.server(http.statusCode, String(data: (try? await session.data(for: request).0) ?? Data(), encoding: .utf8) ?? "")
        }
    }

    private func existingSHA(path: String, config: StoreConfig, token: String) async throws -> String? {
        var request = URLRequest(url: apiContentsURL(config, path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else { return nil }
        return sha
    }
}

extension StoreConfig {
    /// A stable, filesystem-safe slug for a face.
    var publisherDirectory: String {
        slug(publisherHandle)
    }
}

extension StoreFace {
    /// Creates a `StoreFace` (the `metadata.json` payload and `index.json`
    /// record) for a project about to be published, laying it out under
    /// `faces/<publisher>/<slug>/`.
    static func make(
        from project: WatchFaceProject,
        config: StoreConfig,
        version: String,
        description: String,
        tags: [String]
    ) -> StoreFace {
        let directory = "faces/\(slug(config.publisherHandle))/\(slug(project.name))"
        return StoreFace(
            id: slug(project.name),
            name: project.name,
            description: description,
            deviceID: project.deviceID,
            tags: tags,
            version: version,
            updatedAt: Date(),
            author: StoreAuthor(handle: config.publisherHandle, name: config.publisherName.isEmpty ? config.publisherHandle : config.publisherName),
            compiled: false,
            binarySize: nil,
            sourcePath: "\(directory)/face.fprj",
            binaryPath: "\(directory)/face.bin",
            previewPath: "\(directory)/preview.png"
        )
    }
}

/// Slugifies an arbitrary string into a safe path component.
func slug(_ input: String) -> String {
    let allowed = input.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
    let trimmed = allowed.components(separatedBy: "-").filter { !$0.isEmpty }.joined(separator: "-")
    return trimmed.isEmpty ? "face" : trimmed
}