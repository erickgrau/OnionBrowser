//
//  TabEntity.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 22.10.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import AppIntents

@available(iOS 18.0, *)
@AppEntity(schema: .browser.tab)
struct TabEntity: AppEntity {

	struct Query: EntityStringQuery {
		func entities(for identifiers: [TabEntity.ID]) async throws -> [TabEntity] {
			return await AppDelegate.shared?.allOpenTabs
				.filter({ identifiers.contains($0.hash) })
				.map { TabEntity($0) } ?? []
		}

		@MainActor
		func entities(matching string: String) async throws -> [TabEntity] {
			return AppDelegate.shared?.allOpenTabs
				.filter({ $0.url.absoluteString.contains(string) || $0.title.contains(string) })
				.map({ TabEntity($0) }) ?? []
		}
	}

	private static var tabShadow = [TabEntity]()

	@discardableResult
	static func addTab(_ tab: Tab) -> TabEntity {
		let entity = TabEntity(tab)

		tabShadow.append(entity)

		return entity
	}

	static func removeTab(withId id: Int) {
		tabShadow.removeAll(where: { $0.id == id })
	}

	static func getEntity(for tab: Tab) -> TabEntity? {
		return tabShadow.first { $0.id == tab.hash }
	}

	static var defaultQuery = Query()


	var displayRepresentation: AppIntents.DisplayRepresentation {
		AppIntents.DisplayRepresentation(stringLiteral: "\(name)")
	}

	let id: Int

	@Property
	var url: URL?

	@Property
	var name: String

	@Property
	var isPrivate: Bool

	private init(_ tab: Tab) {
		id = tab.hash
		url = tab.url
		name = tab.title
		isPrivate = true
	}
}
