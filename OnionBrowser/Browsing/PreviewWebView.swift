//
//  PreviewWebView.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 15.06.26.
//  Copyright © 2026 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import WebKit

class PreviewWebView: WKWebView, WKNavigationDelegate {

	override init(frame: CGRect, configuration: WKWebViewConfiguration) {
		super.init(frame: frame, configuration: configuration)

		navigationDelegate = self
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)

		navigationDelegate = self
	}


	@discardableResult
	override func load(_ request: URLRequest) -> WKNavigation? {
		var userAgent = HostSettings.for(request.url?.host).userAgent

		if userAgent.isEmpty {
			userAgent = Tab.defaultUserAgent
		}

		if !userAgent.isEmpty {
			customUserAgent = userAgent
		}

		return super.load(request)
	}


	// MARK: WKNavigationDelegate

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
				 preferences: WKWebpagePreferences,
				 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void)
	{
		guard let result = BaseNavigationDelegate.webView(webView, decidePolicyFor: navigationAction, preferences: preferences)
		else {
			return decisionHandler(.cancel, preferences)
		}

		if UrlBlocker.shared.blockRule(for: result.url, withMain: self.url) != nil {
			return decisionHandler(.cancel, preferences)
		}

		decisionHandler(.allow, preferences)
	}

	func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
				 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
	{
		handle(challenge: challenge, completionHandler)
	}

	func handle(challenge: URLAuthenticationChallenge, _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
	{
		let credential = BaseNavigationDelegate.handle(challenge: challenge)
		completionHandler(credential != nil ? .useCredential : .performDefaultHandling, credential)
	}

	func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge,
				 shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void)
	{
		decisionHandler(BaseNavigationDelegate.shouldAllowDeprecatedTls(challenge) ?? false)
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		// Remove circular dependency again, so ARC will remove this object.
		navigationDelegate = nil
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
		navigationDelegate = nil
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
		navigationDelegate = nil
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		navigationDelegate = nil
	}
}
