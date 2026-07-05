//
//  Tab.swift
//  OnionBrowser2
//
//  Created by Benjamin Erhart on 22.11.19.
//  Copyright © 2012 - 2023, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import QuickLook
import WebKit
import ObjectiveC

protocol TabDelegate: AnyObject {
	func updateChrome()

	func addNewTab(_ url: URL?, configuration: WKWebViewConfiguration?) -> Tab?

	func addNewTab(_ url: URL?,
				   transition: BrowsingViewController.Transition,
				   configuration: WKWebViewConfiguration?,
				   completion: ((Bool) -> Void)?) -> Tab?

	func removeTab(_ tab: Tab, focus: Tab?)

	func getTab(ipcId: String?) -> Tab?

	func getTab(hash: Int?) -> Tab?

	func getIndex(of tab: Tab) -> Int?

	@discardableResult
	func present(_ vc: UIViewController, _ sender: UIView?) -> Bool

	func unfocusSearchField()
}

class Tab: UIView {

	@objc
	enum SecureMode: Int {
		case insecure
		case mixed
		case secure
		case secureEv
	}

	/**
	 Some sites do mobile detection by looking for Safari in the UA, so make us look like Mobile Safari

	 from "Mozilla/5.0 (iPhone; CPU iPhone OS 8_4_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Mobile/12H321"
	 to   "Mozilla/5.0 (iPhone; CPU iPhone OS 8_4_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Version/8.0 Mobile/12H321 Safari/600.1.4"
	 */
	static var defaultUserAgent = "" {
		didSet {
			var uaparts = defaultUserAgent.components(separatedBy: " ")

			// Assume Safari major version will match iOS major.
			let osv = UIDevice.current.systemVersion.components(separatedBy: ".")
			let index = (uaparts.endIndex) - 1
			uaparts.insert("Version/\(osv.first ?? "0").0", at: index)

			// Now tack on "Safari/XXX.X.X" from WebKit version.
			for p in uaparts {
				if p.contains("AppleWebKit/") {
					uaparts.append(p.replacingOccurrences(of: "AppleWebKit", with: "Safari"))
					break
				}
			}

			defaultUserAgent = uaparts.joined(separator: " ")
		}
	}


	weak var tabDelegate: TabDelegate?

	var title: String {
		if let downloadedFile = downloadedFile {
			return downloadedFile.lastPathComponent
		}

		if let title = webView?.title, !title.isEmpty {
			return title
		}

		return BrowsingViewController.prettyTitle(url)
	}

	var parentId: Int?

	var ipcId: String?

	@objc
	var url = URL.start

	@objc
	var index: Int {
		return tabDelegate?.getIndex(of: self) ?? -1
	}

	var needsRefresh = false

	var applicableUrlBlockerRules = Set<String>()

	var tlsCertificate: TlsCertificate? {
		didSet {
			if tlsCertificate == nil {
				secureMode = .insecure
			}
			else if tlsCertificate?.isEv ?? false {
				secureMode = .secureEv
			}
			else {
				secureMode = .secure
			}

			Task {
				await MainActor.run {
					tabDelegate?.updateChrome()
				}
			}
		}
	}

	var secureMode = SecureMode.insecure

	@nonobjc
	var progress: Float = 0 {
		didSet {
			Task {
				await MainActor.run {
					tabDelegate?.updateChrome()
				}
			}
		}
	}

	static let historySize = 40
	var skipHistory = false

	var history = [HistoryViewController.Item]()

	override var isUserInteractionEnabled: Bool {
		didSet {
			if previewController != nil {
				if isUserInteractionEnabled {
					overlay.removeFromSuperview()
				}
				else {
					overlay.add(to: self)
				}
			}
		}
	}

	#if DEBUG
	@available(iOS 17.0, *)
	var hasTorSchemeHandler: Bool {
		return conf.urlSchemeHandler(forURLScheme: TorSchemeHandler.torHttpsScheme) != nil
	}
	#endif

	private var _conf: WKWebViewConfiguration?
	private var conf: WKWebViewConfiguration {
		get {
			if let conf = _conf {
				return conf
			}

			let conf = WKWebViewConfiguration()
			conf.allowsAirPlayForMediaPlayback = true
			conf.allowsInlineMediaPlayback = true
			conf.allowsPictureInPictureMediaPlayback = true

			// BUGFIX #438: Popups already have a configuration from their parent tab,
			// injecting this a second time crashes the app.
			setupJsInjections(conf)

			_conf = conf
			return conf
		}
		set {
			_conf = newValue
		}
	}
	/**
	 https://www.hackingwithswift.com/articles/112/the-ultimate-guide-to-wkwebview
	 */
	private(set) var webView: WKWebView?

