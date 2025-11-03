//
//  BookmarkUrlIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 03.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.bookmarkURL)
struct BookmarkUrlIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var name: String?

	@Parameter
	var url: URL


	@MainActor
	func perform() async throws -> some ReturnsValue<BookmarkEntity> {
		let bookmark = NcBookmark(url: CreateTabIntent.upgradeUrlIfNecessary(url).absoluteString, title: name ?? url.host ?? "")

		NcBookmarks.root.bookmarks.append(bookmark)

		_ = try await bookmark.upload()

		_ = await bookmark.acquireIcon()

		NcBookmarks.store()

		return .result(value: BookmarkEntity.add(bookmark: bookmark))
	}
}
