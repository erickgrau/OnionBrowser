//
//  MozillaBookmarks.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 19.11.25.
//  Copyright © 2025 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import Foundation

class MozillaBookmarks {

	static func export(_ folder: NcFolder) throws -> URL {
		var result = """
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<html>
	<head>
		<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
		<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'none'; img-src data: *; object-src 'none'">
		<title>\(Bundle.main.displayName) \(NSLocalizedString("Bookmarks", comment: ""))</title>
	</head>
	<body>

"""

		result += render(folder, level: folder.id == -1 ? 1 : 2)

		result += """
	</body>
</html>

"""

//		print(result)

		let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).last!
			.appendingPathComponent("\(NSLocalizedString("Bookmarks", comment: "")).html")

		try result.write(to: url, atomically: true, encoding: .utf8)

		return url
	}


	private static func render(_ folder: NcFolder, level: UInt8) -> String {
		let prefix = String(repeating: "\t", count: Int(level) + 1)

		var idAttr = ""

		if let id = folder.id {
			idAttr = " id=\"\(id)\""
		}

		var title = folder.title

		if title.isEmpty {
			title = NSLocalizedString("Bookmarks", comment: "")
		}

		var dtOpen = ""
		var dtClose = ""

		if level > 1 {
			dtOpen = "<dt>"
			dtClose = "</dt>"
		}

		var result = "\(prefix)\(dtOpen)<h\(level)\(idAttr)>\(title)</h\(level)>\(dtClose)\n"
		result += "\(prefix)<dl><p>\n"

		for folders in folder.folders {
			result += render(folders, level: level + 1)
		}

		if !folder.bookmarks.isEmpty {
			for bookmark in folder.bookmarks {
				result += render(bookmark, level: level)
			}
		}

		result += "\(prefix)</p></dl>\n"

		return result
	}

	private static func render(_ bookmark: NcBookmark, level: UInt8) -> String {
		let prefix = String(repeating: "\t", count: Int(level) + 2)

		var idAttr = ""

		if let id = bookmark.id {
			idAttr = " id=\"\(id)\""
		}

		var iconAttr = ""

		if let iconUrl = bookmark.iconUrl,
		   let data = try? Data(contentsOf: iconUrl)
		{
			iconAttr = " icon=\"data:image/png;base64,\(data.base64EncodedString())\""
		}

		var title = bookmark.title

		if title.isEmpty {
			title = URL(string: bookmark.url)?.host ?? ""
		}

		return "\(prefix)<dt><a\(idAttr) href=\"\(bookmark.url)\" add_date=\"\(bookmark.added)\" last_modified=\"\(bookmark.lastModified)\"\(iconAttr)>\(title)</a></dt>\n"
	}
}
