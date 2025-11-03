//
//  OpenBookmarkIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 03.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.openBookmark)
struct OpenBookmarkIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var tab: TabEntity?

	@Parameter
	var target: BookmarkEntity


	@MainActor
	func perform() async throws -> some IntentResult {
		let url = CreateTabIntent.upgradeUrlIfNecessary(target.url).withFixedScheme

		if let tab {
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

		guard let tab = AppDelegate.shared?.browsingUis.first?.addNewTab(url?.withFixedScheme) else {
			throw AppIntentErrors.failedToCreateTab
		}

		tab.isHidden = false

		var entity = TabEntity.getEntity(for: tab)

		if entity == nil {
			entity = TabEntity.add(tab: tab)
		}

		return .result()
	}
}
