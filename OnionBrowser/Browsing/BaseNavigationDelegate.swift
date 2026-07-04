//
//  BaseNavigationDelegate.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 15.06.26.
//  Copyright © 2026 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import WebKit

class BaseNavigationDelegate {

	class func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
					   preferences: WKWebpagePreferences) -> (url: URL, hs: HostSettings)?
	{
		guard let url = navigationAction.request.url else {
			return nil
		}

		guard OrbotManager.shared.allowRequests() else {
			return nil
		}

		if Settings.useBuiltInTor ?? false, #available(iOS 17.0, *) {
			guard !webView.configuration.websiteDataStore.proxyConfigurations.isEmpty else {
				return nil
			}
		}

		let hs = HostSettings.for(url.host)

		if hs.blockInsecureHttp && url.isHttp && !url.isOnion {
			return nil
		}

		preferences.allowsContentJavaScript = hs.javaScript

		if #available(iOS 16.0, *) {
#if DEBUG
			// There is no web-browser entitlement in debugging, and without that,
			// *disabling* lockdown mode is disallowed and we would crash here.
			// Hence, only try to enable it, if it's *not* enabled, yet, but it should.
			if !preferences.isLockdownModeEnabled && hs.lockdownMode {
				preferences.isLockdownModeEnabled = true
			}
#else
			preferences.isLockdownModeEnabled = hs.lockdownMode
#endif
		}

		return (url, hs)
	}

	class func handle(challenge: URLAuthenticationChallenge) -> URLCredential?
	{
		let space = challenge.protectionSpace

		switch space.authenticationMethod {
		case NSURLAuthenticationMethodServerTrust:
			if let serverTrust = space.serverTrust,
			   HostSettings.for(space.host).ignoreTlsErrors
			{
				return URLCredential(trust: serverTrust)
			}
			else {
				return nil
			}

		case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
			let storage = URLCredentialStorage.shared

			// If we have existing credentials for this realm, try them.
			if challenge.previousFailureCount < 1,
				let credential = storage.credentials(for: space)?.first?.value
			{
				return credential
			}

		default:
			break
		}

		return nil
	}

	class func shouldAllowDeprecatedTls(_ challenge: URLAuthenticationChallenge) -> Bool?
	{
		let space = challenge.protectionSpace

		guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust
		else {
			return false
		}

		if HostSettings.for(space.host).ignoreTlsErrors {
			return true
		}

		return nil
	}
}
