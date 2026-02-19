//
//  FileTranslator.swift
//  OnionBrowser
//
//  Created by Benjamin Erhart on 19.02.26.
//  Copyright © 2026 Tigas Ventures, LLC (Mike Tigas). All rights reserved.
//

import Foundation

class FileTranslator {

	/**
	 Takes a `source` file, which contains placeholders identified by the regex `{{(.*)}}`, extracts all of them,
	 tries to translate the content of the placeholders and writes the result  to `dest`.

	 - parameter source: The source file. If `nil` this method will do nothing.
	 - parameter dest: The destination file.
	 - parameter tableName: The name of the translation file (without the `.strings` extension) will use `Localizable.strings` if nothing set or empty.
	 */
	class func translate(_ source: URL?, to dest: URL, with tableName: String? = nil) throws {
		guard let source else {
			return
		}

		var tmplt = try String(contentsOf: source, encoding: .utf8)
		let regex = try NSRegularExpression(pattern: "\\{\\{(.*)\\}\\}")

		var replacements = [String: String]()

		let matches = regex.matches(in: tmplt, range: .init(tmplt.startIndex ..< tmplt.endIndex, in: tmplt))

		for match in matches {
			guard let range1 = Range(match.range, in: tmplt),
				  match.numberOfRanges > 1,
				  let range2 = Range(match.range(at: 1), in: tmplt)
			else {
				continue
			}

			let placeholder = String(tmplt[range1])
			let content = tmplt[range2].trimmingCharacters(in: .whitespacesAndNewlines)

			replacements[placeholder] = NSLocalizedString(content, tableName: tableName, comment: "#bc-ignore!")
		}

		for (key, value) in replacements {
			tmplt = tmplt.replacingOccurrences(of: key, with: value)
		}

		try tmplt.write(to: dest, atomically: true, encoding: .utf8)
	}
}