	var scrollView: UIScrollView? {
		return webView?.scrollView
	}

	weak var scrollViewDelegate: UIScrollViewDelegate? {
		didSet {
			scrollView?.delegate = scrollViewDelegate
		}
	}

	var canGoBack: Bool {
		return  parentId != nil || webView?.canGoBack ?? false
	}

	var canGoForward: Bool {
		return webView?.canGoForward ?? false
	}

	var isLoading: Bool {
	// BUGFIX: Sometimes, isLoading still shows true, even if progress is already at 100%.
	// So check that, too, to fix reload/cancel button display.
	return (webView?.isLoading ?? false) && progress < 1
	}

	/// Timestamp of the last navigation start. Used to enforce a timeout
	/// so the webview doesn't spin forever on unreachable sites.
	var loadStartTime: Date?

	var previewController: QLPreviewController?

	/**
	 Add another overlay (a hack to create a transparant clickable view)
	 to disable interaction with the file preview when used in the tab overview.
	 */
	private(set) lazy var overlay: UIView = {
		let view = UIView()
		view.backgroundColor = .white
		view.alpha = 0.11
		view.isUserInteractionEnabled = false

		return view
	}()

	var downloadedFile: URL?

	private(set) lazy var refresher: UIRefreshControl = {
		let refresher = UIRefreshControl()

		refresher.attributedTitle = NSAttributedString(string: NSLocalizedString("Pull to Refresh Page", comment: ""))

		return refresher
	}()

	private var snapshot: UIImage?

	private var closing = false


	init(restorationId: String?, configuration: WKWebViewConfiguration? = nil) {
		super.init(frame: .zero)

		if restorationId != nil {
			restorationIdentifier = restorationId
			needsRefresh = true
		}

		if let configuration = configuration {
			conf = configuration
		}

		setup()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)

