import Foundation

/// Public homepage metadata only; no browser session or visited-page URL needed.
public enum WebsiteIconCandidates {
    public static func urls(in html: String, relativeTo pageURL: URL) -> [URL] {
        let links = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        let attributes = try! NSRegularExpression(
            pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let text = html as NSString
        var candidates: [(url: URL, size: Int, order: Int)] = []
        for link in links.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: link.range)
            let rawTag = tag as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(location: 0, length: rawTag.length)) {
                let key = rawTag.substring(with: attribute.range(at: 1)).lowercased()
                for group in 2...4 where attribute.range(at: group).location != NSNotFound {
                    values[key] = rawTag.substring(with: attribute.range(at: group))
                }
            }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { continue }
            // Raster icons work with ImageIO. SVG-only sites can still use root fallbacks.
            guard url.pathExtension.lowercased() != "svg", values["type"]?.lowercased() != "image/svg+xml" else { continue }
            let sizes = (values["sizes"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            let size = sizes.compactMap { entry -> Int? in
                let dimensions = entry.split(separator: "x")
                guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]) else { return nil }
                return min(width, height)
            }.max() ?? (rel.contains(where: { $0.hasPrefix("apple-touch-icon") }) ? 180 : 32)
            candidates.append((url, size, candidates.count))
        }
        var seen = Set<URL>()
        return candidates.sorted {
            let lhs = min($0.size, 512), rhs = min($1.size, 512)
            return lhs == rhs ? $0.order < $1.order : lhs > rhs
        }.compactMap { seen.insert($0.url).inserted ? $0.url : nil }
    }
}
