//
//  CloseTabsIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 22.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.closeTabs)
struct CloseTabsIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var target: [TabEntity]


	@MainActor
	func perform() async throws -> some IntentResult {
		let tabIds = target.map { $0.id }

		for browsingUi in AppDelegate.shared?.browsingUis ?? [] {
			for tab in browsingUi.tabs.filter({ tabIds.contains($0.hash) }) {
				browsingUi.removeTab(tab)
			}
		}

		return .result()
	}
}
