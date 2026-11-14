//
//  SitePopupViewController.swift
//  Reynard
//
//  Full-screen window for pages the site opens with window.open / target=_blank
//  (sign-in with Google or Apple, payment pages). Keeps the opener relationship,
//  so OAuth popups can report back to the site and close themselves.
//

import GeckoView
import UIKit

final class SitePopupViewController: UIViewController, ContentDelegate, NavigationDelegate, ProgressDelegate {
    private enum UX {
        static let barHeight: CGFloat = 44
        static let horizontalInset: CGFloat = 12
    }

    let session: GeckoSession
    private let sessionManager: SessionManager
    private let geckoView = GeckoView()
    private let topBar = UIView()
    private let separator = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let promptCoordinator = PromptCoordinator(presenter: PromptPresenter())
    private let permissionCoordinator = PermissionCoordinator(promptPresenter: PermissionPromptPresenter())
    private var keyboardBottomConstraint: NSLayoutConstraint?
    private var hasClosedSession = false

    var onClose: (() -> Void)?

    init(session: GeckoSession, sessionManager: SessionManager, initialURL: String) {
        self.session = session
        self.sessionManager = sessionManager
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        titleLabel.text = URL(string: initialURL)?.host
        sessionManager.bindDelegates(
            to: session,
            delegates: SessionDelegates(
                content: self,
                navigation: self,
                permission: permissionCoordinator,
                progress: self,
                prompt: promptCoordinator
            )
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureHierarchy()
        observeKeyboard()

        if session.isOpen() {
            geckoView.session = session
            sessionManager.activate(session)
        }
    }

    // MARK: - Layout

    private func configureHierarchy() {
        [topBar, separator, titleLabel, doneButton, geckoView, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        topBar.backgroundColor = .secondarySystemBackground
        separator.backgroundColor = .separator

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let prefersHebrew = Locale.preferredLanguages.first?.hasPrefix("he") == true
        doneButton.setTitle(prefersHebrew ? "סגור" : "Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        view.addSubview(topBar)
        topBar.addSubview(titleLabel)
        topBar.addSubview(doneButton)
        view.addSubview(separator)
        view.addSubview(geckoView)
        topBar.addSubview(spinner)

        let keyboardBottom = geckoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        keyboardBottomConstraint = keyboardBottom

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: UX.barHeight),

            doneButton.leadingAnchor.constraint(equalTo: topBar.safeAreaLayoutGuide.leadingAnchor, constant: UX.horizontalInset),
            doneButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            doneButton.heightAnchor.constraint(equalToConstant: UX.barHeight),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: doneButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -(UX.horizontalInset + 60)),

            separator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            geckoView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            geckoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geckoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardBottom,

            spinner.trailingAnchor.constraint(equalTo: topBar.safeAreaLayoutGuide.trailingAnchor, constant: -UX.horizontalInset),
            spinner.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
        ])
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
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        let inset = session.isInHardwareKeyboardMode() ? 0 : overlap
        if inset > 0 {
            session.zoomToFocusedInput(force: true)
        }
        keyboardBottomConstraint?.constant = -inset
        view.layoutIfNeeded()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardBottomConstraint?.constant = 0
        view.layoutIfNeeded()
    }

    // MARK: - Closing

    @objc private func doneTapped() {
        close()
    }

    func close() {
        closeSessionIfNeeded()
        if presentingViewController != nil {
            dismiss(animated: true)
        }
        onClose?()
        onClose = nil
    }

    private func closeSessionIfNeeded() {
        guard !hasClosedSession else {
            return
        }
        hasClosedSession = true
        geckoView.endEditing(true)
        geckoView.session = nil
        sessionManager.close(session)
    }

    // MARK: - ContentDelegate

    func onCloseRequest(session: GeckoSession) {
        close()
    }

    func onCrash(session: GeckoSession) {
        close()
    }

    func onKill(session: GeckoSession) {
        close()
    }

    func onTitleChange(session: GeckoSession, title: String) {
        if !title.isEmpty {
            titleLabel.text = title
        }
    }

    // MARK: - ProgressDelegate

    func onPageStart(session: GeckoSession, url: String) {
        spinner.startAnimating()
    }
    
    func onPageStop(session: GeckoSession, success: Bool) {
        spinner.stopAnimating()
    }
    
    // MARK: - NavigationDelegate

    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        guard let url, let host = URL(string: url)?.host else {
            return
        }
        if titleLabel.text?.isEmpty ?? true {
            titleLabel.text = host
        }
        permissionCoordinator.restorePermissions(for: session, at: url)
    }

    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        // Sign-in flows hop across many hosts, so any web page stays in the popup;
        // only app links (tel:, mailto:, ...) leave it.
        if let url = URL(string: request.uri),
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "javascript"].contains(scheme) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return .deny
        }

        guard request.target != .current else {
            return .allow
        }
        session.load(request.uri)
        return .deny
    }
}
