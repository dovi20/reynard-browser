//
//  SiteIconStore.swift
//  Reynard
//
//  Icons for site apps: the app's own icon for the loading screen, and one icon
//  per site for the hub switcher. Icons of built-in sites are bundled at
//  packaging time (SiteIcons/<id>.png); icons of sites added on the device are
//  downloaded once and cached.
//

import UIKit

enum SiteIconStore {
    private static let bundleFolder = "SiteIcons"
    private static let minimumIconSide: CGFloat = 32
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static var memoryCache: [String: UIImage] = [:]
    private static var fetchingIDs: Set<String> = []
    private static var failedIDs: Set<String> = []

    // MARK: - App Icon

    static let appIcon: UIImage? = {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(bundleFolder, isDirectory: true)
            .appendingPathComponent("app.png")
        if let image = UIImage(contentsOfFile: bundled.path) {
            return image
        }

        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in files.reversed() {
            if let image = UIImage(named: name) {
                return image
            }
        }
        return nil
    }()

    // MARK: - Site Icons

    static func cachedIcon(for site: SiteConfiguration) -> UIImage? {
        if let image = memoryCache[site.id] {
            return image
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent(bundleFolder, isDirectory: true)
            .appendingPathComponent("\(site.id).png")
        if let image = UIImage(contentsOfFile: bundled.path) {
            memoryCache[site.id] = image
            return image
        }

        if let cacheURL = cacheURL(for: site), let image = UIImage(contentsOfFile: cacheURL.path) {
            memoryCache[site.id] = image
            return image
        }
        return nil
    }

    static func icon(for site: SiteConfiguration) -> UIImage {
        return cachedIcon(for: site) ?? monogram(for: site)
    }

    static func fetchIconIfNeeded(for site: SiteConfiguration, completion: @escaping () -> Void) {
        guard cachedIcon(for: site) == nil,
              !fetchingIDs.contains(site.id),
              !failedIDs.contains(site.id) else {
            return
        }
        guard #available(iOS 15.0, *) else {
            return
        }
        fetchingIDs.insert(site.id)

        Task {
            let image = await downloadIcon(for: site)
            fetchingIDs.remove(site.id)
            guard let image else {
                // Not retried until the next launch
                failedIDs.insert(site.id)
                return
            }
            memoryCache[site.id] = image
            if let cacheURL = cacheURL(for: site), let data = image.pngData() {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: cacheURL)
            }
            completion()
        }
    }

    static func monogram(for site: SiteConfiguration, side: CGFloat = 120) -> UIImage {
        let letter = String(site.name.prefix(1)).uppercased()
        let hue = CGFloat(abs(site.host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 })) / 360
        let color = UIColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1)
        let size = CGSize(width: side, height: side)

        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.5, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let textSize = text.size()
            text.draw(at: CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2))
        }
    }

    // MARK: - Download

    private static func cacheURL(for site: SiteConfiguration) -> URL? {
        let safeID = site.id.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleFolder, isDirectory: true)
            .appendingPathComponent("\(safeID).png")
    }

    @available(iOS 15.0, *)
    private static func downloadIcon(for site: SiteConfiguration) async -> UIImage? {
        var candidates: [URL] = []
        if let page = await fetch(site.startURL),
           let html = String(data: page.data.prefix(400_000), encoding: .utf8)
            ?? String(data: page.data.prefix(400_000), encoding: .isoLatin1) {
            candidates += iconLinks(inHTML: html, baseURL: page.url)
        }
        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.ico"] {
            if let url = URL(string: path, relativeTo: site.startURL)?.absoluteURL {
                candidates.append(url)
            }
        }

        for candidate in candidates.prefix(8) {
            guard let response = await fetch(candidate),
                  let image = UIImage(data: response.data),
                  min(image.size.width, image.size.height) * image.scale >= minimumIconSide else {
                continue
            }
            return image
        }
        return nil
    }

    @available(iOS 15.0, *)
    private static func fetch(_ url: URL) async -> (data: Data, url: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return (result.0, http.url ?? url)
    }

    private static func iconLinks(inHTML html: String, baseURL: URL) -> [URL] {
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let hrefRegex = try? NSRegularExpression(
                pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']",
                options: [.caseInsensitive]
              ) else {
            return []
        }

        let source = html as NSString
        var touchIcons: [URL] = []
        var otherIcons: [URL] = []

        for match in linkRegex.matches(in: html, options: [], range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range)
            let lowercasedTag = tag.lowercased()
            guard lowercasedTag.contains("icon"), !lowercasedTag.contains(".svg") else {
                continue
            }
            let tagSource = tag as NSString
            guard let hrefMatch = hrefRegex.firstMatch(
                in: tag,
                options: [],
                range: NSRange(location: 0, length: tagSource.length)
            ) else {
                continue
            }
            let href = tagSource.substring(with: hrefMatch.range(at: 1))
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
                continue
            }
            if lowercasedTag.contains("apple-touch-icon") {
                touchIcons.append(url)
            } else {
                otherIcons.append(url)
            }
        }
        return touchIcons + otherIcons
    }
}
