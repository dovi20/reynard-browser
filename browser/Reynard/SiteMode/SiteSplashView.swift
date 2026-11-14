//
//  SiteSplashView.swift
//  Reynard
//
//  Loading screen for site apps: continues the launch screen (same background)
//  with the icon and a spinner until the site has painted, instead of a
//  browser-style progress line.
//

import UIKit

final class SiteSplashView: UIView {
    private enum UX {
        static let iconSide: CGFloat = 96
        static let iconCornerRatio: CGFloat = 0.225
        static let spinnerSpacing: CGFloat = 28
        static let fadeDuration: TimeInterval = 0.25
    }

    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var hideToken = 0

    init(icon: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = UIColor(named: "LaunchBackground") ?? .systemBackground
        isUserInteractionEnabled = true

        iconView.image = icon
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = UX.iconSide * UX.iconCornerRatio
        iconView.layer.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -UX.spinnerSpacing),
            iconView.widthAnchor.constraint(equalToConstant: UX.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: UX.iconSide),

            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: UX.spinnerSpacing),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var icon: UIImage? {
        get { return iconView.image }
        set { iconView.image = newValue }
    }

    var isShowing: Bool {
        return !isHidden
    }

    func show() {
        hideToken += 1
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        spinner.startAnimating()
    }

    func hide(animated: Bool = true) {
        guard !isHidden else {
            return
        }
        hideToken += 1
        let token = hideToken

        guard animated else {
            finishHiding()
            return
        }
        UIView.animate(withDuration: UX.fadeDuration, animations: {
            self.alpha = 0
        }, completion: { _ in
            // A show() during the fade wins
            if self.hideToken == token {
                self.finishHiding()
            }
        })
    }

    private func finishHiding() {
        spinner.stopAnimating()
        isHidden = true
        alpha = 1
    }
}