		setup()
	}

	override func observeValue(forKeyPath keyPath: String?, of object: Any?,
							   change: [NSKeyValueChangeKey : Any]?,
							   context: UnsafeMutableRawPointer?)
	{
		if keyPath == "estimatedProgress" {
			progress = Float(webView?.estimatedProgress ?? 0)
		}
	}

	// MARK: Public Methods

	@objc
	func refresh() {
		if url == URL.start || url == URL.aboutSecurityLevels {
			NcBookmarks.updateStartPage()
		}

		needsRefresh = false
		skipHistory = true

		if webView?.url != nil {
			webView?.reload()
		}
		else {
			load(url)
		}
	}

	func stop() {
		webView?.stopLoading()

		// Seems not to update correctly via the #observeValue path.
		progress = 1
	}

	@objc
	func load(_ url: URL?) {
		var request: URLRequest?

		if let url = url?.withFixedScheme?.real, !url.absoluteString.isEmpty {
			request = URLRequest(url: url)
		}

		load(request)
	}

	func load(_ request: URLRequest?) {
		Task {
			await MainActor.run {
				webView?.stopLoading()
			}
		}

		reset(request?.url)

		var request = request ?? URLRequest(url: URL.start)

		// If webView doesn't exist yet (e.g. setup() returned early waiting
		// for Tor), create it now — Tor should be running by the time
		// the user tries to load a URL.
		if webView == nil {
			setup()
		}

		// Rewrite http/https URLs to our custom scheme so TorSchemeHandler
		// intercepts them and routes through Tor's SOCKS5 proxy.
		if #available(iOS 17.0, *), Settings.useBuiltInTor == true,
		   let url = request.url, let torURL = TorSchemeHandler.toTorURL(url) {
			request.url = torURL
			print("[OnionBrowser] Rewrote URL to \(torURL.absoluteString)")
		}

		// https://globalprivacycontrol.github.io/gpc-spec/
		if Settings.sendGpc {
			request.setValue("1", forHTTPHeaderField: "Sec-GPC")
		}

		if let url = request.url {
			if url == URL.start || url == URL.aboutSecurityLevels {
				NcBookmarks.updateStartPage()
			}
			else if let bookmark = NcBookmarks.find(url) {
				Task {
					if await bookmark.acquireIcon() {
						NcBookmarks.store()
					}
				}
			}

			self.url = url
		}

		Task {
			await MainActor.run {
				var userAgent = HostSettings.for(request.url?.host).userAgent

				if userAgent.isEmpty {
					userAgent = Self.defaultUserAgent
				}

				if !userAgent.isEmpty {
					webView?.customUserAgent = userAgent
				}

				loadStartTime = Date()
				webView?.load(request)

				// Timeout: if the page hasn't finished loading in 30 seconds,
				// stop the webview and show an error. This prevents the infinite
				// X/refresh flip when the SOCKS5 proxy can't reach the site.
				Task {
					try? await Task.sleep(nanoseconds: 30_000_000_000)
					await MainActor.run {
						guard let start = loadStartTime,
						      Date().timeIntervalSince(start) >= 29 else { return }
						if webView?.isLoading ?? false && progress < 1 {
							webView?.stopLoading()
							progress = 1
							loadStartTime = nil
						}
					}
				}
			}
		}
	}

	@objc
	func search(for query: String?) {
		return load(LiveSearchViewController.constructRequest(query))
	}

	func reset(_ url: URL? = nil) {
		// Only delete this, when scheme or host is differently,
		// to not loose certificate information and blocker rules again.
		if self.url.scheme != url?.scheme || self.url.host != url?.host {
			applicableUrlBlockerRules.removeAll()
			tlsCertificate = nil
		}

		self.url = url ?? URL.start
	}

	@objc
	func goBack() {
		if webView?.canGoBack ?? false {
			skipHistory = true
			webView?.goBack()
		}
		else if let parentId = parentId {
			tabDelegate?.removeTab(self, focus: tabDelegate?.getTab(hash: parentId))
		}
	}

	@objc
	func goForward() {
		if webView?.canGoForward ?? false {
			skipHistory = true
			webView?.goForward()
		}
	}

	func toggleFind(searchText: String? = nil) {
		if #available(iOS 16.0, *) {
			webView?.isFindInteractionEnabled = !((webView?.isFindInteractionEnabled ?? false) && webView?.findInteraction?.isFindNavigatorVisible ?? false)

			if webView?.isFindInteractionEnabled ?? false {
				webView?.findInteraction?.presentFindNavigator(showingReplace: false)
				webView?.findInteraction?.searchText = searchText
			}
		}
	}

	@discardableResult
	@MainActor
	func stringByEvaluatingJavaScript(from script: String) async -> String? {
		guard let webView else {
			return nil
		}

		let result: Any?

		do {
			result = try await webView.evaluateJavaScript(script)
		}
		catch {
			Log.error(for: Self.self, "#stringByEvaluatingJavaScript error=\(error)")
			result = nil
		}

		return result as? String
	}

	/**
	Call this before giving up the tab, otherwise memory leaks will occur!
	*/
	func close() {
		// Avoid closing loops which might crash the app.
		if closing {
			return
		}

		closing = true

		cancelDownload()

		Thread.performOnMain {
			self.tabDelegate = nil

			self.destructWebView()

			self.removeFromSuperview()
		}
	}

	@MainActor
	func empty() {
		self.stop()

		Task {
			// Will empty the webView, but keep the URL and doesn't create a history entry.
			await self.stringByEvaluatingJavaScript(from: "document.open()")
		}

		self.needsRefresh = true
	}

	func getSnapshot(size: CGSize) -> UIImage? {
		if snapshot == nil, let scrollView = scrollView {
			let offset = scrollView.contentOffset
			let frame = scrollView.frame

			scrollView.contentOffset = .zero
			scrollView.frame = CGRect(
				x: 0, y: 0,
				width: scrollView.contentSize.width,
				height: scrollView.contentSize.height)

			snapshot = scrollView.layer.makeSnapshot(scale: 1.0)?.topCropped(newSize: size)

			scrollView.contentOffset = offset
			scrollView.frame = frame
		}

		return snapshot
	}

	func clearSnapshot() {
		snapshot = nil
	}

	func reinitWebView() {
	destructWebView()
	setup()

	needsRefresh = true
	}

	/// Retry setting up the proxy connection and reload if needed.
	/// Called when Tor finishes bootstrapping after the webview was already created.
	/// Guard against re-entrant reinit to avoid webview recreation loops.
	private var isEnsuringProxy = false

	func ensureProxyAndReload() {
		if #available(iOS 17.0, *), Settings.useBuiltInTor == true {
			// Check if our scheme handler is registered. If not, reinit.
			let hasScheme = conf.urlSchemeHandler(forURLScheme: TorSchemeHandler.torHttpsScheme) != nil
			if !hasScheme && !isEnsuringProxy {
				isEnsuringProxy = true
				print("[OnionBrowser] Scheme handler not registered, reinitializing...")
				reinitWebView()
				isEnsuringProxy = false
			}
		}
		if needsRefresh {
			refresh()
		}
	}


	private func setupConnection() {
		if #available(iOS 17.0, *), Settings.useBuiltInTor == true {
			print("[OnionBrowser] setupConnection: useBuiltInTor=true, torSocks5=\(TorManager.shared.torSocks5 ?? .none)")

			if TorManager.shared.torSocks5 != nil {
				// Only register if not already registered (avoids crash:
				// "URL scheme already has a registered URL schemeHandler")
				if conf.urlSchemeHandler(forURLScheme: TorSchemeHandler.torHttpsScheme) == nil {
					let schemeHandler = TorSchemeHandler()
					conf.setURLSchemeHandler(schemeHandler, forURLScheme: TorSchemeHandler.torHttpScheme)
					conf.setURLSchemeHandler(schemeHandler, forURLScheme: TorSchemeHandler.torHttpsScheme)

					// Store reference so we can reset it when Tor restarts.
					objc_setAssociatedObject(self, &Self.schemeHandlerKey, schemeHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

					print("[OnionBrowser] TorSchemeHandler registered for \(TorSchemeHandler.torHttpScheme) and \(TorSchemeHandler.torHttpsScheme)")
				} else {
					print("[OnionBrowser] TorSchemeHandler already registered, skipping")
				}
				return
			}

			// Tor not ready yet. Retry in 1 second until Tor is ready.
			print("[OnionBrowser] Tor SOCKS5 not yet available, scheduling retry...")
			Task {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
				await MainActor.run {
					if TorManager.shared.torSocks5 != nil {
						// Tor is ready. Reinit webview so scheme handler is
						// registered on the config before creation.
						reinitWebView()
						if needsRefresh { refresh() }
					} else {
						// Tor still not ready, retry again.
						setupConnection()
					}
				}
			}
		} else {
			print("[OnionBrowser] setupConnection: useBuiltInTor=\(String(describing: Settings.useBuiltInTor))")
		}
	}

	private static var schemeHandlerKey: UInt8 = 0

	private func setup() {
	    setupConnection()

	    webView = WKWebView(frame: .zero, configuration: conf)

#if DEBUG
		if #available(iOS 16.4, *) {
			webView?.isInspectable = true
		}
