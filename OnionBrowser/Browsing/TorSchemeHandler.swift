//
//  TorSchemeHandler.swift
//  OnionBrowser
//
//  Bypasses the broken iOS 27 ProxyConfiguration API for WKWebView
//  by intercepting requests via WKURLSchemeHandler with custom schemes
//  (torhttp:// and torhttps://) and routing them through Tor's SOCKS5
//  proxy using URLSession.
//

import WebKit
import Network

@available(iOS 17.0, *)
class TorSchemeHandler: NSObject, WKURLSchemeHandler {

    private let lock = NSLock()
    private var activeTasks: [Int: URLSessionTask] = [:]
    private var session: URLSession?

    // Custom schemes that map to http and https
    static let torHttpScheme = "torhttp"
    static let torHttpsScheme = "torhttps"

    /// JavaScript snippet injected at document start to intercept fetch/XHR
    /// and rewrite http/https URLs to our custom scheme.
    static let interceptionScript: String = """
    (function() {
        var TOR_HTTP = '\(torHttpScheme)';
        var TOR_HTTPS = '\(torHttpsScheme)';

        function rewriteURL(url) {
            if (typeof url !== 'string') return url;
            try {
                if (url.indexOf('https://') === 0) {
                    return TOR_HTTPS + url.substring(4);
                }
                if (url.indexOf('http://') === 0) {
                    return TOR_HTTP + url.substring(3);
                }
                if (url.indexOf('//') === 0) {
                    return TOR_HTTPS + ':' + url;
                }
            } catch(e) {}
            return url;
        }

        // Intercept fetch()
        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function(input, init) {
                try {
                    if (typeof input === 'string') {
                        input = rewriteURL(input);
                    } else if (input instanceof Request) {
                        var rewritten = rewriteURL(input.url);
                        if (rewritten !== input.url) {
                            input = new Request(rewritten, {
                                method: input.method,
                                headers: input.headers,
                                body: input.body,
                                mode: input.mode,
                                credentials: input.credentials,
                                cache: input.cache,
                                redirect: input.redirect,
                                referrer: input.referrer,
                                integrity: input.integrity
                            });
                        }
                    }
                } catch(e) {}
                return origFetch.call(window, input, init);
            };
        }

        // Intercept XMLHttpRequest
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
            try {
                if (typeof url === 'string') {
                    url = rewriteURL(url);
                }
            } catch(e) {}
            return origOpen.call(this, method, url, async !== undefined ? async : true, user, password);
        };

        // Intercept window.location assignment
        var origLocationDescriptor = Object.getOwnPropertyDescriptor(window.Location.prototype, 'href');
        if (origLocationDescriptor && origLocationDescriptor.set) {
            var origSet = origLocationDescriptor.set;
            Object.defineProperty(window.Location.prototype, 'href', {
                set: function(val) {
                    try {
                        val = rewriteURL(val);
                    } catch(e) {}
                    origSet.call(this, val);
                },
                get: origLocationDescriptor.get,
                configurable: true
            });
        }

        // Intercept <a> element click via document-level listener (capture)
        document.addEventListener('click', function(e) {
            var a = e.target.closest ? e.target.closest('a') : null;
            if (a && a.href) {
                var rewritten = rewriteURL(a.href);
                if (rewritten !== a.href) {
                    // Let the browser handle it - we just prevent and re-navigate
                    e.preventDefault();
                    window.location.href = rewritten;
                }
            }
        }, true);
    })();
    """

    /// Convert a standard http/https URL to our custom scheme
    static func toTorURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme else { return nil }
        let torScheme: String
        switch scheme {
        case "http": torScheme = torHttpScheme
        case "https": torScheme = torHttpsScheme
        default: return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = torScheme
        return components?.url
    }

    /// Convert our custom scheme URL back to standard http/https
    static func toStandardURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme else { return nil }
        let standardScheme: String?
        switch scheme {
        case torHttpScheme: standardScheme = "http"
        case torHttpsScheme: standardScheme = "https"
        default: return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = standardScheme
        return components?.url
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Convert torhttp/torhttps back to http/https for the actual fetch
        guard let realURL = Self.toStandardURL(url) else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }

        guard let session = getSession() else {
            urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
            return
        }

