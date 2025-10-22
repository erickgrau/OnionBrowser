//
//  SwitchToTabIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 22.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.switchTab)
struct SwitchToTabIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var target: TabEntity


	@MainActor
	func perform() async throws -> some IntentResult {
		for browsingUi in AppDelegate.shared?.browsingUis ?? [] {
			if let tab = browsingUi.tabs.first(where: { $0.hash == target.id }),
			   let idx = browsingUi.getIndex(of: tab)
			{
				browsingUi.switchToTab(idx)
			}
		}

		return .result()
	}
}
