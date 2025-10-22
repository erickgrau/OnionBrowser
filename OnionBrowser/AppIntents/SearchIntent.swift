//
//  SearchIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 22.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.search)
struct SearchWebIntent: ShowInAppSearchResultsIntent {

	static var openAppWhenRun = true
	static var searchScopes: [StringSearchScope] = [.general]


	@Parameter
	var criteria: StringSearchCriteria


	@MainActor
	func perform() async throws -> some IntentResult {
		guard let browsingUi = AppDelegate.shared?.browsingUis.first else {
			throw AppIntentErrors.uiUnavailable
		}

		if let url = browsingUi.parseSearch(criteria.term) {
			guard browsingUi.addNewTab(url) != nil else {
				throw AppIntentErrors.failedToCreateTab
			}
		}
		else {
			guard let tab = browsingUi.addNewTab() else {
				throw AppIntentErrors.failedToCreateTab
			}

			tab.search(for: criteria.term)
		}

		return .result()
	}
}
