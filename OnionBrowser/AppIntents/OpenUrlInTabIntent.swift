//
//  OpenUrlInTabIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 22.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.openURLInTab)
struct OpenUrlInTabIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var tab: TabEntity

	@Parameter
	var url: URL


	@MainActor
	func perform() async throws -> some IntentResult {
		url = CreateTabIntent.upgradeUrlIfNecessary(url)

		for browsingUi in AppDelegate.shared?.browsingUis ?? [] {
			if let tab = browsingUi.tabs.first(where: { $0.hash == tab.id }),
			   let idx = browsingUi.getIndex(of: tab)
			{
				browsingUi.switchToTab(idx)
				tab.load(url)

				return .result()
			}
		}

		throw AppIntentErrors.failedToFindTab
	}
}
