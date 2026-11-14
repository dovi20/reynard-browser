//
//  SiteRootViewController.swift
//  Reynard
//
//  Root of a site app. Hosts one SiteViewController per website: a single one
//  in a single-site app, or several behind a bottom switcher in a hub. Sites
//  keep their own page alive while the user is in another one, as far as
//  memory allows; sign-ins live in the shared Gecko profile and persist.
//

import GeckoView
import UIKit

final class SiteRootViewController: UIViewController {
    private enum UX {
        static let switcherHeight: CGFloat = 52
        // Devices under this keep fewer sites loaded at once
        static let largeMemoryThreshold: UInt64 = 3_500_000_000
        // The notifications question waits until the first page is on screen
        static let notificationsOfferDelay: TimeInterval = 2
    }

    private static let selectedSiteKey = "SiteRoot.selectedSite"

    let sessionManager = SessionManager()

    private let activity = SiteActivityCenter.shared
    private let isHub = SiteCatalog.isHub
    private var sites = SiteCatalog.sites()
    private var controllers: [String: SiteViewController] = [:]
    // Most recently used first
    private var recentIDs: [String] = []
    private var selectedID: String?
    private var isContentFullScreen = false
    private var hasOfferedNotifications = false

    private let contentContainer = UIView()
    private let switcher = SiteSwitcherBar()
    private var switcherShownConstraint: NSLayoutConstraint?
    private var switcherHiddenConstraint: NSLayoutConstraint?

    private var selectedController: SiteViewController? {
        guard let selectedID else {
            return nil
        }
        return controllers[selectedID]
    }

    override var childForStatusBarStyle: UIViewController? {
        return selectedController
    }

    override var childForStatusBarHidden: UIViewController? {
        return selectedController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        return selectedController
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "LaunchBackground") ?? .systemBackground

        RuntimePreferences.apply() // Gecko prefs
        activity.onOpenSite = { [weak self] id in
            self?.select(id)
        }
        activity.webPermissionPresenter = { [weak self] site, completion in
            guard let self else {
                completion(false)
                return
            }
            self.presentWebPermissionRequest(for: site, completion: completion)
        }
        activity.onAuthorizationDenied = { [weak self] in
            self?.presentNotificationsBlocked()
        }
        activity.start()

        configureHierarchy()

        let storedID = UserDefaults.standard.string(forKey: Self.selectedSiteKey)
        if let initial = sites.first(where: { $0.id == storedID }) ?? sites.first {
            select(initial.id)
        }
        refreshSwitcher()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasOfferedNotifications else {
            return
        }
        hasOfferedNotifications = true
        DispatchQueue.main.asyncAfter(deadline: .now() + UX.notificationsOfferDelay) { [weak self] in
            self?.offerNotificationsIfNeeded()
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for (id, controller) in controllers where id != selectedID && !activity.generatingSiteIDs.contains(id) {
            controller.suspend()
        }
    }

    // MARK: - Scene Lifecycle (called by SceneDelegate)

    func setApplicationForeground(_ isForeground: Bool) {
        sessionManager.setApplicationForeground(isForeground)
    }

    func applicationDidBecomeActive() {
        sessionManager.applicationDidBecomeActive()
        activity.applicationDidBecomeActive()
        selectedController?.applicationDidBecomeActive()
    }

    func applicationWillResignActive() {
        sessionManager.applicationWillResignActive()
        activity.applicationWillResignActive()
        selectedController?.applicationWillResignActive()
    }

    func open(_ url: URL) {
        loadViewIfNeeded()
        if let site = sites.first(where: { $0.isInternal(url) }) {
            select(site.id)
        }
        selectedController?.open(url)
    }

    // MARK: - Layout

    private func configureHierarchy() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        switcher.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        view.addSubview(switcher)

        switcher.onSelect = { [weak self] id in
            self?.select(id)
        }
        switcher.onLongPress = { [weak self] id in
            self?.presentMenu(forSiteID: id)
        }
        switcher.onAdd = { [weak self] in
            self?.presentAddSite()
        }

