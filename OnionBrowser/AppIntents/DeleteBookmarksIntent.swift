//
//  DeleteBookmarksIntent.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 03.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppIntent(schema: .browser.deleteBookmarks)
struct DeleteBookmarksIntent: AppIntent {

	static var openAppWhenRun = true


	@Parameter
	var entities: [BookmarkEntity]


	@MainActor
	func perform() async throws -> some IntentResult {
		let ids = entities.map { $0.id }
		let urls = entities.map { $0.url.absoluteString }

		try await recurse(NcBookmarks.root, ids, urls)

		NcBookmarks.store()

		return .result()
	}


	private func recurse(_ folder: NcFolder, _ ids: [Int], _ urls: [String]) async throws {
		let toDelete = folder.bookmarks.filter {
			($0.id != nil && ids.contains($0.id!)) || ($0.id == nil && urls.contains($0.url))
		}

		for bookmark in toDelete {
			try await NcServer.delete(bookmark)

			if let idx = folder.bookmarks.firstIndex(of: bookmark) {
				folder.bookmarks.remove(at: idx)
			}

			BookmarkEntity.remove(bookmark: bookmark)
		}

		for folder in folder.folders {
			try await recurse(folder, ids, urls)
		}
	}
}
