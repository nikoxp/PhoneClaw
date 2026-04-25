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
    private static let treeRequestTimeout: TimeInterval = 12

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

                let downloadFiles = repositoryFiles.map { repositoryFile in
                    DownloadFile(
                        relativePath: repositoryFile.path,
                        expectedSize: normalizedExpectedSize(repositoryFile.size),
                        sources: downloadSources(for: asset, file: repositoryFile.path)
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
        var request = URLRequest(url: url)
        request.timeoutInterval = treeRequestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
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

}
