import Foundation

struct LiveAssetDownloadPlan: Sendable {
    let liveAsset: LiveModelAsset
    let files: [DownloadFile]
    let listingHost: String

    var totalBytes: Int64? {
        var total: Int64 = 0
        for file in files {
            guard let expectedSize = file.expectedSize else { return nil }
            total += expectedSize
        }
        return total
    }

    func downloadAsset(
        destinationDirectory: URL,
        preservesWorkspaceOnCompletion: Bool = false
    ) -> DownloadAsset {
        DownloadAsset(
            id: liveAsset.id,
            displayName: liveAsset.displayName,
            destinationDirectory: destinationDirectory,
            files: files,
            preservesWorkspaceOnCompletion: preservesWorkspaceOnCompletion
        )
    }
}

enum LiveDownloadPlanner {
    private static let hosts = [
        "hf-mirror.com",
        "huggingface.co"
    ]
    private static let probeByteLimit = 256 * 1024
    private static let probeTimeout: TimeInterval = 8

    static func makePlans(for assets: [LiveModelAsset]) async throws -> [LiveAssetDownloadPlan] {
        var plans: [LiveAssetDownloadPlan] = []
        for asset in assets {
            plans.append(try await makePlan(for: asset))
        }
        return plans
    }

    static func makePlan(for asset: LiveModelAsset) async throws -> LiveAssetDownloadPlan {
        var lastError: Error?

        for host in hosts {
            do {
                let repositoryFiles = try await fetchTree(host: host, repo: asset.repositoryID)
                    .filter { LiveModelDefinition.shouldDownload($0.path, for: asset) }
                    .sorted { $0.path < $1.path }

                try validateRequiredFiles(asset, repositoryFiles: repositoryFiles)

                guard !repositoryFiles.isEmpty else {
                    throw DownloadFailure.invalidResponse("\(asset.id) has no downloadable files")
                }

                let sourceOrder = await probeSourceOrder(for: asset, sampleFile: repositoryFiles[0].path)
                let downloadFiles = repositoryFiles.map { repositoryFile in
                    DownloadFile(
                        relativePath: repositoryFile.path,
                        expectedSize: normalizedExpectedSize(repositoryFile.size),
                        sources: downloadSources(for: asset, file: repositoryFile.path, sourceOrder: sourceOrder)
                    )
                }

                print("[LiveDL] \(host): \(asset.id) planned \(downloadFiles.count) files")
                return LiveAssetDownloadPlan(
                    liveAsset: asset,
                    files: downloadFiles,
                    listingHost: host
                )
            } catch {
                lastError = error
                print("[LiveDL] \(host) tree API failed for \(asset.id): \(error.localizedDescription)")
            }
        }

        throw lastError ?? DownloadFailure.invalidResponse("Unable to list \(asset.id)")
    }

    private static func fetchTree(host: String, repo: String) async throws -> [RepositoryFile] {
        do {
            let files = try await fetchTreeRecursiveQuery(host: host, repo: repo)
            if !files.isEmpty {
                return files
            }
        } catch {
            print("[LiveDL] \(host) recursive tree API unavailable for \(repo): \(error.localizedDescription)")
        }
        return try await fetchTreeByWalkingDirectories(host: host, repo: repo, path: "")
    }

    private static func fetchTreeRecursiveQuery(host: String, repo: String) async throws -> [RepositoryFile] {
        guard let url = URL(string: "https://\(host)/api/models/\(repo)/tree/main?recursive=true") else {
            throw DownloadFailure.invalidURL("https://\(host)/api/models/\(repo)/tree/main?recursive=true")
        }

        let items = try await fetchTreeItems(url: url)
        return items.compactMap { item in
            guard item.type == "file" else { return nil }
            return RepositoryFile(path: item.path, size: item.size)
        }
    }