        // Build a new request with the real URL
        var request = URLRequest(url: realURL)
        request.httpMethod = urlSchemeTask.request.httpMethod ?? "GET"
        // Copy safe headers, avoiding ones that would break the proxy fetch
        if let headers = urlSchemeTask.request.allHTTPHeaderFields {
            for (key, value) in headers {
                // Skip Host header - URLSession will set it from the URL
                if key.lowercased() == "host" { continue }
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.httpBody = urlSchemeTask.request.httpBody

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            self.removeTask(urlSchemeTask.hash)

            if let error = error {
                // Don't log cancellation errors (happen on page navigation)
                if (error as NSError).code != URLError.cancelled.rawValue {
                    print("[TorSchemeHandler] Fetch error for \(realURL.absoluteString): \(error.localizedDescription)")
                }
                urlSchemeTask.didFailWithError(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }

            // Rewrite any Location header to use our custom scheme
            var modifiedHeaders = httpResponse.allHeaderFields
            if let location = modifiedHeaders["Location"] as? String {
                let rewritten = Self.rewriteLocationHeader(location, baseURL: realURL)
                if rewritten != location {
                    modifiedHeaders["Location"] = rewritten
                }
            }

            // Rewrite Content-Security-Policy to allow our custom scheme
            if let csp = modifiedHeaders["Content-Security-Policy"] as? String {
                let modifiedCSP = Self.rewriteCSP(csp)
                modifiedHeaders["Content-Security-Policy"] = modifiedCSP
            }

            // Convert [AnyHashable: Any] to [String: String] for HTTPURLResponse
            var stringHeaders: [String: String] = [:]
            for (key, value) in modifiedHeaders {
                if let key = key as? String, let value = value as? String {
                    stringHeaders[key] = value
                }
            }

            let modifiedResponse = HTTPURLResponse(
                url: url, // Keep the custom scheme URL
                statusCode: httpResponse.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stringHeaders
            )!

            // For HTML responses, rewrite subresource URLs
            var finalData = data ?? Data()
            let contentType = (stringHeaders["Content-Type"] ?? stringHeaders["content-type"] ?? "").lowercased()
            let isHTML = contentType.contains("text/html") || contentType.contains("application/xhtml+xml")
            let isCSS = contentType.contains("text/css")

            if isHTML, let htmlString = String(data: finalData, encoding: .utf8) {
                let rewritten = Self.rewriteHTMLURLs(in: htmlString, baseURL: realURL)
                if let rewrittenData = rewritten.data(using: .utf8) {
                    finalData = rewrittenData
                }
            } else if isCSS, let cssString = String(data: finalData, encoding: .utf8) {
                let rewritten = Self.rewriteCSSURLs(in: cssString, baseURL: realURL)
                if let rewrittenData = rewritten.data(using: .utf8) {
                    finalData = rewrittenData
                }
            }

            // Update Content-Length to match potentially modified data
            if stringHeaders["Content-Length"] != nil {
                stringHeaders["Content-Length"] = String(finalData.count)
            }
            // Remove Transfer-Encoding to avoid confusion with chunked encoding
            stringHeaders.removeValue(forKey: "Transfer-Encoding")
            stringHeaders.removeValue(forKey: "transfer-encoding")

            // Rebuild response with updated headers
            let finalResponse = HTTPURLResponse(
                url: url,
                statusCode: httpResponse.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stringHeaders
            )!

            urlSchemeTask.didReceive(finalResponse)
            urlSchemeTask.didReceive(finalData)
            urlSchemeTask.didFinish()
        }

        addTask(urlSchemeTask.hash, task)
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        if let task = removeTask(urlSchemeTask.hash) {
            task.cancel()
        }
    }

    // MARK: - Task Management (thread-safe)

    private func addTask(_ hash: Int, _ task: URLSessionTask) {
        lock.lock()
        activeTasks[hash] = task
        lock.unlock()
    }

    private func removeTask(_ hash: Int) -> URLSessionTask? {
        lock.lock()
        let task = activeTasks.removeValue(forKey: hash)
        lock.unlock()
        return task
    }

    // MARK: - Session Management

    private func getSession() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }

        if let session = session {
            return session
        }

