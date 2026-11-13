//
//  SiteViewController.swift
//  Reynard
//
//  Single-site shell: one full-screen GeckoSession pinned to
//  SiteConfiguration.current, with no browser chrome.
//

import GeckoView
import UIKit

final class SiteViewController: UIViewController, ContentDelegate, NavigationDelegate, ProgressDelegate, UIGestureRecognizerDelegate {
    private enum UX {
        static let progressHeight: CGFloat = 2
        static let backSwipeDistance: CGFloat = 80
        static let backSwipeVelocity: CGFloat = 500
        static let floatingKeyboardWidthRatio: CGFloat = 0.8
        static let keyboardAnimationDuration: TimeInterval = 0.25
        static let keyboardAnimationCurve: UInt = 7
    }

    let configuration: SiteConfiguration
    let sessionManager = SessionManager()

    private let geckoView = GeckoView()
    private let errorView = WebContentErrorView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let promptCoordinator = PromptCoordinator(presenter: PromptPresenter())
    private let permissionCoordinator = PermissionCoordinator(promptPresenter: PermissionPromptPresenter())
    private let selectionActionCoordinator = SelectionActionCoordinator(
        presenter: SelectionActionPresenter(
            onMenuDismissed: { _ in },
            onFindInPage: { _, _ in }
        )
    )

    private let bridge: SiteBridge?
    private weak var popupViewController: SitePopupViewController?
    private var pendingDownloads: [String: String] = [:]

    private var session: GeckoSession?
    private var lastURL: String?
    private var canGoBack = false
    private var currentError: WebRequestError?
    private var needsSessionRecovery = false
    private var isFullScreen = false
    private var pageBackgroundColor: UIColor = .systemBackground

    private var normalConstraints: [NSLayoutConstraint] = []
    private var fullScreenConstraints: [NSLayoutConstraint] = []
    private var keyboardBottomConstraint: NSLayoutConstraint?

    // MARK: - Lifecycle

    init(configuration: SiteConfiguration) {
        self.configuration = configuration
        self.bridge = SiteBridge.supports(configuration) ? SiteBridge() : nil
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

        RuntimePreferences.apply() // Gecko prefs
        bridge?.start()

        configureHierarchy()
        configureBackSwipe()
        observeKeyboard()
        startSession(loading: configuration.startURL.absoluteString)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = session?.focusForHardwareKeyboard()
    }

    // MARK: - Scene Lifecycle (called by SceneDelegate)

    func setApplicationForeground(_ isForeground: Bool) {
        sessionManager.setApplicationForeground(isForeground)
    }

    func applicationDidBecomeActive() {
        sessionManager.applicationDidBecomeActive()
        bridge?.applicationDidBecomeActive()
        if needsSessionRecovery {
            recoverSession()
        }
    }

    func applicationWillResignActive() {
        sessionManager.applicationWillResignActive()
        bridge?.applicationWillResignActive()
    }

    func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        loadViewIfNeeded()
        session?.load(url.absoluteString)
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
        bridge?.attach(to: session)
        sessionManager.open(session)
        geckoView.session = session
        sessionManager.activate(session)
        self.session = session
        needsSessionRecovery = false
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
    }

    private func recoverSession() {
        tearDownSession()
        showError(nil)
        startSession(loading: lastURL ?? configuration.startURL.absoluteString)
    }

    // MARK: - Layout

    private func configureHierarchy() {
        geckoView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false

        errorView.isHidden = true
        errorView.onAction = { [weak self] action in
            self?.handleErrorAction(action)
        }

        progressView.trackTintColor = .clear
        progressView.alpha = 0

        view.addSubview(geckoView)
        view.addSubview(errorView)
        view.addSubview(progressView)

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

            progressView.topAnchor.constraint(equalTo: geckoView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: geckoView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: geckoView.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: UX.progressHeight),
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

    // MARK: - Back Swipe

    private func configureBackSwipe() {
        let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackSwipe(_:)))
        let isRightToLeft = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        recognizer.edges = isRightToLeft ? .right : .left
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
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
        guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
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
            setProgressVisible(false)
        }
    }

    private func handleErrorAction(_ action: WebContentErrorView.Action) {
        switch action {
        case .retry:
            if session == nil || needsSessionRecovery {
                recoverSession()
            } else {
                showError(nil)
                session?.reload()
            }
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
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Progress

    private func setProgressVisible(_ visible: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.progressView.alpha = visible ? 1 : 0
        }
    }

    func onPageStart(session: GeckoSession, url: String) {
        progressView.setProgress(0.1, animated: false)
        setProgressVisible(true)
    }

    func onProgressChange(session: GeckoSession, progress: Int) {
        progressView.setProgress(Float(progress) / 100, animated: true)
    }

    func onPageStop(session: GeckoSession, success: Bool) {
        progressView.setProgress(1, animated: true)
        setProgressVisible(false)
    }

    // MARK: - ContentDelegate

    func onPageBackgroundColorChange(session: GeckoSession, color: UIColor) {
        pageBackgroundColor = color
        view.backgroundColor = color
        setNeedsStatusBarAppearanceUpdate()
    }

    func onFullScreen(session: GeckoSession, fullScreen: Bool) {
        setFullScreen(fullScreen)
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
        lastURL = url
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
        switch configuration.route(for: request.uri) {
        case .external(let url):
            let isWebLink = url.scheme?.lowercased().hasPrefix("http") == true
            // Server redirects and script hops (sign-in flows) stay in the app;
            // links the user taps to other websites open in Safari.
            if isWebLink, request.isRedirect || !(request.hasUserGesture || request.target != .current) {
                return .allow
            }
            UIApplication.shared.open(url)
            return .deny
        case .inApp:
            // target=_blank and window.open continue to onNewSession (popup window)
            return .allow
        }
    }

    func onNewSession(session: GeckoSession, uri: String, windowId: String, target: LoadRequestTarget) async -> GeckoSession? {
        if case .external(let url) = configuration.route(for: uri) {
            UIApplication.shared.open(url)
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
