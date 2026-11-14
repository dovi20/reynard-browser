//
//  SiteViewController.swift
//  Reynard
//
//  One website shown full-screen with no browser chrome. SiteRootViewController
//  hosts one of these per site (a single one in a single-site app).
//

import GeckoView
import UIKit

final class SiteViewController: UIViewController, ContentDelegate, NavigationDelegate, ProgressDelegate, UIGestureRecognizerDelegate {
    private enum UX {
        static let backSwipeDistance: CGFloat = 80
        static let backSwipeVelocity: CGFloat = 500
        static let floatingKeyboardWidthRatio: CGFloat = 0.8
        static let keyboardAnimationDuration: TimeInterval = 0.25
        static let keyboardAnimationCurve: UInt = 7
        static let menuPressDuration: TimeInterval = 0.7
        // The loading screen never outlives this, whatever the page reports
        static let splashTimeout: TimeInterval = 20
        // Reopening the app within this time returns to the page it was on
        static let resumeWindow: TimeInterval = 30 * 60
    }

    let site: SiteConfiguration
    let sessionManager: SessionManager

    // Page colors changed (the hub tints its switcher with them)
    var onAppearanceChange: (() -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?
    // Two-finger long press: the app menu
    var onMenuRequest: (() -> Void)?

    private let geckoView = GeckoView()
    private let errorView = WebContentErrorView()
    private let splashView: SiteSplashView
    private let bridgeEndpoint: SiteBridgeEndpoint
    private let promptCoordinator = PromptCoordinator(presenter: PromptPresenter())
    private let permissionCoordinator = PermissionCoordinator(promptPresenter: PermissionPromptPresenter())
    private let selectionActionCoordinator = SelectionActionCoordinator(
        presenter: SelectionActionPresenter(
            onMenuDismissed: { _ in },
            onFindInPage: { _, _ in }
        )
    )

    private weak var popupViewController: SitePopupViewController?
    private var pendingDownloads: [String: String] = [:]

    private var session: GeckoSession?
    private var lastURL: String?
    private var canGoBack = false
    private var currentError: WebRequestError?
    private var needsSessionRecovery = false
    private var isFullScreen = false
    private var splashToken = 0
    private var isLoadingBlankPage = false
    private(set) var isSelected = false
    private(set) var pageBackgroundColor: UIColor = UIColor(named: "LaunchBackground") ?? .systemBackground

    private var normalConstraints: [NSLayoutConstraint] = []
    private var fullScreenConstraints: [NSLayoutConstraint] = []
    private var keyboardBottomConstraint: NSLayoutConstraint?

    // MARK: - Lifecycle

    init(site: SiteConfiguration, sessionManager: SessionManager, splashIcon: UIImage?) {
        self.site = site
        self.sessionManager = sessionManager
        self.splashView = SiteSplashView(icon: splashIcon)
        self.bridgeEndpoint = SiteBridgeEndpoint(site: site)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return pageBackgroundColor.isLightColor(in: traitCollection) ? .darkContent : .lightContent
    }

    override var prefersStatusBarHidden: Bool {
        return isFullScreen
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return isFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageBackgroundColor

        configureHierarchy()
        configureGestures()
        observeKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isSelected {
            _ = session?.focusForHardwareKeyboard()
        }
    }

    // MARK: - Selection (called by SiteRootViewController)

    var splashIcon: UIImage? {
        get { return splashView.icon }
        set { splashView.icon = newValue }
    }

    // A site with no session costs no memory; it reloads when selected again
    var isLive: Bool {
        return session != nil
    }

    func setSelected(_ selected: Bool) {
        loadViewIfNeeded()
        isSelected = selected

        if selected {
            if let session {
                sessionManager.activate(session)
            } else {
                showError(nil)
                startSession(loading: resumeURL())
            }
            return
        }

        geckoView.endEditing(true)
        if let session {
            sessionManager.deactivate(session)
        }
    }

    func suspend() {
        guard !isSelected, session != nil else {
            return
        }
        tearDownSession()
    }

    func applicationDidBecomeActive() {
        if isSelected, needsSessionRecovery {
            recoverSession()
        }
    }

    func applicationWillResignActive() {
        if isSelected {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUsedKey)
        }
    }

