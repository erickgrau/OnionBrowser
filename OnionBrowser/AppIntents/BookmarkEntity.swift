//
//  BookmarkEntity.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 03.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppEntity(schema: .browser.bookmark)
struct BookmarkEntity: AppEntity {

	struct Query: EntityStringQuery {

		static var persistentIdentifier = "BookmarkEntityQuery"

		func entities(for identifiers: [BookmarkEntity.ID]) async throws -> [BookmarkEntity] {
			return NcBookmarks
				.find { identifiers.contains($0.id ?? Int.min) }
				.map { BookmarkEntity($0) }
		}

		@MainActor
		func entities(matching string: String) async throws -> [BookmarkEntity] {
			return NcBookmarks
				.find { $0.url.contains(string) || $0.title.contains(string) }
				.map { BookmarkEntity($0) }
		}
	}

	private static var bookmarkShadow = [BookmarkEntity]()

	@discardableResult
	static func add(bookmark: NcBookmark) -> BookmarkEntity {
		let entity = BookmarkEntity(bookmark)

		bookmarkShadow.append(entity)

		return entity
	}

	static func add(folder: NcFolder) {
		for bookmark in folder.bookmarks {
			add(bookmark: bookmark)
		}

		for folder in folder.folders {
			add(folder: folder)
		}
	}

	static func remove(bookmark: NcBookmark) {
		bookmarkShadow.removeAll(where: { bookmark.id != nil ? $0.id == bookmark.id : $0.url.absoluteString == bookmark.url })
	}

	static func getEntity(for bookmark: NcBookmark) -> BookmarkEntity? {
		return bookmarkShadow.first { $0.id == bookmark.id }
	}

	static var defaultQuery = Query()


	var displayRepresentation: AppIntents.DisplayRepresentation {
		AppIntents.DisplayRepresentation(stringLiteral: "\(name)")
	}

	let id: Int

	@Property
	var url: URL

	@Property
	var name: String


	private init(_ bookmark: NcBookmark) {
		id = bookmark.id ?? Int.min
		url = URL(string: bookmark.url)!
		name = bookmark.title
	}
}
