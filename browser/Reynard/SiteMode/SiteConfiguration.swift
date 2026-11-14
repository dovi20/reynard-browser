//
//  SiteConfiguration.swift
//  Reynard
//
//  Site-app mode: when the app's Info.plist lists websites, the app boots straight
//  into them instead of the full browser UI. One site = a single-site app; several
//  sites (or ReynardSiteHub) = a hub with a site switcher.
//
//  Info.plist keys (injected at packaging time by tools/site/customize-app.sh):
//    ReynardSites                        String  "Name=https://a.example, https://b.example"
//    ReynardSiteHub                      Bool    show the site switcher and allow adding sites
//    ReynardSiteAllowedHosts             String  extra hosts that stay in-app, comma or space separated
//    ReynardSiteOpenExternalLinksOutside Bool    true (default): other hosts open in Safari
//    ReynardSiteURL                      String  legacy single-site key
//

import Foundation

struct SiteConfiguration {
    enum Route {
        case inApp
        case external(URL)
    }

    let id: String
    let name: String
    let startURL: URL
    let allowedHosts: [String]
    let opensExternalLinksOutside: Bool
    let isBuiltIn: Bool

    // Sign-in pages that sites open in a new window; they stay in the app
    private static let signInHosts = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "auth.openai.com",
        "auth0.com",
    ]

    private static let knownExtraHosts: [String: [String]] = [
        "claude.ai": ["claude.com", "anthropic.com"],
        "chatgpt.com": ["openai.com"],
        "chat.z.ai": ["z.ai"],
        "gemini.google.com": ["google.com"],
        "chat.deepseek.com": ["deepseek.com"],
        "chat.mistral.ai": ["mistral.ai"],
        "copilot.microsoft.com": ["microsoft.com"],
    ]

    private static let knownNames: [String: String] = [
        "claude.ai": "Claude",
        "chatgpt.com": "ChatGPT",
        "chat.z.ai": "Z.ai",
        "gemini.google.com": "Gemini",
        "chat.deepseek.com": "DeepSeek",
        "chat.mistral.ai": "Mistral",
        "copilot.microsoft.com": "Copilot",
        "grok.com": "Grok",
        "perplexity.ai": "Perplexity",
    ]

    init?(
        urlString: String,
        name: String?,
        id: String? = nil,
        extraHosts: [String] = [],
        opensExternalLinksOutside: Bool = true,
        isBuiltIn: Bool
    ) {
        var rawURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty, !rawURL.contains("://") {
            rawURL = "https://" + rawURL
        }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              rawHost.contains(".") else {
            return nil
        }

        let host = SiteConfiguration.normalizedHost(rawHost)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        self.id = id ?? host
        self.name = trimmedName.isEmpty ? SiteConfiguration.defaultName(forHost: host) : trimmedName
        self.startURL = url
        self.allowedHosts = [host]
        + (SiteConfiguration.knownExtraHosts[host] ?? [])
        + extraHosts.map { SiteConfiguration.normalizedHost($0) }.filter { !$0.isEmpty }
        self.opensExternalLinksOutside = opensExternalLinksOutside
        self.isBuiltIn = isBuiltIn
    }

    var host: String {
        return SiteConfiguration.normalizedHost(startURL.host ?? "")
    }

    static func normalizedHost(_ host: String) -> String {
        var host = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    static func defaultName(forHost host: String) -> String {
        if let known = knownNames[host] {
            return known
        }
        // chat.example.com -> Example
        let labels = host.split(separator: ".").map { String($0) }
        let generic = ["www", "chat", "app", "web", "m", "ai"]
        let candidates = labels.dropLast().filter { !generic.contains($0) }
        let label = candidates.last ?? labels.first ?? host
        return label.prefix(1).uppercased() + String(label.dropFirst())
    }

    func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func staysInApp(_ url: URL) -> Bool {
        if isInternal(url) {
            return true
        }
        guard let host = url.host?.lowercased() else {
            return false
        }
        return SiteConfiguration.signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func route(for uri: String) -> Route {
        guard let url = URL(string: uri),
              let scheme = url.scheme?.lowercased() else {
            return .inApp
        }

        switch scheme {
        case "http", "https":
            if !opensExternalLinksOutside || staysInApp(url) {
                return .inApp
            }
            return .external(url)
        case "about", "data", "blob", "javascript", "moz-extension", "resource", "chrome", "file", "view-source", "moz-icon":
            return .inApp
        default:
            // tel:, mailto:, sms:, whatsapp:, maps:, itms-apps: ...
            return .external(url)
        }
    }
}

enum SiteCatalog {
    private static let customSitesKey = "SiteCatalog.customSites"
    private static let hiddenSitesKey = "SiteCatalog.hiddenSites"

    static let builtInSites: [SiteConfiguration] = {
        let info = Bundle.main.infoDictionary ?? [:]
        let opensOutside = info["ReynardSiteOpenExternalLinksOutside"] as? Bool ?? true
        let extraHosts = splitList(info["ReynardSiteAllowedHosts"] as? String ?? "")

        var entries = splitList(info["ReynardSites"] as? String ?? "", separators: [",", "\n", ";"])
        if entries.isEmpty, let legacyURL = info["ReynardSiteURL"] as? String {
            entries = splitList(legacyURL, separators: ["\n"])
        }

        var sites: [SiteConfiguration] = []
        for entry in entries {
            let (name, urlString) = splitEntry(entry)
            guard let site = SiteConfiguration(
                urlString: urlString,
                name: name,
                extraHosts: extraHosts,
                opensExternalLinksOutside: opensOutside,
                isBuiltIn: true
            ) else {
                continue
            }
            sites.append(uniqued(site, among: sites, extraHosts: extraHosts, opensOutside: opensOutside))
        }
        return sites
    }()

    static let isSiteApp: Bool = !builtInSites.isEmpty

    static let isHub: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["ReynardSiteHub"] as? Bool ?? false) || builtInSites.count > 1
    }()

    static func sites() -> [SiteConfiguration] {
        guard isHub else {
            return builtInSites
        }
        let defaults = UserDefaults.standard
        let hidden = Set(defaults.stringArray(forKey: hiddenSitesKey) ?? [])
        var sites = builtInSites.filter { !hidden.contains($0.id) }

        let stored = defaults.array(forKey: customSitesKey) as? [[String: String]] ?? []
        for entry in stored {
            guard let urlString = entry["url"],
                  let id = entry["id"],
                  !sites.contains(where: { $0.id == id }),
                  let site = SiteConfiguration(
                    urlString: urlString,
                    name: entry["name"],
                    id: id,
                    isBuiltIn: false
                  ) else {
                continue
            }
            sites.append(site)
        }
        return sites
    }

    static func addSite(urlString: String, name: String?) -> SiteConfiguration? {
        guard let candidate = SiteConfiguration(urlString: urlString, name: name, isBuiltIn: false) else {
            return nil
        }
        let defaults = UserDefaults.standard

        // Adding a built-in site that was removed earlier brings it back
        if let builtIn = builtInSites.first(where: { $0.host == candidate.host }) {
            var hidden = defaults.stringArray(forKey: hiddenSitesKey) ?? []
            if hidden.contains(builtIn.id) {
                hidden.removeAll { $0 == builtIn.id }
                defaults.set(hidden, forKey: hiddenSitesKey)
                return builtIn
            }
        }

        let existing = sites()
        var id = candidate.id
        var suffix = 2
        while existing.contains(where: { $0.id == id }) {
            id = "\(candidate.id)-\(suffix)"
            suffix += 1
        }
        guard let site = SiteConfiguration(
            urlString: candidate.startURL.absoluteString,
            name: candidate.name,
            id: id,
            isBuiltIn: false
        ) else {
            return nil
        }

        var stored = defaults.array(forKey: customSitesKey) as? [[String: String]] ?? []
        stored.append(["id": site.id, "name": site.name, "url": site.startURL.absoluteString])
        defaults.set(stored, forKey: customSitesKey)
        return site
    }

    static func removeSite(id: String) {
        let defaults = UserDefaults.standard
        if builtInSites.contains(where: { $0.id == id }) {
            var hidden = defaults.stringArray(forKey: hiddenSitesKey) ?? []
            if !hidden.contains(id) {
                hidden.append(id)
                defaults.set(hidden, forKey: hiddenSitesKey)
            }
            return
        }
        var stored = defaults.array(forKey: customSitesKey) as? [[String: String]] ?? []
        stored.removeAll { $0["id"] == id }
        defaults.set(stored, forKey: customSitesKey)
    }

    // MARK: - Parsing

    private static func splitList(_ value: String, separators: [Character] = [",", " ", "\n"]) -> [String] {
        return value
            .split(whereSeparator: { separators.contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // "Name=https://example.com" or just "https://example.com"
    private static func splitEntry(_ entry: String) -> (name: String?, url: String) {
        guard let separator = entry.firstIndex(of: "=") else {
            return (nil, entry)
        }
        let left = String(entry[..<separator])
        if left.contains("/") || left.contains("?") {
            return (nil, entry)
        }
        let right = String(entry[entry.index(after: separator)...])
        return (left.trimmingCharacters(in: .whitespaces), right.trimmingCharacters(in: .whitespaces))
    }

    private static func uniqued(
        _ site: SiteConfiguration,
        among sites: [SiteConfiguration],
        extraHosts: [String],
        opensOutside: Bool
    ) -> SiteConfiguration {
        guard sites.contains(where: { $0.id == site.id }) else {
            return site
        }
        var suffix = 2
        while sites.contains(where: { $0.id == "\(site.id)-\(suffix)" }) {
            suffix += 1
        }
        return SiteConfiguration(
            urlString: site.startURL.absoluteString,
            name: site.name,
            id: "\(site.id)-\(suffix)",
            extraHosts: extraHosts,
            opensExternalLinksOutside: opensOutside,
            isBuiltIn: true
        ) ?? site
    }
}