    func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        loadViewIfNeeded()
        if let session {
            session.load(url.absoluteString)
        } else {
            lastURL = url.absoluteString
        }
    }

    func reload() {
        if session == nil || needsSessionRecovery {
            recoverSession()
        } else {
            showError(nil)
            session?.reload()
        }
    }

    func goToStartPage() {
        lastURL = site.startURL.absoluteString
        if let session, !needsSessionRecovery {
            showError(nil)
            session.load(site.startURL.absoluteString)
        } else {
            recoverSession()
        }
    }

    // MARK: - Resume State

    private var lastURLKey: String {
        return "SiteState.\(site.id).lastURL"
    }

    private var lastUsedKey: String {
        return "SiteState.\(site.id).lastUsed"
    }

    private func resumeURL() -> String {
        if let lastURL {
            return lastURL
        }
        let defaults = UserDefaults.standard
        let lastUsed = defaults.double(forKey: lastUsedKey)
        if lastUsed > 0,
           Date().timeIntervalSince1970 - lastUsed < UX.resumeWindow,
           let stored = defaults.string(forKey: lastURLKey),
           let storedURL = URL(string: stored),
           site.isInternal(storedURL) {
            return stored
        }
        return site.startURL.absoluteString
    }

    private func rememberLocation(_ url: String) {
        lastURL = url
        guard let parsed = URL(string: url), site.isInternal(parsed) else {
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(url, forKey: lastURLKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastUsedKey)
    }

    // MARK: - Session

    private func startSession(loading url: String) {
        let session = sessionManager.createSession(
            url: url,
            tabID: nil,
            isPrivate: false,
            opening: .manual,
            delegates: SessionDelegates()
        )
        sessionManager.bindDelegates(
            to: session,
            delegates: SessionDelegates(
                content: self,
                navigation: self,
                permission: permissionCoordinator,
                progress: self,
                prompt: promptCoordinator,
                selectionAction: selectionActionCoordinator
            )
        )
        bridgeEndpoint.attach(to: session)
        sessionManager.open(session)
        geckoView.session = session
        if isSelected {
            sessionManager.activate(session)
        } else {
            sessionManager.deactivate(session)
        }
        self.session = session
        needsSessionRecovery = false
        showSplash()
        session.load(url)
    }

    private func tearDownSession() {
        guard let session else {
            return
        }
        geckoView.endEditing(true)
        geckoView.session = nil
        sessionManager.close(session)
        self.session = nil
        canGoBack = false
        SiteActivityCenter.shared.sessionDidClose(for: site)
    }

    private func recoverSession() {
        tearDownSession()
        showError(nil)
        startSession(loading: lastURL ?? site.startURL.absoluteString)
    }

    // MARK: - Loading Screen

    private func showSplash() {
        splashToken += 1
        let token = splashToken
        splashView.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + UX.splashTimeout) { [weak self] in
            guard let self, self.splashToken == token else {
                return
            }
            self.splashView.hide()
        }
    }

    private func hideSplash() {
        guard splashView.isShowing else {
            return
        }
        splashToken += 1
        splashView.hide()
    }

    // MARK: - Layout

    private func configureHierarchy() {
        geckoView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        splashView.translatesAutoresizingMaskIntoConstraints = false

        errorView.isHidden = true
        errorView.onAction = { [weak self] action in
            self?.handleErrorAction(action)
        }

        splashView.isHidden = true

        view.addSubview(geckoView)
        view.addSubview(splashView)
        view.addSubview(errorView)

        let safeArea = view.safeAreaLayoutGuide
        let keyboardBottom = geckoView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        keyboardBottomConstraint = keyboardBottom

        normalConstraints = [
            geckoView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            keyboardBottom,
        ]
        fullScreenConstraints = [
            geckoView.topAnchor.constraint(equalTo: view.topAnchor),
            geckoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]

        NSLayoutConstraint.activate(normalConstraints + [
            geckoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geckoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            errorView.topAnchor.constraint(equalTo: geckoView.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: geckoView.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: geckoView.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: geckoView.trailingAnchor),

            splashView.topAnchor.constraint(equalTo: view.topAnchor),
            splashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        errorView.configureContentLayout(
            topAnchor: geckoView.topAnchor,
            bottomAnchor: geckoView.bottomAnchor
        )
    }

    private func setFullScreen(_ fullScreen: Bool) {
        guard isFullScreen != fullScreen else {
            return
        }
        isFullScreen = fullScreen
        if fullScreen {
            NSLayoutConstraint.deactivate(normalConstraints)
            NSLayoutConstraint.activate(fullScreenConstraints)
        } else {
            NSLayoutConstraint.deactivate(fullScreenConstraints)
            NSLayoutConstraint.activate(normalConstraints)
        }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        view.layoutIfNeeded()
    }

    // MARK: - Gestures

    private func configureGestures() {
        let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackSwipe(_:)))
        let isRightToLeft = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        recognizer.edges = isRightToLeft ? .right : .left
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)

        let menuPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        menuPress.numberOfTouchesRequired = 2
        menuPress.minimumPressDuration = UX.menuPressDuration
        menuPress.delegate = self
        view.addGestureRecognizer(menuPress)
    }

    @objc private func handleMenuPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else {
            return
        }
        onMenuRequest?()
    }

    @objc private func handleBackSwipe(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard recognizer.state == .ended, canGoBack, !isFullScreen else {
            return
        }
        let direction: CGFloat = recognizer.edges == .right ? -1 : 1
        let distance = recognizer.translation(in: view).x * direction
        let velocity = recognizer.velocity(in: view).x * direction
        if distance > UX.backSwipeDistance || velocity > UX.backSwipeVelocity {
            session?.goBack()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard isSelected,
              let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }

        let keyboardFrame = view.convert(frameValue.cgRectValue, from: nil)
        let keyboardOverlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        let keyboardInset = max(0, keyboardOverlap - view.safeAreaInsets.bottom)
        let spansWindow = view.bounds.width > 0
        && keyboardFrame.width >= view.bounds.width * UX.floatingKeyboardWidthRatio
        let sitsFlushWithBottom = keyboardFrame.maxY >= view.bounds.maxY - 8
        let isFloatingKeyboard = UIDevice.current.userInterfaceIdiom == .pad
        && !(spansWindow && sitsFlushWithBottom)
        let isHardwareKeyboardMode = session?.isInHardwareKeyboardMode() == true

        let inset = (isFloatingKeyboard || isHardwareKeyboardMode) ? 0 : keyboardInset
        applyKeyboardInset(inset, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        applyKeyboardInset(0, notification: notification)
    }

    private func applyKeyboardInset(_ inset: CGFloat, notification: Notification) {
        guard let keyboardBottomConstraint,
              abs(keyboardBottomConstraint.constant + inset) > 0.5 else {
            return
        }

        if inset > 0 {
            // Gecko waits for the resize below, then scrolls the focused field into view.
            session?.zoomToFocusedInput(force: true)
        }

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        ?? UX.keyboardAnimationDuration
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        ?? UX.keyboardAnimationCurve

        keyboardBottomConstraint.constant = -inset
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [UIView.AnimationOptions(rawValue: rawCurve << 16)]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Errors

    private func showError(_ error: WebRequestError?) {
        currentError = error
        errorView.configure(error: error, canGoBack: canGoBack)
        if error != nil {
            hideSplash()
        }
    }

    private func handleErrorAction(_ action: WebContentErrorView.Action) {
        switch action {
        case .retry:
            reload()
        case .back:
            showError(nil)
            session?.goBack()
        case .acceptCertificate:
            if let currentError, session?.addCertException(for: currentError) == true {
                showError(nil)
            }
        case .continueHTTP:
            if let currentError, session?.reloadWithHttpsOnlyException(for: currentError) == true {
                showError(nil)
            }
        case .openLink(let url):
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    // MARK: - ProgressDelegate

    func onPageStart(session: GeckoSession, url: String) {
        isLoadingBlankPage = url.isEmpty || url.hasPrefix("about:blank")
    }

    func onPageStop(session: GeckoSession, success: Bool) {
        // A new session can report its initial blank page before the site
        if !isLoadingBlankPage {
            hideSplash()
        }
    }

    // MARK: - ContentDelegate

    func onFirstContentfulPaint(session: GeckoSession) {
        hideSplash()
    }

    func onPageBackgroundColorChange(session: GeckoSession, color: UIColor) {
        pageBackgroundColor = color
        view.backgroundColor = color
        setNeedsStatusBarAppearanceUpdate()
        onAppearanceChange?()
    }

    func onFullScreen(session: GeckoSession, fullScreen: Bool) {
        setFullScreen(fullScreen)
        onFullScreenChange?(fullScreen)
    }

    func onCrash(session: GeckoSession) {
        handleTermination(of: session, recoverAutomatically: false)
    }

    func onKill(session: GeckoSession) {
        handleTermination(of: session, recoverAutomatically: true)
    }

    private func handleTermination(of terminatedSession: GeckoSession, recoverAutomatically: Bool) {
        guard terminatedSession === session else {
            return
        }
        tearDownSession()
        guard isSelected else {
            // Reloads from lastURL the next time this site is selected
            return
        }
        needsSessionRecovery = true

        if recoverAutomatically {
            if sessionManager.isApplicationActive {
                recoverSession()
            }
        } else {
            showError(WebRequestError(kind: .contentCrashed, uri: lastURL))
        }
    }

    // MARK: - NavigationDelegate

    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        if let error = session.currentLoadError {
            if error != currentError {
                showError(error)
            }
            return
        }

        if currentError != nil, url != currentError?.pageURI {
            showError(nil)
        }

        guard let url, !url.isEmpty, !url.hasPrefix("about:blank") else {
            return
        }
        rememberLocation(url)
        permissionCoordinator.restorePermissions(for: session, at: url)
    }

    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        self.canGoBack = canGoBack
    }

    func onLoadError(session: GeckoSession, error: WebRequestError) -> String? {
        showError(error)
        return error.pageURI
    }

    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        switch site.route(for: request.uri) {
        case .external(let url):
            let isWebLink = url.scheme?.lowercased().hasPrefix("http") == true
            // Navigations of the page itself stay in the app whatever the host
            // (sign-in flows hop across hosts); links that ask for a new window,
            // as chat sites do for links in answers, open in Safari.
            if isWebLink, request.target == .current {
                return .allow
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return .deny
        case .inApp:
            // target=_blank and window.open continue to onNewSession (popup window)
            return .allow
        }
    }

    func onNewSession(session: GeckoSession, uri: String, windowId: String, target: LoadRequestTarget) async -> GeckoSession? {
        if case .external(let url) = site.route(for: uri) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return nil
        }

        popupViewController?.close()
        let popupSession = sessionManager.createSession(
            url: uri,
            tabID: nil,
            isPrivate: false,
            opening: .external,
            delegates: SessionDelegates()
        )
        permissionCoordinator.restorePermissions(for: popupSession, at: uri)
        let popup = SitePopupViewController(
            session: popupSession,
            sessionManager: sessionManager,
            initialURL: uri
        )
        popupViewController = popup
        // Gecko opens the returned session with the requested window id; present right after.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.topPresenter.present(popup, animated: true)
        }
        return popupSession
    }

    private var topPresenter: UIViewController {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    // MARK: - Downloads

    func onExternalResponse(session: GeckoSession, response: ExternalResponseInfo) async -> Bool {
        let fallbackName = URL(string: response.url)?.lastPathComponent
        let name = [response.filename, fallbackName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "/" } ?? "download"
        pendingDownloads[response.localFilePath] = name
        sessionManager.retainExternalResponse(for: session)
        return true
    }

    func onExternalResponseProgress(session: GeckoSession, localFilePath: String, bytesReceived: Int64) -> Bool {
        return pendingDownloads[localFilePath] != nil
    }

    func onExternalResponseComplete(session: GeckoSession, localFilePath: String, succeeded: Bool) {
        sessionManager.releaseExternalResponse(for: session)
        guard let name = pendingDownloads.removeValue(forKey: localFilePath), succeeded else {
            return
        }
        presentDownloadedFile(at: localFilePath, named: name)
    }

    private func presentDownloadedFile(at path: String, named name: String) {
        let fileManager = FileManager.default
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(safeName)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: URL(fileURLWithPath: path), to: destination)
        } catch {
            NSLog("Site download: failed to prepare %@: %@", safeName, "\(error)")
            return
        }

        let activity = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
        let presenter = topPresenter
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}