        switcherShownConstraint = switcher.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -UX.switcherHeight
        )
        switcherHiddenConstraint = switcher.topAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: switcher.topAnchor),

            switcher.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            switcher.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            switcher.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateSwitcherVisibility()
    }

    private func updateSwitcherVisibility() {
        let showsSwitcher = isHub && !isContentFullScreen
        switcherShownConstraint?.isActive = false
        switcherHiddenConstraint?.isActive = false
        if showsSwitcher {
            switcherShownConstraint?.isActive = true
        } else {
            switcherHiddenConstraint?.isActive = true
        }
        switcher.isHidden = !showsSwitcher
    }

    // MARK: - Sites

    private var liveSessionLimit: Int {
        return ProcessInfo.processInfo.physicalMemory < UX.largeMemoryThreshold ? 2 : 3
    }

    func select(_ id: String) {
        guard let site = sites.first(where: { $0.id == id }) else {
            return
        }
        loadViewIfNeeded()
        guard selectedID != id else {
            return
        }

        let previous = selectedController
        let controller = siteController(for: site)

        previous?.setSelected(false)
        previous?.view.isHidden = true

        selectedID = id
        activity.visibleSiteID = id
        isContentFullScreen = false
        controller.view.isHidden = false
        controller.setSelected(true)

        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        trimLiveSessions()
        UserDefaults.standard.set(id, forKey: Self.selectedSiteKey)

        refreshSwitcher()
        updateSwitcherVisibility()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func siteController(for site: SiteConfiguration) -> SiteViewController {
        if let existing = controllers[site.id] {
            return existing
        }

        let siteID = site.id
        let controller = SiteViewController(
            site: site,
            sessionManager: sessionManager,
            splashIcon: splashIcon(for: site)
        )
        controller.onAppearanceChange = { [weak self] in
            guard let self, self.selectedID == siteID else {
                return
            }
            self.refreshSwitcherColors()
        }
        controller.onFullScreenChange = { [weak self] fullScreen in
            guard let self, self.selectedID == siteID else {
                return
            }
            self.isContentFullScreen = fullScreen
            self.updateSwitcherVisibility()
        }
        controller.onMenuRequest = { [weak self] in
            self?.presentMenu(forSiteID: siteID)
        }

        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.isHidden = true
        contentContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        controller.didMove(toParent: self)

        controllers[siteID] = controller
        return controller
    }

    private func splashIcon(for site: SiteConfiguration) -> UIImage {
        if !isHub, let appIcon = SiteIconStore.appIcon {
            return appIcon
        }
        return SiteIconStore.icon(for: site)
    }

    // Keeps the most recently used sites loaded and frees the rest; a site that
    // is still writing a response is left alone.
    private func trimLiveSessions() {
        var liveCount = 0
        for id in recentIDs {
            guard let controller = controllers[id], controller.isLive else {
                continue
            }
            liveCount += 1
            if liveCount > liveSessionLimit, id != selectedID, !activity.generatingSiteIDs.contains(id) {
                controller.suspend()
            }
        }
    }

    private func addSite(urlString: String, name: String?) {
        guard let site = SiteCatalog.addSite(urlString: urlString, name: name) else {
            let alert = UIAlertController(
                title: SiteStrings.text("That address does not look right", "הכתובת לא נראית תקינה"),
                message: SiteStrings.text(
                    "Enter a full website address, for example https://chatgpt.com",
                    "הקלד כתובת אתר מלאה, למשל https://chatgpt.com"
                ),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: SiteStrings.text("OK", "אישור"), style: .cancel))
            topPresenter.present(alert, animated: true)
            return
        }
        sites = SiteCatalog.sites()
        select(site.id)
        refreshSwitcher()
    }

    private func removeSite(id: String) {
        guard sites.count > 1 else {
            return
        }
        SiteCatalog.removeSite(id: id)

        let wasSelected = selectedID == id
        if let controller = controllers.removeValue(forKey: id) {
            controller.setSelected(false)
            controller.suspend()
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        recentIDs.removeAll { $0 == id }
        sites = SiteCatalog.sites()

        if wasSelected {
            selectedID = nil
            if let next = sites.first {
                select(next.id)
            }
        }
        refreshSwitcher()
    }

    // MARK: - Switcher

    private func refreshSwitcher() {
        guard isHub else {
            return
        }
        let items = sites.map { site in
            SiteSwitcherBar.Item(id: site.id, title: site.name, icon: SiteIconStore.icon(for: site))
        }
        switcher.setItems(items, selectedID: selectedID)
        refreshSwitcherColors()

        for site in sites {
            SiteIconStore.fetchIconIfNeeded(for: site) { [weak self] in
                guard let self else {
                    return
                }
                self.controllers[site.id]?.splashIcon = SiteIconStore.icon(for: site)
                self.refreshSwitcher()
            }
        }
    }

    private func refreshSwitcherColors() {
        guard isHub else {
            return
        }
        let color: UIColor = selectedController?.pageBackgroundColor
        ?? UIColor(named: "LaunchBackground")
        ?? .systemBackground
        // Also fills the home-indicator strip under the switcher
        view.backgroundColor = color
        switcher.applyBackground(color, isLight: color.isLightColor(in: traitCollection))
    }

    // MARK: - Menus

    private var topPresenter: UIViewController {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    private func presentMenu(forSiteID id: String) {
        guard let site = sites.first(where: { $0.id == id }) else {
            return
        }

        let sheet = UIAlertController(title: site.name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: SiteStrings.text("Start page", "דף הפתיחה"),
            style: .default
        ) { [weak self] _ in
            self?.select(id)
            self?.controllers[id]?.goToStartPage()
        })
        sheet.addAction(UIAlertAction(
            title: SiteStrings.text("Reload", "טען מחדש"),
            style: .default
        ) { [weak self] _ in
            self?.select(id)
            self?.controllers[id]?.reload()
        })
        sheet.addAction(UIAlertAction(
            title: SiteStrings.text("Notifications and status", "התראות ומצב"),
            style: .default
        ) { [weak self] _ in
            self?.presentStatus()
        })
        if isHub, sites.count > 1 {
            sheet.addAction(UIAlertAction(
                title: SiteStrings.text("Remove from the hub", "הסר מה-hub"),
                style: .destructive
            ) { [weak self] _ in
                self?.removeSite(id: id)
            })
        }
        sheet.addAction(UIAlertAction(title: SiteStrings.text("Cancel", "ביטול"), style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        topPresenter.present(sheet, animated: true)
    }

    // MARK: - Notifications

    // iOS shows no permission alert for apps TrollStore installs, so the app asks itself
    private func offerNotificationsIfNeeded() {
        guard activity.notificationsDecision == nil else {
            return
        }
        guard presentedViewController == nil else {
            // Something else is up (a site prompt); ask after it
            DispatchQueue.main.asyncAfter(deadline: .now() + UX.notificationsOfferDelay) { [weak self] in
                self?.offerNotificationsIfNeeded()
            }
            return
        }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "This app"
        let alert = UIAlertController(
            title: SiteStrings.text(
                "\u{201C}\(appName)\u{201D} Would Like to Send You Notifications",
                "\u{201C}\(appName)\u{201D} מבקשת לשלוח לך התראות"
            ),
            message: SiteStrings.text(
                "You get a notification when a response is ready and you are not looking at it.",
                "תקבל התראה כשתשובה מוכנה ואתה לא מסתכל עליה."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Don\u{2019}t Allow", "אל תאפשר"),
            style: .default
        ) { [weak self] _ in
            self?.activity.setNotificationsEnabled(false)
        })
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Allow", "אפשר"),
            style: .default
        ) { [weak self] _ in
            self?.activity.setNotificationsEnabled(true)
        })
        present(alert, animated: true)
    }

    private func presentWebPermissionRequest(for site: SiteConfiguration, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: SiteStrings.text(
                "\u{201C}\(site.name)\u{201D} Would Like to Send You Notifications",
                "\u{201C}\(site.name)\u{201D} מבקש לשלוח לך התראות"
            ),
            message: site.host,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Don\u{2019}t Allow", "אל תאפשר"),
            style: .default
        ) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Allow", "אפשר"),
            style: .default
        ) { _ in
            completion(true)
        })
        topPresenter.present(alert, animated: true)
    }

    private func presentNotificationsBlocked() {
        let alert = UIAlertController(
            title: SiteStrings.text("iOS is blocking notifications", "iOS חוסם את ההתראות"),
            message: SiteStrings.text(
                "Open Settings, then Notifications, choose this app and allow notifications.",
                "פתח הגדרות, אחר כך התראות, בחר באפליקציה הזאת ואפשר התראות."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Open Settings", "פתח הגדרות"),
            style: .default
        ) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        })
        alert.addAction(UIAlertAction(title: SiteStrings.text("Close", "סגור"), style: .cancel))
        topPresenter.present(alert, animated: true)
    }

    private func presentStatus() {
        activity.onStatusRefreshed = { [weak self] in
            guard let self else {
                return
            }
            self.activity.onStatusRefreshed = nil

            let alert = UIAlertController(
                title: SiteStrings.text("Notifications and status", "התראות ומצב"),
                message: self.activity.statusText(),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: SiteStrings.text("Test notification in 5 seconds", "התראת בדיקה בעוד 5 שניות"),
                style: .default
            ) { _ in
                SiteActivityCenter.shared.sendTestNotification()
            })
            let isOn = self.activity.notificationsDecision == true
            alert.addAction(UIAlertAction(
                title: isOn
                ? SiteStrings.text("Turn notifications off", "כבה התראות")
                : SiteStrings.text("Turn notifications on", "הפעל התראות"),
                style: .default
            ) { _ in
                SiteActivityCenter.shared.setNotificationsEnabled(!isOn)
            })
            alert.addAction(UIAlertAction(title: SiteStrings.text("Close", "סגור"), style: .cancel))
            self.topPresenter.present(alert, animated: true)
        }
        activity.refreshStatus()
    }

    private func presentAddSite() {
        let alert = UIAlertController(
            title: SiteStrings.text("Add a site", "הוספת אתר"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "https://"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = SiteStrings.text("Name (optional)", "שם (לא חובה)")
        }
        alert.addAction(UIAlertAction(title: SiteStrings.text("Cancel", "ביטול"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: SiteStrings.text("Add", "הוסף"),
            style: .default
        ) { [weak self, weak alert] _ in
            let urlString = alert?.textFields?.first?.text ?? ""
            let name = alert?.textFields?.last?.text
            self?.addSite(urlString: urlString, name: name)
        })
        topPresenter.present(alert, animated: true)
    }
}

// MARK: - Switcher Bar

final class SiteSwitcherBar: UIView {
    struct Item {
        let id: String
        let title: String
        let icon: UIImage
    }

    private enum UX {
        static let contentHeight: CGFloat = 52
        static let separatorHeight: CGFloat = 0.5
    }

    var onSelect: ((String) -> Void)?
    var onLongPress: ((String) -> Void)?
    var onAdd: (() -> Void)?

    private let separator = UIView()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var itemViews: [SiteSwitcherItemView] = []
    private var selectedID: String?
    private var tint: UIColor = .label

    init() {
        super.init(frame: .zero)

        separator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false

        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.alignment = .fill

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        addSubview(separator)

        let fitsWidth = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        fitsWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: UX.separatorHeight),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: UX.contentHeight),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            fitsWidth,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setItems(_ items: [Item], selectedID: String?) {
        self.selectedID = selectedID

        for itemView in itemViews {
            stackView.removeArrangedSubview(itemView)
            itemView.removeFromSuperview()
        }
        itemViews = []

        for item in items {
            let itemView = SiteSwitcherItemView(siteID: item.id, title: item.title, image: item.icon, isSymbol: false)
            itemView.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
            itemView.addGestureRecognizer(
                UILongPressGestureRecognizer(target: self, action: #selector(itemLongPressed(_:)))
            )
            appendItemView(itemView)
        }

        let addView = SiteSwitcherItemView(
            siteID: nil,
            title: SiteStrings.text("Add", "הוסף"),
            image: UIImage(systemName: "plus"),
            isSymbol: true
        )
        addView.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        appendItemView(addView)

        applyState()
    }

    func applyBackground(_ color: UIColor, isLight: Bool) {
        backgroundColor = color
        tint = isLight ? .black : .white
        separator.backgroundColor = tint.withAlphaComponent(0.14)
        applyState()
    }

    private func appendItemView(_ itemView: SiteSwitcherItemView) {
        itemViews.append(itemView)
        stackView.addArrangedSubview(itemView)
    }

    private func applyState() {
        for itemView in itemViews {
            itemView.apply(
                isSelected: itemView.siteID != nil && itemView.siteID == selectedID,
                tint: tint
            )
        }
    }

    @objc private func itemTapped(_ sender: SiteSwitcherItemView) {
        guard let id = sender.siteID else {
            return
        }
        onSelect?(id)
    }

    @objc private func itemLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let id = (recognizer.view as? SiteSwitcherItemView)?.siteID else {
            return
        }
        onLongPress?(id)
    }

    @objc private func addTapped() {
        onAdd?()
    }
}