#endif

		webView?.uiDelegate = self
		webView?.navigationDelegate = self
		scrollView?.delegate = scrollViewDelegate

		webView?.add(to: self)

		webView?.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

		setupGestureRecognizers()

		if Self.defaultUserAgent.isEmpty {
			Task {
				let ua = await stringByEvaluatingJavaScript(from: "navigator.userAgent")

				if let ua = ua, !ua.isEmpty {
					Self.defaultUserAgent = ua
				}
			}
		}

		// Immediately refresh the page if its host settings were changed, so
		// users sees the impact of their changes.
		NotificationCenter.default.addObserver(self, selector: #selector(hostSettingsChanged),
											   name: .hostSettingsChanged, object: nil)
	}

	private func destructWebView() {
		NotificationCenter.default.removeObserver(self)

		scrollView?.delegate = nil
		webView?.uiDelegate = nil
		webView?.navigationDelegate = nil

		removeGestureRecognizers()

		stop()
		webView?.loadHTMLString("", baseURL: nil)

		webView?.removeFromSuperview()
		webView = nil

		// Clear cached configuration so reinitWebView creates a fresh one
		// with the correct proxy settings.
		_conf = nil
	}

	@objc
	private func hostSettingsChanged(_ notification: Notification) {
		let host = notification.object as? String

		// Refresh on default changes and specific changes for this host.
		if host == nil || host == self.url.host {
			self.refresh()
		}
	}


	deinit {
		close()
	}
}
