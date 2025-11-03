//
//  BookmarkTabIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 03.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.bookmarkTab)
struct BookmarkTabIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var name: String?

	@Parameter
	var tab: TabEntity


	@MainActor
	func perform() async throws -> some ReturnsValue<BookmarkEntity> {
		guard let tab = AppDelegate.shared?.allOpenTabs.first(where: { $0.hash == tab.id }) else {
			throw AppIntentErrors.failedToFindTab
		}

		let bookmark = NcBookmark(url: tab.url.absoluteString, title: name ?? tab.title)

		NcBookmarks.root.bookmarks.append(bookmark)

		_ = try await bookmark.upload()

		_ = await bookmark.acquireIcon()

		NcBookmarks.store()

		return .result(value: BookmarkEntity.add(bookmark: bookmark))
	}
}