final class SiteSwitcherItemView: UIControl {
    private enum UX {
        static let minimumWidth: CGFloat = 64
        static let iconSide: CGFloat = 28
        static let iconCornerRadius: CGFloat = 7
        static let iconTop: CGFloat = 6
        static let labelTop: CGFloat = 3
        static let unselectedAlpha: CGFloat = 0.45
    }

    let siteID: String?
    private let imageView = UIImageView()
    private let label = UILabel()
    private let isSymbol: Bool

    init(siteID: String?, title: String, image: UIImage?, isSymbol: Bool) {
        self.siteID = siteID
        self.isSymbol = isSymbol
        super.init(frame: .zero)

        imageView.image = image
        imageView.contentMode = isSymbol ? .center : .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = isSymbol ? 0 : UX.iconCornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.translatesAutoresizingMaskIntoConstraints = false

        label.text = title
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(label)

        accessibilityLabel = title
        isAccessibilityElement = true
        accessibilityTraits = .button

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumWidth),

            imageView.topAnchor.constraint(equalTo: topAnchor, constant: UX.iconTop),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: UX.iconSide),
            imageView.heightAnchor.constraint(equalToConstant: UX.iconSide),

            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: UX.labelTop),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(isSelected: Bool, tint: UIColor) {
        label.textColor = tint
        imageView.tintColor = tint
        alpha = (isSelected || isSymbol) ? 1 : UX.unselectedAlpha
        if isSymbol {
            imageView.alpha = 0.7
            label.alpha = 0.7
        }
    }
}
