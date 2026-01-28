//
//  WebsiteStorage.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 29.07.22.
//  Copyright © 2012 - 2023, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//


import Foundation
import WebKit

class WebsiteStorage {

	static let shared = WebsiteStorage()

	private static let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

	private static let allTypesButCookies: Set<String> = {
		var types = allTypes
		types.remove(WKWebsiteDataTypeCookies)

		return types
	}()


	private let store = WKWebsiteDataStore.default()

	private lazy var localizations: [String: String] = {
		[
			WKWebsiteDataTypeFetchCache: NSLocalizedString("Fetch Cache", comment: ""),
			WKWebsiteDataTypeDiskCache: NSLocalizedString("Disk Cache", comment: ""),
			WKWebsiteDataTypeMemoryCache: NSLocalizedString("Memory Cache", comment: ""),
			WKWebsiteDataTypeOfflineWebApplicationCache: NSLocalizedString("Offline Web Application Cache", comment: ""),
			WKWebsiteDataTypeCookies: NSLocalizedString("Cookies", comment: ""),
			WKWebsiteDataTypeSessionStorage: NSLocalizedString("Session Storage", comment: ""),
			WKWebsiteDataTypeLocalStorage: NSLocalizedString("Local Storage", comment: ""),
			WKWebsiteDataTypeWebSQLDatabases: NSLocalizedString("WebSQL Databases", comment: ""),
			WKWebsiteDataTypeIndexedDBDatabases: NSLocalizedString("IndexedDB Databases", comment: ""),
			WKWebsiteDataTypeServiceWorkerRegistrations: NSLocalizedString("Service Worker Registrations", comment: ""),
		]
	}()


	private init() {
	}

	/**
	 Remove all cookies and website data for domains which are not whitelisted.
	 */
	func cleanup() {
		store.httpCookieStore.getAllCookies { cookies in
			for cookie in cookies {
				if !self.isWhitelisted(cookie.domain) {
					self.store.httpCookieStore.delete(cookie)
				}
			}
		}

		store.fetchDataRecords(ofTypes: Self.allTypes) { records in
			let toRemove = records.filter { record in
				!self.isWhitelisted(record.displayName)
			}

			self.store.removeData(ofTypes: Self.allTypes, for: toRemove) {
				// Ignore.
			}
		}
	}

	/**
	 Remove all cookies and website data for a given domain.

	 - parameter ignoreWhitelist: Remove, regardless, if the domain is whitelisted.
	 */
	func remove(for host: String, ignoreWhitelist: Bool = false) {
		store.httpCookieStore.getAllCookies { cookies in
			for cookie in cookies {
				if self.isEqual(cookie.domain, host) && (ignoreWhitelist || !self.isWhitelisted(cookie.domain)) {
					self.store.httpCookieStore.delete(cookie)
				}
			}
		}

		store.fetchDataRecords(ofTypes: Self.allTypes) { records in
			let toRemove = records.filter { record in
				self.isEqual(record.displayName, host) && (ignoreWhitelist || !self.isWhitelisted(record.displayName))
			}

			self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: toRemove) {
				// Ignore.
			}
		}
	}

	/**
	 Get a sorted list of hosts which have stored stuff.

	 - returns: List of hosts which have stored stuff.
	 */
	@MainActor
	func hosts() async -> [String] {
		let cookies = await store.httpCookieStore.allCookies()

		var hosts = Set(cookies.map({ sanitize($0.domain) }))

		for record in await store.dataRecords(ofTypes: Self.allTypesButCookies) {
			hosts.insert(sanitize(record.displayName))
		}

		return hosts.sorted()
	}

	/**
	 Get storage details for a given host.

	 - parameter host: The host to get details for.
	 - returns: A list of stuff, this host has stored.
	 */
	@MainActor
	func details(for host: String) async -> [String: Int] {
		var details = [String: Int]()

		let cookies = await store.httpCookieStore.allCookies()

		let count = cookies.filter({ isEqual($0.domain, host) }).count

		if count > 0 {
			details[NSLocalizedString("Cookies", comment: "")] = count
		}

		for record in await store.dataRecords(ofTypes: Self.allTypesButCookies) {
			if self.isEqual(record.displayName, host) {
				for type in record.dataTypes {
					let type = self.pretty(type: type)

					details[type] = details[type] ?? 0 + 1
				}
			}
		}

		return details
	}


	// MARK: Private Methods

	private func isWhitelisted(_ host: String) -> Bool {
		return HostSettings.for(sanitize(host)).whitelistCookies
	}

	private func isEqual(_ host1: String, _ host2: String) -> Bool {
		return sanitize(host1) == sanitize(host2)
	}

	private func sanitize(_ host: String) -> String {
		var host = host

		if host.first == "." {
			host.removeFirst()
		}

		return host.lowercased()
	}

	private func pretty(type: String) -> String {
		if let localized = localizations[type] {
			return localized
		}

		var type = type

		if type.starts(with: "WKWebsiteDataType") {
			type.removeFirst(17)
		}

		return type
	}
}
