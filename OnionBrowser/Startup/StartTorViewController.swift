//
//  StartTorViewController.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 11.10.23.
//  Copyright © 2023 Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import IPtProxyUI

class StartTorViewController: UIViewController, BridgesConfDelegate {

	@IBOutlet weak var titleLb: UILabel! {
		didSet {
			titleLb.text = NSLocalizedString("Starting Tor…", comment: "")
		}
	}

	@IBOutlet weak var activityIndicator: UIActivityIndicatorView!

	@IBOutlet weak var retryBt: UIButton! {
		didSet {
			retryBt.setTitle(NSLocalizedString("Retry", comment: ""))
		}
	}

	@IBOutlet weak var progressView: UIProgressView!

	@IBOutlet weak var statusLb: UILabel!

	@IBOutlet weak var bridgesBt: UIButton! {
		didSet {
			bridgesBt.setTitle(NSLocalizedString("Configure Bridges", comment: ""))
		}
	}


	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		retry()
	}


	// MARK: BridgesConfDelegate

	var transport: IPtProxyUI.Transport {
		get {
			Settings.transport
		}
		set {
			Settings.transport = newValue
		}
	}

	var customBridges: [String]? {
		get {
			Settings.customBridges
		}
		set {
			Settings.customBridges = newValue
		}
	}

	var countryCode: String? {
		get {
			Settings.countryCode
		}
		set {
			Settings.countryCode = newValue
		}
	}

	func save() {
		TorManager.shared.updateConfig(Settings.transport)
	}


	// MARK: Actions

	@IBAction
	func retry() {
		activityIndicator.isHidden = false
		retryBt.isHidden = true
		progressView.progress = 0
		statusLb.isHidden = true

		TorManager.shared.start(Settings.transport) { [weak self] progress, summary in
			guard let progress = progress else {
				return
			}

			Task {
				await MainActor.run {
					self?.progressView.setProgress(Float(progress) / 100, animated: true)

					UIAccessibility.post(notification: .announcement, argument: String(format: "%d%%", progress))

					if let summary = summary, !summary.isEmpty {
						self?.statusLb.text = summary
						self?.statusLb.textColor = .label
						self?.statusLb.isHidden = false
					}
					else {
						self?.statusLb.isHidden = true
					}
				}
			}
		} _: { [weak self] error in
			Task {
				guard error == nil else {
					await MainActor.run {
						self?.activityIndicator.isHidden = true
						self?.retryBt.isHidden = false
						self?.statusLb.text = (error ?? TorManager.Errors.noSocksAddr).localizedDescription
						self?.statusLb.textColor = .systemRed
						self?.statusLb.isHidden = false

						UIAccessibility.post(notification: .announcement, argument: self?.statusLb.text)
					}

					return
				}

				await MainActor.run {
					// Tor is now started and torSocks5 should be available.
					// Reinitialize webviews so the scheme handler is registered,
					// then reload. ensureProxyAndReload will handle the refresh
					// after reinit, so no need to call both separately.
					AppDelegate.shared?.allOpenTabs.forEach { tab in
						tab.reinitWebView()
					}
					// Give the reinit a moment to settle, then ensure proxy + reload.
					Task {
						try? await Task.sleep(nanoseconds: 500_000_000)
						await MainActor.run {
							AppDelegate.shared?.allOpenTabs.forEach { tab in
								tab.ensureProxyAndReload()
							}
						}
					}

					// Update chrome to show green icon now that Tor is started.
					AppDelegate.shared?.sceneDelegates.forEach { delegate in
						delegate.browsingUi.updateChrome()
					}

					// Force show the browser UI -- don't re-check status which
					// could race and return StartTorViewController again.
					self?.view.sceneDelegate?.show(nil)
				}
			}
		}
	}

	@IBAction
	func configureBridges() {
		let vc = BridgesConfViewController()
		vc.delegate = self

		present(UINavigationController(rootViewController: vc))
	}
}
