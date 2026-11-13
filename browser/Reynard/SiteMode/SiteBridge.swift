//
//  SiteBridge.swift
//  Reynard
//
//  Native side of the built-in "claude-bridge" extension (browser/SiteExtensions).
//  The content script reports when Claude starts and finishes a response; the
//  bridge keeps the app alive in the background while a response is being written
//  and posts a local notification when it finishes while the app is not in front.
//

import Foundation
import GeckoView
import UIKit
import UserNotifications

final class SiteBridge: AddonMessageDelegate {
    static let extensionID = "claude-bridge@reynard.site"
    static let extensionLocation = "resource://app/extensions/claude-bridge/"
    static let nativeApp = "reynard_site_bridge"

    private enum UX {
        // Upper bound for staying alive in the background for one response
        static let keepAliveLimit: TimeInterval = 15 * 60
    }

    private var isGenerating = false
    private var generationTitle: String?
    private var isAppActive = true
    private var isKeepingAlive = false
    private var keepAliveToken = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var hasRequestedAuthorization = false

    static func supports(_ configuration: SiteConfiguration) -> Bool {
        guard let host = configuration.startURL.host?.lowercased() else {
            return false
        }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    // MARK: - Setup

    func start() {
        Task {
            do {
                _ = try await AddonRuntime.shared.ensureBuiltIn(
                    location: Self.extensionLocation,
                    id: Self.extensionID
                )
            } catch {
                NSLog("SiteBridge: failed to install %@: %@", Self.extensionID, "\(error)")
            }
        }
    }

    func attach(to session: GeckoSession) {
        session.setAddonMessageDelegate(self, extensionID: Self.extensionID, nativeApp: Self.nativeApp)
    }

    // MARK: - App Lifecycle

    func applicationWillResignActive() {
        isAppActive = false
        if isGenerating {
            // Start while the app is still allowed to begin audio playback
            beginKeepAlive()
        }
    }

    func applicationDidBecomeActive() {
        isAppActive = true
        endKeepAlive()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - AddonMessageDelegate

    func addonMessage(_ message: Any, nativeApp: String, sender: AddonMessageSender) async throws -> Any? {
        guard let payload = message as? [String: Any?],
              let type = payload["type"] as? String else {
            return nil
        }

        switch type {
        case "ready":
            requestAuthorizationIfNeeded()
        case "activity":
            handleActivity(
                active: Self.bool(payload["active"] ?? nil),
                title: payload["title"] as? String,
                preview: payload["preview"] as? String
            )
        default:
            break
        }
        return ["ok": true]
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    // MARK: - Activity

    private func handleActivity(active: Bool, title: String?, preview: String?) {
        if active {
            isGenerating = true
            if let title, !title.isEmpty {
                generationTitle = title
            }
            if !isAppActive {
                beginKeepAlive()
            }
            return
        }

        guard isGenerating else {
            return
        }
        isGenerating = false

        if !isAppActive {
            postCompletionNotification(title: title?.isEmpty == false ? title : generationTitle, preview: preview)
        }
        generationTitle = nil
        endKeepAlive()
    }

    // MARK: - Background Keep-Alive

    private func beginKeepAlive() {
        guard !isKeepingAlive else {
            return
        }
        isKeepingAlive = true
        keepAliveToken += 1
        let token = keepAliveToken

        BackgroundAudioManager.shared.start()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Claude response") { [weak self] in
            self?.endBackgroundTask()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + UX.keepAliveLimit) { [weak self] in
            guard let self, self.keepAliveToken == token else {
                return
            }
            self.endKeepAlive()
        }
    }

    private func endKeepAlive() {
        guard isKeepingAlive else {
            return
        }
        isKeepingAlive = false
        keepAliveToken += 1
        BackgroundAudioManager.shared.stop()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Notifications

    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else {
            return
        }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postCompletionNotification(title: String?, preview: String?) {
        let prefersHebrew = Locale.preferredLanguages.first?.hasPrefix("he") == true
        let content = UNMutableNotificationContent()
        content.title = (title?.isEmpty == false ? title : nil) ?? "Claude"
        if let preview, !preview.isEmpty {
            content.body = preview
        } else {
            content.body = prefersHebrew ? "Claude סיים לענות" : "Claude finished responding"
        }
        content.sound = .default
        content.threadIdentifier = "claude-responses"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("SiteBridge: failed to post notification: %@", "\(error)")
            }
        }
    }
}
