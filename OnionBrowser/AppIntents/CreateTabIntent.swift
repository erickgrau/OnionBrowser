//
//  OpenLocationIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 21.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.createTab)
struct CreateTabIntent: AppIntent {

	static var openAppWhenRun = true

	@Parameter
	var url: URL?

	@Parameter(description: "Ignored")
	var isPrivate: Bool


	@MainActor
	func perform() async throws -> some ReturnsValue<TabEntity> {
		if let url = url {
			self.url = Self.upgradeUrlIfNecessary(url)
		}

		guard let tab = AppDelegate.shared?.browsingUis.first?.addNewTab(url?.withFixedScheme) else {
			throw AppIntentErrors.failedToCreateTab
		}

		tab.isHidden = false

		var entity = TabEntity.getEntity(for: tab)

		if entity == nil {
			entity = TabEntity.add(tab: tab)
		}

		return .result(value: entity!)
	}


	/**
	 If we're configured to deny insecure HTTP requests, we automatically upgrade to HTTPS, because
	 that scheme was probably added by iOS automatically.

	 Otherwise users will get confused, why their request isn't executed.
	 */
	static func upgradeUrlIfNecessary(_ url: URL) -> URL {
		let hs = HostSettings.for(url.host)

		if hs.blockInsecureHttp && url.isHttp && !url.isOnion {
			if var urlc = URLComponents(url: url, resolvingAgainstBaseURL: false) {
				urlc.scheme = "https"

				if let url = urlc.url {
					return url
				}
			}
		}

		return url
	}
}
