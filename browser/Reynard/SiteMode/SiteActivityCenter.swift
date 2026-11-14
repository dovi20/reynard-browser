//
//  SiteActivityCenter.swift
//  Reynard
//
//  Native side of the built-in site bridge extension (browser/SiteExtensions).
//  The extension reports when a site starts and finishes writing a response; this
//  keeps the app alive in the background while a response is being written and
//  posts a local notification when it finishes and the user is not looking at it.
//  It also delivers the sites' own web notifications (window.Notification), which
//  Gecko on iOS has no backend for.
//

import Foundation
import GeckoView
import UIKit
import UserNotifications

enum SiteStrings {
    static let prefersHebrew = Locale.preferredLanguages.first?.hasPrefix("he") == true

    static func text(_ english: String, _ hebrew: String) -> String {
        return prefersHebrew ? hebrew : english
    }
}

final class SiteActivityCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SiteActivityCenter()

    static let extensionID = "claude-bridge@reynard.site"
    // Gecko only installs built-in extensions from this exact folder (see
    // GeckoViewWebExtension.sys.mjs.patch); site builds put the bridge there
    // in place of reader mode (tools/site/customize-app.sh).
    static let extensionLocation = "resource://app/extensions/readerview/"
    static let nativeApp = "reynard_site_bridge"

    private enum UX {
        // Upper bound for staying alive in the background for one response
        static let keepAliveLimit: TimeInterval = 15 * 60
        static let testNotificationDelay: TimeInterval = 5
        // A site's own notification and the bridge's often announce the same response
        static let duplicateWindow: TimeInterval = 8
    }

    enum WebPermission: String {
        case undecided = "default"
        case granted
        case denied
    }

    private static let enabledKey = "SiteNotifications.enabled"
    private static let webPermissionKeyPrefix = "SiteNotifications.web."

    // Called with a site id when the user taps a notification
    var onOpenSite: ((String) -> Void)?
    var onStatusRefreshed: (() -> Void)?
    // iOS refused the app's notifications (turned off in Settings)
    var onAuthorizationDenied: (() -> Void)?
    // Asks the user whether a site may send notifications; calls back with the answer
    var webPermissionPresenter: ((SiteConfiguration, @escaping (Bool) -> Void) -> Void)?
    // The site currently on screen; responses finishing elsewhere are announced
    var visibleSiteID: String?

    private(set) var generatingSiteIDs: Set<String> = []
    private var conversationTitles: [String: String] = [:]
    private var isAppActive = true
    private var hasStarted = false
    private var lastPostDates: [String: Date] = [:]
    private var sitesAwaitingPermission: Set<String> = []
    private var isKeepingAlive = false
    private var keepAliveToken = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Shown in the status sheet, since device logs are not at hand
    private var extensionStatus = "not started"
    private var authorizationStatus = "unknown"
    private var lastBridgeEvent = "none"
    private var lastNotificationResult = "none"

    // MARK: - Setup

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        UNUserNotificationCenter.current().delegate = self
        // iOS wants one request before any notification, including from apps it
        // shows no permission alert for (TrollStore registers apps as system apps)
        requestAuthorization(reportingDenial: false)

        extensionStatus = "installing"
        Task {
            do {
                _ = try await AddonRuntime.shared.ensureBuiltIn(
                    location: Self.extensionLocation,
                    id: Self.extensionID
                )
                extensionStatus = "installed"
            } catch {
                extensionStatus = "failed: \(error)"
                NSLog("SiteActivityCenter: failed to install %@: %@", Self.extensionID, "\(error)")
            }
        }
    }

    // MARK: - Permission

    // nil until the user has answered the app's own "turn on notifications" question
    var notificationsDecision: Bool? {
        return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        guard enabled else {
            return
        }
        requestAuthorization(reportingDenial: true)
        // Visible proof that iOS shows this app's notifications
        let content = UNMutableNotificationContent()
        content.title = SiteStrings.text("Notifications are on", "ההתראות פועלות")
        content.body = SiteStrings.text(
            "You will be notified when a response is ready.",
            "תקבל התראה כשתשובה מוכנה."
        )
        content.sound = .default
        add(content, trigger: nil, label: "confirmation")
    }

    private func requestAuthorization(reportingDenial: Bool) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let failure = error.map { "\($0.localizedDescription)" }
            Task { @MainActor in
                if let failure {
                    self.authorizationStatus = "request failed: \(failure)"
                } else {
                    self.authorizationStatus = granted ? "allowed" : "not allowed"
                }
                if reportingDenial, !granted {
                    self.onAuthorizationDenied?()
                }
            }
        }
    }

    func webPermission(for site: SiteConfiguration) -> WebPermission {
        let stored = UserDefaults.standard.string(forKey: Self.webPermissionKeyPrefix + site.id) ?? ""
        return WebPermission(rawValue: stored) ?? .undecided
    }

    // The site called Notification.requestPermission()
    func requestWebPermission(for site: SiteConfiguration) async -> WebPermission {
        let current = webPermission(for: site)
        guard current == .undecided,
              let presenter = webPermissionPresenter,
              !sitesAwaitingPermission.contains(site.id) else {
            return current
        }

        sitesAwaitingPermission.insert(site.id)
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            presenter(site) { allowed in
                continuation.resume(returning: allowed)
            }
        }
        sitesAwaitingPermission.remove(site.id)

        let result: WebPermission = allowed ? .granted : .denied
        UserDefaults.standard.set(result.rawValue, forKey: Self.webPermissionKeyPrefix + site.id)
        if allowed, notificationsDecision != true {
            setNotificationsEnabled(true)
        }
        return result
    }

    // The site created a Notification
    func postWebNotification(for site: SiteConfiguration, title: String, body: String) {
        lastBridgeEvent = "\(site.name): site notification at \(Self.timestamp())"
        guard webPermission(for: site) == .granted, notificationsDecision != false else {
            return
        }
        guard !isAppActive || visibleSiteID != site.id else {
            // The user is looking at this site
            return
        }

        let content = UNMutableNotificationContent()
        if SiteCatalog.isHub, title.caseInsensitiveCompare(site.name) != .orderedSame {
            content.title = site.name
            content.subtitle = title
        } else {
            content.title = title.isEmpty ? site.name : title
        }
        content.body = body
        content.sound = .default
        content.threadIdentifier = "responses-\(site.id)"
        content.userInfo = ["site": site.id]
        post(content, for: site, label: "site notification from \(site.name)")
    }

    // MARK: - App Lifecycle

    func applicationWillResignActive() {
        isAppActive = false
        if !generatingSiteIDs.isEmpty {
            // Start while the app is still allowed to begin audio playback
            beginKeepAlive()
        }
    }

    func applicationDidBecomeActive() {
        isAppActive = true
        endKeepAlive()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Activity

    func bridgeDidLoad(for site: SiteConfiguration) {
        lastBridgeEvent = "\(site.name): page ready at \(Self.timestamp())"
    }

    func activityChanged(for site: SiteConfiguration, active: Bool, title: String?, preview: String?) {
        lastBridgeEvent = "\(site.name): response \(active ? "started" : "finished") at \(Self.timestamp())"

        if active {
            generatingSiteIDs.insert(site.id)
            if let title, !title.isEmpty {
                conversationTitles[site.id] = title
            }
            if !isAppActive {
                beginKeepAlive()
            }
            return
        }

        guard generatingSiteIDs.remove(site.id) != nil else {
            return
        }
        let storedTitle = conversationTitles.removeValue(forKey: site.id)
        let finalTitle = (title?.isEmpty == false ? title : nil) ?? storedTitle

        if notificationsDecision == true, !isAppActive || visibleSiteID != site.id {
            postCompletionNotification(for: site, title: finalTitle, preview: preview)
        }
        if generatingSiteIDs.isEmpty {
            endKeepAlive()
        }
    }

    // A site whose session was closed can no longer report that it finished
    func sessionDidClose(for site: SiteConfiguration) {
        generatingSiteIDs.remove(site.id)
        conversationTitles.removeValue(forKey: site.id)
        if generatingSiteIDs.isEmpty {
            endKeepAlive()
        }
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
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Site response") { [weak self] in
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

    private func postCompletionNotification(for site: SiteConfiguration, title: String?, preview: String?) {
        let content = UNMutableNotificationContent()
        let conversation = title.flatMap { $0.caseInsensitiveCompare(site.name) == .orderedSame ? nil : $0 }

        if SiteCatalog.isHub {
            content.title = site.name
            if let conversation {
                content.subtitle = conversation
            }
        } else {
            content.title = conversation ?? site.name
        }
        if let preview, !preview.isEmpty {
            content.body = preview
        } else {
            content.body = SiteStrings.text(
                "\(site.name) finished responding",
                "\(site.name) סיים לענות"
            )
        }
        content.sound = .default
        content.threadIdentifier = "responses-\(site.id)"
        content.userInfo = ["site": site.id]

        post(content, for: site, label: "response from \(site.name)")
    }

    private func post(_ content: UNNotificationContent, for site: SiteConfiguration, label: String) {
        if let last = lastPostDates[site.id], Date().timeIntervalSince(last) < UX.duplicateWindow {
            lastNotificationResult = "\(label) at \(Self.timestamp()) skipped as a duplicate"
            return
        }
        lastPostDates[site.id] = Date()
        add(content, trigger: nil, label: label)
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = SiteStrings.text("Test notification", "התראת בדיקה")
        content.body = SiteStrings.text(
            "Notifications from this app work.",
            "התראות מהאפליקציה הזאת עובדות."
        )
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: UX.testNotificationDelay,
            repeats: false
        )
        add(content, trigger: trigger, label: "test")
    }

    private func add(_ content: UNNotificationContent, trigger: UNNotificationTrigger?, label: String) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        let stamp = Self.timestamp()
        UNUserNotificationCenter.current().add(request) { error in
            let failure = error.map { "\($0.localizedDescription)" }
            Task { @MainActor in
                if let failure {
                    self.lastNotificationResult = "\(label) at \(stamp) failed: \(failure)"
                    NSLog("SiteActivityCenter: failed to post notification: %@", failure)
                } else {
                    self.lastNotificationResult = "\(label) at \(stamp) accepted by iOS"
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Shown while the app is open too: a response finished in another site
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let siteID = response.notification.request.content.userInfo["site"] as? String
        Task { @MainActor in
            if let siteID {
                SiteActivityCenter.shared.onOpenSite?(siteID)
            }
        }
        completionHandler()
    }

    // MARK: - Status

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus.rawValue
            let alerts = settings.alertSetting.rawValue
            Task { @MainActor in
                self.authorizationStatus = Self.describeAuthorization(status, alertSetting: alerts)
                self.onStatusRefreshed?()
            }
        }
    }

    func statusText() -> String {
        let decision: String
        switch notificationsDecision {
        case .some(true):
            decision = "on"
        case .some(false):
            decision = "off"
        case .none:
            decision = "not chosen yet"
        }
        let registersForNotifications = Bundle.main.object(forInfoDictionaryKey: "SBAppUsesLocalNotifications") as? Bool ?? false
        return [
            "In this app: \(decision)",
            "iOS: \(authorizationStatus)",
            "Registered with iOS for notifications: \(registersForNotifications ? "yes" : "no")",
            "Bridge extension: \(extensionStatus)",
            "Last bridge event: \(lastBridgeEvent)",
            "Last notification: \(lastNotificationResult)",
            "Responses in progress: \(generatingSiteIDs.count)",
        ].joined(separator: "\n")
    }

    private static func describeAuthorization(_ status: Int, alertSetting: Int) -> String {
        let name: String
        switch status {
        case UNAuthorizationStatus.notDetermined.rawValue:
            name = "not asked yet"
        case UNAuthorizationStatus.denied.rawValue:
            name = "turned off in Settings"
        case UNAuthorizationStatus.authorized.rawValue:
            name = "allowed"
        default:
            name = "status \(status)"
        }
        let alerts = alertSetting == UNNotificationSetting.enabled.rawValue ? "banners on" : "banners off"
        return "\(name), \(alerts)"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// One per site session: receives the bridge extension's messages for that site.
final class SiteBridgeEndpoint: AddonMessageDelegate {
    let site: SiteConfiguration

    init(site: SiteConfiguration) {
        self.site = site
    }

    func attach(to session: GeckoSession) {
        session.setAddonMessageDelegate(
            self,
            extensionID: SiteActivityCenter.extensionID,
            nativeApp: SiteActivityCenter.nativeApp
        )
    }

    func addonMessage(_ message: Any, nativeApp: String, sender: AddonMessageSender) async throws -> Any? {
        guard let payload = message as? [String: Any?],
              let type = payload["type"] as? String else {
            return nil
        }

        switch type {
        case "ready":
            SiteActivityCenter.shared.bridgeDidLoad(for: site)
        case "activity":
            SiteActivityCenter.shared.activityChanged(
                for: site,
                active: Self.bool(payload["active"] ?? nil),
                title: payload["title"] as? String,
                preview: payload["preview"] as? String
            )
        case "web-notification-permission":
            return ["permission": SiteActivityCenter.shared.webPermission(for: site).rawValue]
        case "web-notification-request":
            let permission = await SiteActivityCenter.shared.requestWebPermission(for: site)
            return ["permission": permission.rawValue]
        case "web-notification":
            SiteActivityCenter.shared.postWebNotification(
                for: site,
                title: payload["title"] as? String ?? "",
                body: payload["body"] as? String ?? ""
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
}
