//
//  SiteConfiguration.swift
//  Reynard
//
//  Single-site mode: when the app's Info.plist carries ReynardSiteURL, the app
//  boots straight into that website instead of the full browser UI.
//
//  Info.plist keys (injected at packaging time by tools/site/customize-app.sh):
//    ReynardSiteURL                     String  start page (http/https)
//    ReynardSiteAllowedHosts            String  extra hosts that stay in-app, comma or space separated
//    ReynardSiteOpenExternalLinksOutside Bool   true (default): other hosts open in Safari
//

import Foundation

struct SiteConfiguration {
    enum Route {
        case inApp
        case external(URL)
    }

    let startURL: URL
    let allowedHosts: [String]
    let opensExternalLinksOutside: Bool

    static let current: SiteConfiguration? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let rawURL = (info["ReynardSiteURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        var hosts = [normalizedHost(host)]
        if let extraHosts = info["ReynardSiteAllowedHosts"] as? String {
            hosts += extraHosts
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { normalizedHost(String($0)) }
                .filter { !$0.isEmpty }
        }

        return SiteConfiguration(
            startURL: url,
            allowedHosts: hosts,
            opensExternalLinksOutside: info["ReynardSiteOpenExternalLinksOutside"] as? Bool ?? true
        )
    }()

    private static func normalizedHost(_ host: String) -> String {
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

    func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func route(for uri: String) -> Route {
        guard let url = URL(string: uri),
              let scheme = url.scheme?.lowercased() else {
            return .inApp
        }

        switch scheme {
        case "http", "https":
            if !opensExternalLinksOutside || isInternal(url) {
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