    private static func fetchTreeByWalkingDirectories(host: String, repo: String, path: String) async throws -> [RepositoryFile] {
        let urlPath = path.isEmpty
            ? "https://\(host)/api/models/\(repo)/tree/main"
            : "https://\(host)/api/models/\(repo)/tree/main/\(encodedPath(path))"

        guard let url = URL(string: urlPath) else {
            throw DownloadFailure.invalidURL(urlPath)
        }

        let items = try await fetchTreeItems(url: url)
        var files: [RepositoryFile] = []
        for item in items {
            if item.type == "file" {
                files.append(RepositoryFile(path: item.path, size: item.size))
            } else if item.type == "directory" {
                let subFiles = try await fetchTreeByWalkingDirectories(host: host, repo: repo, path: item.path)
                files.append(contentsOf: subFiles)
            }
        }
        return files
    }

    private static func fetchTreeItems(url: URL) async throws -> [TreeItem] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadFailure.invalidResponse("Missing HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadFailure.httpStatus(http.statusCode)
        }

        return try JSONDecoder().decode([TreeItem].self, from: data)
    }

    private static func validateRequiredFiles(
        _ asset: LiveModelAsset,
        repositoryFiles: [RepositoryFile]
    ) throws {
        let missing = asset.requiredFiles.filter { required in
            !repositoryContains(required, in: repositoryFiles)
        }
        guard missing.isEmpty else {
            throw DownloadFailure.invalidResponse(
                "\(asset.id) repository schema changed; missing required files: \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func repositoryContains(_ requiredPath: String, in files: [RepositoryFile]) -> Bool {
        if files.contains(where: { $0.path == requiredPath }) {
            return true
        }
        let directoryPrefix = requiredPath.hasSuffix("/") ? requiredPath : "\(requiredPath)/"
        return files.contains { $0.path.hasPrefix(directoryPrefix) }
    }

    private static func downloadSources(
        for asset: LiveModelAsset,
        file: String,
        sourceOrder: [String] = hosts
    ) -> [DownloadFile.Source] {
        sourceOrder.enumerated().compactMap { index, host in
            let encodedFile = encodedPath(file)
            guard let url = URL(string: "https://\(host)/\(asset.repositoryID)/resolve/main/\(encodedFile)") else {
                return nil
            }
            return DownloadFile.Source(label: host, url: url, priority: index)
        }
    }

    private static func probeSourceOrder(for asset: LiveModelAsset, sampleFile: String) async -> [String] {
        let sources = downloadSources(for: asset, file: sampleFile)
        var results: [SourceProbeResult] = []

        await withTaskGroup(of: SourceProbeResult?.self) { group in
            for source in sources {
                group.addTask {
                    await probe(source: source)
                }
            }

            for await result in group {
                if let result {
                    results.append(result)
                }
            }
        }

        guard !results.isEmpty else { return hosts }

        let ranked = results
            .sorted {
                if $0.bytesPerSecond == $1.bytesPerSecond {
                    return $0.label < $1.label
                }
                return $0.bytesPerSecond > $1.bytesPerSecond
            }
            .map(\.label)
        let remaining = hosts.filter { !ranked.contains($0) }
        let order = ranked + remaining
        print("[LiveDL] \(asset.id) source probe order: \(order.joined(separator: " -> "))")
        return order
    }

    private static func probe(source: DownloadFile.Source) async -> SourceProbeResult? {
        var request = URLRequest(url: source.url)
        request.setValue("bytes=0-\(probeByteLimit - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = probeTimeout

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            var received = 0
            for try await _ in bytes {
                received += 1
                if received >= probeByteLimit {
                    break
                }
            }

            guard received > 0 else { return nil }
            let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
            return SourceProbeResult(
                label: source.label,
                bytesPerSecond: Double(received) / elapsed
            )
        } catch {
            return nil
        }
    }

    private static func encodedPath(_ path: String) -> String {
        path.components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
    }

    private static func normalizedExpectedSize(_ size: Int64?) -> Int64? {
        guard let size, size > 0 else { return nil }
        return size
    }

    private struct TreeItem: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private struct RepositoryFile: Sendable {
        let path: String
        let size: Int64?
    }

    private struct SourceProbeResult: Sendable {
        let label: String
        let bytesPerSecond: Double
    }
}
