import Foundation

private final class MockDownloadURLProtocol: URLProtocol {
    static let url = URL(string: "https://download.test/model.bin")!
    static var payload = Data()
    static var rangeHeaders: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == url.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }

        let method = request.httpMethod ?? "GET"
        let etag = "\"fixture-etag\""
        let lastModified = "Fri, 24 Apr 2026 00:00:00 GMT"
        let fullLength = MockDownloadURLProtocol.payload.count

        if method == "HEAD" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "\(fullLength)",
                    "ETag": etag,
                    "Last-Modified": lastModified,
                ]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }

        var statusCode = 200
        var body = MockDownloadURLProtocol.payload
        var headers = [
            "Content-Length": "\(fullLength)",
            "ETag": etag,
            "Last-Modified": lastModified,
        ]

        if let range = request.value(forHTTPHeaderField: "Range") {
            MockDownloadURLProtocol.rangeHeaders.append(range)
            if range.hasPrefix("bytes="),
               let lowerBound = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""),
               lowerBound < fullLength {
                statusCode = 206
                body = MockDownloadURLProtocol.payload.subdata(in: lowerBound..<fullLength)
                headers["Content-Length"] = "\(body.count)"
                headers["Content-Range"] = "bytes \(lowerBound)-\(fullLength - 1)/\(fullLength)"
            } else {
                statusCode = 416
                body = Data()
                headers["Content-Length"] = "0"
            }
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct ResumableDownloaderTest {
    static func main() async throws {
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        MockDownloadURLProtocol.payload = payload
        MockDownloadURLProtocol.rangeHeaders = []

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneclaw-resumable-downloader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelsDir = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let manifestStore = DownloadManifestStore(rootDirectory: modelsDir)
        let downloader = ResumableAssetDownloader(
            manifestStore: manifestStore,
            urlSession: session
        )

        let assetID = "fixture-model"
        let fileName = "model.bin"
        let resumeOffset = 512 * 1024
        let partialURL = try await manifestStore.partialFileURL(for: assetID, relativePath: fileName)
        try payload.prefix(resumeOffset).write(to: partialURL)

        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let metadata = DownloadFileMetadata(
            sourceURL: MockDownloadURLProtocol.url,
            sourceHost: MockDownloadURLProtocol.url.host,
            etag: "\"fixture-etag\"",
            contentLength: Int64(payload.count),
            lastModified: "Fri, 24 Apr 2026 00:00:00 GMT",
            checksumSHA256: nil,
            updatedAt: now
        )
        try await manifestStore.writeManifest(
            DownloadManifest(
                assetID: assetID,
                createdAt: now,
                updatedAt: now,
                files: [
                    DownloadManifestFile(
                        relativePath: fileName,
                        state: .paused,
                        downloadedBytes: Int64(resumeOffset),
                        expectedBytes: Int64(payload.count),
                        selectedSourceLabel: "fixture",
                        metadata: metadata
                    )
                ]
            ),
            for: assetID
        )

        let asset = DownloadAsset(
            id: assetID,
            displayName: "Fixture",
            destinationDirectory: modelsDir,
            files: [
                DownloadFile(
                    relativePath: fileName,
                    expectedSize: Int64(payload.count),
                    sources: [
                        DownloadFile.Source(label: "fixture", url: MockDownloadURLProtocol.url)
                    ]
                )
            ]
        )

        _ = try await downloader.download(asset: asset)

        let finalURL = modelsDir.appendingPathComponent(fileName)
        let finalData = try Data(contentsOf: finalURL)
        precondition(finalData == payload, "Resumed download should match source payload")
        precondition(
            MockDownloadURLProtocol.rangeHeaders.contains("bytes=\(resumeOffset)-"),
            "Downloader should request a byte range when a validated partial file exists"
        )

        print("ResumableAssetDownloader tests passed")
    }
}
