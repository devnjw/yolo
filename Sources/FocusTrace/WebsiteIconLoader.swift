import Foundation
import ImageIO
import UniformTypeIdentifiers
import TrackingCore

/// Reads public homepage icon metadata without browser cookies or visit history.
actor WebsiteIconLoader {
    static let shared = WebsiteIconLoader()
    private let session: URLSession
    private let cacheDirectory: URL
    private var pending: [String: Task<Data?, Never>] = [:]
    private var results: [String: Data] = [:]
    private var retryAfter: [String: Date] = [:]
    private let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private struct Icon { let png: Data; let pixels: Int }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusTrace/WebsiteIcons", isDirectory: true)
    }

    func icon(for identifier: String) async -> Data? {
        guard let domain = Source.normalizedDomain(identifier) else { return nil }
        if let retry = retryAfter[domain], retry > Date() { return results[domain] }
        if let task = pending[domain] { return await task.value }
        let task = Task { await self.load(domain: domain) }
        pending[domain] = task
        let result = await task.value
        pending[domain] = nil
        results[domain] = result
        let pixels = result.flatMap(Self.thumbnail)?.pixels ?? 0
        retryAfter[domain] = Date().addingTimeInterval(pixels >= 64 ? lifetime : 60 * 60)
        return result
    }

    private func load(domain: String) async -> Data? {
        // A new cache generation upgrades old 16px favicons automatically.
        let directory = cacheDirectory.appendingPathComponent("v2", isDirectory: true)
        let file = directory.appendingPathComponent(domain + ".png")
        let current = (try? Data(contentsOf: file)).flatMap(Self.thumbnail)
        let legacy = current == nil ? (try? Data(contentsOf: cacheDirectory.appendingPathComponent(domain + ".png"))).flatMap(Self.thumbnail) : nil
        var best = current ?? legacy
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let current, let modified, Date().timeIntervalSince(modified) < (current.pixels >= 64 ? lifetime : 60 * 60) {
            return current.png
        }

        let hosts = [domain, "www." + domain]
        var candidates: [URL] = []
        for host in hosts {
            guard let url = URL(string: "https://\(host)/"),
                  let page = await download(url, htmlHead: true) else { continue }
            let html = String(decoding: page.data, as: UTF8.self)
            candidates = WebsiteIconCandidates.urls(in: html, relativeTo: page.url)
            if !candidates.isEmpty { break }
        }
        // Bound metadata candidates and use conventional files when metadata is absent.
        candidates = Array(candidates.prefix(6))
        for path in ["apple-touch-icon.png", "favicon.ico"] {
            for host in hosts {
                if let url = URL(string: "https://\(host)/\(path)") { candidates.append(url) }
            }
        }
        var seen = Set<URL>()
        var downloaded = false
        for url in candidates where seen.insert(url).inserted {
            guard let response = await download(url), let icon = Self.thumbnail(response.data) else { continue }
            if icon.pixels >= (best?.pixels ?? 0) { best = icon; downloaded = true }
            if icon.pixels >= 64 { break }
        }
        if downloaded, let best {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try best.png.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { /* Icon caching must never interfere with measurement. */ }
        }
        return best?.png
    }

    private func download(_ url: URL, htmlHead: Bool = false) async -> (data: Data, url: URL)? {
        let limit = htmlHead ? 256 * 1024 : 2 * 1024 * 1024
        do {
            var request = URLRequest(url: url)
            // CFNetwork's default agent can be redirected to low-resolution mobile sites.
            request.setValue("FocusTrace/0.2 (macOS; Desktop)", forHTTPHeaderField: "User-Agent")
            request.setValue(htmlHead ? "text/html" : "image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let finalURL = response.url, finalURL.scheme == "https",
                  htmlHead || response.expectedContentLength <= limit else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit { return htmlHead ? (data, finalURL) : nil }
                data.append(byte)
                // Stop once the head is found; homepage bytes are never persisted.
                if htmlHead, data.count % 4096 == 0,
                   String(decoding: data, as: UTF8.self).range(of: "</head>", options: .caseInsensitive) != nil { break }
            }
            return (data, finalURL)
        } catch { return nil }
    }

    private static func thumbnail(_ data: Data) -> Icon? {
        guard data.count <= 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // ICO files can contain several resolutions. Never blindly use the first frame.
        var bestIndex = 0, bestSize = 0
        for index in 0..<min(CGImageSourceGetCount(source), 32) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192 else { continue }
            let size = min(width, height)
            if size > bestSize { bestIndex = index; bestSize = size }
        }
        guard bestSize > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, bestIndex, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(128, bestSize),
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Icon(png: output as Data, pixels: min(image.width, image.height))
    }
}