        guard let proxy = TorManager.shared.torSocks5 else {
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: proxy)]
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let session = URLSession(configuration: config)
        self.session = session
        return session
    }

    /// Called when Tor restarts or SOCKS5 port changes.
    func resetSession() {
        lock.lock()
        let s = session
        session = nil
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        lock.unlock()
        s?.invalidateAndCancel()
    }

    // MARK: - URL Rewriting

    /// Rewrite http/https URLs in HTML to use our custom scheme.
    /// Handles: src, href, action, poster, data-src, srcset, inline style url(),
    /// <style> blocks, and protocol-relative URLs.
    private static func rewriteHTMLURLs(in html: String, baseURL: URL) -> String {
        var result = html

        // 1. Rewrite all URL attributes with a regex approach
        // Matches: attr="url", attr='url', attr=url (unquoted)
        let urlAttrPattern = #"\b(src|href|action|poster|data-src|data-href|data-url|data-bg|data-background|data-original|data-lazy|data-lazy-src|data-lazy-srcset|data-srcset|srcset|cite|longdesc|usemap|profile|formaction|background|manifest|codebase|data|archive)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#

        if let regex = try? NSRegularExpression(pattern: urlAttrPattern, options: .caseInsensitive) {
            let nsRange = NSRange(html.startIndex..., in: html)
            var matches: [(NSTextCheckingResult, String)] = []
            regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
                guard let match = match else { return }
                // Extract the URL value from whichever group matched
                let urlValue: String
                let grp2 = match.range(at: 2)
                let grp3 = match.range(at: 3)
                let grp4 = match.range(at: 4)
                if grp2.location != NSNotFound, let r = Range(grp2, in: html) {
                    urlValue = String(html[r])
                } else if grp3.location != NSNotFound, let r = Range(grp3, in: html) {
                    urlValue = String(html[r])
                } else if grp4.location != NSNotFound, let r = Range(grp4, in: html) {
                    urlValue = String(html[r])
                } else {
                    return
                }

                let rewritten = rewriteSingleURL(urlValue, baseURL: baseURL)
                if rewritten != urlValue {
                    matches.append((match, rewritten))
                }
            }

            // Replace from end to start to keep indices valid
            for (match, rewritten) in matches.reversed() {
                let grpRange: NSRange
                if match.range(at: 2).location != NSNotFound {
                    grpRange = match.range(at: 2)
                } else if match.range(at: 3).location != NSNotFound {
                    grpRange = match.range(at: 3)
                } else {
                    grpRange = match.range(at: 4)
                }
                if let r = Range(grpRange, in: result) {
                    result.replaceSubrange(r, with: rewritten)
                }
            }
        }

        // 2. Handle srcset specially (can have multiple URLs with descriptors)
        result = rewriteSrcset(result, baseURL: baseURL)

        // 3. Rewrite inline style="url(...)" attributes
        result = rewriteInlineStyles(result, baseURL: baseURL)

        // 4. Rewrite <style>...</style> blocks (CSS content)
        result = rewriteStyleBlocks(result, baseURL: baseURL)

        // 5. Rewrite <base> tag if present, or add one
        result = addOrUpdateBaseTag(result, baseURL: baseURL)

        return result
    }

    /// Rewrite a single URL string (absolute, protocol-relative, or relative)
    /// to use our custom scheme.
    private static func rewriteSingleURL(_ url: String, baseURL: URL) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return url }

        // Absolute http/https URL
        if trimmed.hasPrefix("https://") {
            return torHttpsScheme + "://" + trimmed.dropFirst("https://".count)
        }
        if trimmed.hasPrefix("http://") {
            return torHttpScheme + "://" + trimmed.dropFirst("http://".count)
        }

        // Protocol-relative URL (//example.com/path)
        if trimmed.hasPrefix("//") {
            return torHttpsScheme + "://" + trimmed.dropFirst(2)
        }

        // Skip data: URLs, blob: URLs, javascript: URLs, mailto:, etc.
        if trimmed.hasPrefix("data:") || trimmed.hasPrefix("blob:")
            || trimmed.hasPrefix("javascript:") || trimmed.hasPrefix("mailto:")
            || trimmed.hasPrefix("about:") || trimmed.hasPrefix("tel:")
            || trimmed.hasPrefix("torhttp://") || trimmed.hasPrefix("torhttps://") {
            return url
        }

        // Relative URL (e.g. /path, ./path, ../path, path)
        // Resolve against baseURL and then convert
        if let resolved = URL(string: trimmed, relativeTo: baseURL),
           let torURL = toTorURL(resolved) {
            // Only rewrite if it resolves to http/https
            if resolved.scheme == "http" || resolved.scheme == "https" {
                return torURL.absoluteString
            }
        }

        return url
    }

    /// Rewrite srcset attributes, which have format: "url1 1x, url2 2x" or "url1 100w, url2 200w"
    private static func rewriteSrcset(_ html: String, baseURL: URL) -> String {
        let pattern = #"srcset\s*=\s*(?:"([^"]*)"|'([^']*)')"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        var result = html
        let nsRange = NSRange(html.startIndex..., in: html)
        var matches: [(NSTextCheckingResult, String)] = []

        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match else { return }

            let valueRange: NSRange
            if match.range(at: 1).location != NSNotFound {
                valueRange = match.range(at: 1)
            } else if match.range(at: 2).location != NSNotFound {
                valueRange = match.range(at: 2)
            } else {
                return
            }

            guard let r = Range(valueRange, in: html) else { return }
            let srcsetValue = String(html[r])

            // Split by comma, rewrite each URL
            let entries = srcsetValue.components(separatedBy: ",")
            let rewrittenEntries = entries.map { entry -> String in
                let parts = entry.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                if parts.isEmpty { return entry }
                let rewrittenURL = rewriteSingleURL(parts[0], baseURL: baseURL)
                if parts.count > 1 {
                    return rewrittenURL + " " + parts[1...].joined(separator: " ")
                }
                return rewrittenURL
            }
            let rewritten = rewrittenEntries.joined(separator: ", ")
            matches.append((match, rewritten))
        }

        for (match, rewritten) in matches.reversed() {
            let valueRange: NSRange
            if match.range(at: 1).location != NSNotFound {
                valueRange = match.range(at: 1)
            } else {
                valueRange = match.range(at: 2)
            }
            if let r = Range(valueRange, in: result) {
                result.replaceSubrange(r, with: rewritten)
            }
        }

        return result
    }

    /// Rewrite url() references in inline style="..." attributes
    private static func rewriteInlineStyles(_ html: String, baseURL: URL) -> String {
        let pattern = #"style\s*=\s*(?:"([^"]*)"|'([^']*)')"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        var result = html
        let nsRange = NSRange(html.startIndex..., in: html)
        var matches: [(NSTextCheckingResult, String)] = []

        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match else { return }

            let valueRange: NSRange
            if match.range(at: 1).location != NSNotFound {
                valueRange = match.range(at: 1)
            } else if match.range(at: 2).location != NSNotFound {
                valueRange = match.range(at: 2)
            } else {
                return
            }

            guard let r = Range(valueRange, in: html) else { return }
            let styleValue = String(html[r])
            let rewritten = rewriteCSSURLs(in: styleValue, baseURL: baseURL)
            if rewritten != styleValue {
                matches.append((match, rewritten))
            }
        }

        for (match, rewritten) in matches.reversed() {
            let valueRange: NSRange
            if match.range(at: 1).location != NSNotFound {
                valueRange = match.range(at: 1)
            } else {
                valueRange = match.range(at: 2)
            }
            if let r = Range(valueRange, in: result) {
                result.replaceSubrange(r, with: rewritten)
            }
        }

        return result
    }

    /// Rewrite url() references in <style>...</style> blocks
    private static func rewriteStyleBlocks(_ html: String, baseURL: URL) -> String {
        let pattern = #"<style[^>]*>([\s\S]*?)</style>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        var result = html
        let nsRange = NSRange(html.startIndex..., in: html)
        var matches: [(NSTextCheckingResult, String)] = []

        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges > 1 else { return }
            guard let r = Range(match.range(at: 1), in: html) else { return }
            let cssContent = String(html[r])
            let rewritten = rewriteCSSURLs(in: cssContent, baseURL: baseURL)
            if rewritten != cssContent {
                matches.append((match, rewritten))
            }
        }

        for (match, rewritten) in matches.reversed() {
            if let r = Range(match.range(at: 1), in: result) {
                result.replaceSubrange(r, with: rewritten)
            }
        }

        return result
    }

    /// Rewrite url() references in CSS content (both inline and external).
    /// Handles: url(...), @import "..." / url(...), @font-face src
    private static func rewriteCSSURLs(in css: String, baseURL: URL) -> String {
        var result = css

        // Rewrite url(...) patterns: url("..."), url('...'), url(...)
        let urlPattern = #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]+))\s*\)"#

        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let nsRange = NSRange(result.startIndex..., in: result)
            var matches: [(NSTextCheckingResult, String)] = []

            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match else { return }

                var urlValue: String = ""
                var valueRange: NSRange = NSRange(location: NSNotFound, length: 0)

                if match.range(at: 1).location != NSNotFound {
                    valueRange = match.range(at: 1)
                    if let r = Range(valueRange, in: result) { urlValue = String(result[r]) }
                    else { return }
                } else if match.range(at: 2).location != NSNotFound {
                    valueRange = match.range(at: 2)
                    if let r = Range(valueRange, in: result) { urlValue = String(result[r]) }
                    else { return }
                } else if match.range(at: 3).location != NSNotFound {
                    valueRange = match.range(at: 3)
                    if let r = Range(valueRange, in: result) { urlValue = String(result[r]) }
                    else { return }
                } else {
                    return
                }

                // Skip data: URLs
                if urlValue.hasPrefix("data:") || urlValue.hasPrefix("blob:") {
                    return
                }

                let rewritten = rewriteSingleURL(urlValue, baseURL: baseURL)
                if rewritten != urlValue {
                    matches.append((match, rewritten))
                }
            }

            for (match, rewritten) in matches.reversed() {
                let valueRange: NSRange
                if match.range(at: 1).location != NSNotFound {
                    valueRange = match.range(at: 1)
                } else if match.range(at: 2).location != NSNotFound {
                    valueRange = match.range(at: 2)
                } else {
                    valueRange = match.range(at: 3)
                }
                if let r = Range(valueRange, in: result) {
                    result.replaceSubrange(r, with: rewritten)
                }
            }
        }

        // Rewrite @import "..." or @import url("...") patterns
        let importPattern = #"@import\s+(?!url\()[\"']([^\"']+)[\"']"#

        if let regex = try? NSRegularExpression(pattern: importPattern, options: .caseInsensitive) {
            let nsRange = NSRange(result.startIndex..., in: result)
            var matches: [(NSTextCheckingResult, String)] = []

            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges > 1 else { return }
                guard let r = Range(match.range(at: 1), in: result) else { return }
                let importURL = String(result[r])

                if importURL.hasPrefix("data:") { return }

                let rewritten = rewriteSingleURL(importURL, baseURL: baseURL)
                if rewritten != importURL {
                    matches.append((match, rewritten))
                }
            }

            for (match, rewritten) in matches.reversed() {
                if let r = Range(match.range(at: 1), in: result) {
                    result.replaceSubrange(r, with: rewritten)
                }
            }
        }

        return result
    }

    /// Add or update the <base> tag so relative URLs resolve against the
    /// tor-scheme version of the page's origin.
    private static func addOrUpdateBaseTag(_ html: String, baseURL: URL) -> String {
        let torBaseScheme = baseURL.scheme == "https" ? torHttpsScheme : torHttpScheme
        let baseHref = "\(torBaseScheme)://\(baseURL.host ?? "")\(baseURL.path)"

        // Check if a <base> tag already exists
        if let baseRegex = try? NSRegularExpression(pattern: #"<base\s[^>]*>"#, options: .caseInsensitive) {
            let nsRange = NSRange(html.startIndex..., in: html)
            if let baseMatch = baseRegex.firstMatch(in: html, options: [], range: nsRange) {
                if let r = Range(baseMatch.range, in: html) {
                    let existing = String(html[r])
                    // If it already has our scheme, leave it
                    if existing.contains(torHttpScheme) || existing.contains(torHttpsScheme) {
                        // Could still be wrong scheme, but leave it to avoid breaking
                        return html
                    }
                    // Replace the existing <base> tag
                    let newBaseTag = "<base href=\"\(baseHref)\">"
                    var result = html
                    result.replaceSubrange(r, with: newBaseTag)
                    return result
                }
            }
        }

        // No <base> tag found, insert one after <head...>
        let baseTag = "<base href=\"\(baseHref)\">"
        if let headRange = html.range(of: "<head", options: .caseInsensitive) {
            if let closeHeadTagRange = html.range(of: ">", range: headRange) {
                var result = html
                result.insert(contentsOf: baseTag, at: closeHeadTagRange.upperBound)
                return result
            }
        }

        // No <head> tag found, try <html
        if let htmlRange = html.range(of: "<html", options: .caseInsensitive) {
            if let closeHtmlTagRange = html.range(of: ">", range: htmlRange) {
                let headWithBase = "<head>\(baseTag)</head>"
                var result = html
                result.insert(contentsOf: headWithBase, at: closeHtmlTagRange.upperBound)
                return result
            }
        }

        // Fallback: prepend
        return baseTag + html
    }

    /// Rewrite Location header value to use our custom scheme.
    private static func rewriteLocationHeader(_ location: String, baseURL: URL) -> String {
        if let locURL = URL(string: location),
           let torLocURL = toTorURL(locURL) {
            return torLocURL.absoluteString
        }
        if location.hasPrefix("/") {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = location
            components?.query = nil
            components?.fragment = nil
            if let resolved = components?.url, let torLocURL = toTorURL(resolved) {
                return torLocURL.absoluteString
            }
        }
        return location
    }

    /// Rewrite Content-Security-Policy header to allow our custom schemes.
    private static func rewriteCSP(_ csp: String) -> String {
        // Replace scheme references in CSP
        var result = csp
        // Add our schemes to any existing scheme-src directives
        result = result.replacingOccurrences(of: "https:", with: "\(torHttpsScheme):")
        result = result.replacingOccurrences(of: "http:", with: "\(torHttpScheme):")
        // Also add 'self' + scheme to default-src if not present
        // (Don't overthink it -- just make the schemes match)
        return result
    }
}
