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
    /// URLSession tasks keyed by the scheme task's identity.
    private var activeTasks: [ObjectIdentifier: URLSessionTask] = [:]
    /// Scheme tasks WebKit has not stopped yet. Calling didReceive/didFinish/
    /// didFailWithError on a stopped WKURLSchemeTask throws NSInternal-
    /// InconsistencyException, so every callback must be guarded by this set.
    private var liveTasks: Set<ObjectIdentifier> = []
    private var session: URLSession?

    // MARK: - Response cache

    /// One cached page/subresource: the rewritten data WebKit expects, the
    /// custom-scheme response, and when it was fetched.
    private struct CacheEntry {
        let date: Date
        let response: HTTPURLResponse
        let data: Data
    }

    /// In-memory cache shared across all tabs, keyed by custom-scheme URL.
    /// Lets a page come straight back after an app switch — WebKit reloads
    /// when iOS reclaims its content process, and Tor may be mid-restart, so
    /// serving from cache keeps the page consistent without a round trip.
    /// Memory-only on purpose: no .onion content is written to disk.
    private static let cacheLock = NSLock()
    private static var responseCache: [String: CacheEntry] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheMaxEntries = 400
    private static let cacheMaxBytes = 64 * 1024 * 1024
    private static var cacheBytes = 0

    /// How long a cached response is served before refetching. Matches the
    /// "cache for 24 hours" ask; overridable via Settings.torCacheSeconds.
    static var cacheTTL: TimeInterval {
        Settings.torCacheSeconds
    }

    private static func cachedResponse(for key: String) -> (HTTPURLResponse, Data)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = responseCache[key] else { return nil }

        if Date().timeIntervalSince(entry.date) > cacheTTL {
            responseCache[key] = nil
            cacheOrder.removeAll { $0 == key }
            cacheBytes -= entry.data.count
            return nil
        }

        return (entry.response, entry.data)
    }

    private static func store(_ response: HTTPURLResponse, _ data: Data, for key: String) {
        // Only cache successful, non-empty GET-style bodies, and only when
        // caching is enabled.
        guard cacheTTL > 0,
              (200...299).contains(response.statusCode), !data.isEmpty,
              data.count < cacheMaxBytes / 4
        else {
            return
        }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let existing = responseCache[key] {
            cacheBytes -= existing.data.count
            cacheOrder.removeAll { $0 == key }
        }

        responseCache[key] = CacheEntry(date: Date(), response: response, data: data)
        cacheOrder.append(key)
        cacheBytes += data.count

        // Evict oldest until back under both limits.
        while cacheOrder.count > cacheMaxEntries || cacheBytes > cacheMaxBytes,
              let oldest = cacheOrder.first {
            if let e = responseCache[oldest] { cacheBytes -= e.data.count }
            responseCache[oldest] = nil
            cacheOrder.removeFirst()
        }
    }

    /// Drop all cached .onion content (called when the user clears data).
    static func clearCache() {
        cacheLock.lock()
        responseCache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        cacheLock.unlock()
    }

    // Custom schemes that map to http and https
    static let torHttpScheme = "torhttp"
    static let torHttpsScheme = "torhttps"

    /// JavaScript snippet injected at document start to intercept fetch/XHR
    /// and rewrite http/https URLs to our custom scheme.
    static let interceptionScript: String = """
    (function() {
        // Only activate on .onion pages. Regular pages use normal networking.
        if (!window.location.hostname || !window.location.hostname.endsWith('.onion')) {
            return;
        }

        var TOR_HTTP = '\(torHttpScheme)';
        var TOR_HTTPS = '\(torHttpsScheme)';

        function rewriteURL(url) {
            if (typeof url !== 'string') return url;
            try {
                // Only .onion targets go through Tor; leave clearnet alone.
                // Replace just the scheme prefix — earlier code used the wrong
                // substring offsets and produced 'torhttpss://' / 'torhttpp://'
                // (unsupported URL) on every rewritten link.
                if (url.indexOf('https://') === 0) {
                    if (url.indexOf('.onion', 8) === -1 && url.indexOf('.onion/', 8) === -1) return url;
                    return TOR_HTTPS + '://' + url.substring(8);
                }
                if (url.indexOf('http://') === 0) {
                    if (url.indexOf('.onion', 7) === -1 && url.indexOf('.onion/', 7) === -1) return url;
                    return TOR_HTTP + '://' + url.substring(7);
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

        print("[TorSchemeHandler] start: \(url.absoluteString)")

        // Convert torhttp/torhttps back to http/https for the actual fetch
        guard let realURL = Self.toStandardURL(url) else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }

        let cacheKey = url.absoluteString
        let isReloadable = (urlSchemeTask.request.httpMethod ?? "GET").uppercased() == "GET"

        // Serve from cache for GETs unless the user forced a reload
        // (Cache-Control: no-cache is set by our reload path). This keeps a
        // page consistent across app switches and works even while Tor is
        // still restarting.
        let noCache = (urlSchemeTask.request.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().contains("no-cache")

        if isReloadable, !noCache, let (response, data) = Self.cachedResponse(for: cacheKey) {
            print("[TorSchemeHandler] cache hit: \(cacheKey)")
            let id = ObjectIdentifier(urlSchemeTask)
            addLiveOnly(id)
            DispatchQueue.main.async {
                guard self.finishTask(id) else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
            return
        }

        guard let session = getSession() else {
            print("[TorSchemeHandler] No Tor session for \(url.absoluteString)")
            // Last resort: if Tor isn't up yet but we have any cached copy,
            // serve it rather than failing.
            if isReloadable, let (response, data) = Self.cachedResponse(for: cacheKey) {
                let id = ObjectIdentifier(urlSchemeTask)
                addLiveOnly(id)
                DispatchQueue.main.async {
                    guard self.finishTask(id) else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
                return
            }
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
        if request.httpBody == nil {
            // WebKit delivers large/multipart bodies (file uploads) as a stream.
            request.httpBodyStream = urlSchemeTask.request.httpBodyStream
        }

        let id = ObjectIdentifier(urlSchemeTask)

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            // WKURLSchemeTask methods must run on the thread that called
            // start(urlSchemeTask:) — main. Dispatching there also serializes
            // the liveness check with stop(urlSchemeTask:).
            DispatchQueue.main.async {
                guard let self = self, self.finishTask(id) else {
                    // WebKit already stopped this task; touching it would throw.
                    return
                }

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

                // URLSession follows redirects transparently, so the page we
                // got may live at a different URL than requested. All rewriting
                // must resolve against the final URL, or every relative link on
                // a redirected page breaks.
                let finalURL = httpResponse.url ?? realURL

                print("[TorSchemeHandler] response: \(finalURL.absoluteString) status=\(httpResponse.statusCode) size=\(data?.count ?? 0)")

                // Rewrite any Location header to use our custom scheme
                var modifiedHeaders = httpResponse.allHeaderFields
                if let location = modifiedHeaders["Location"] as? String {
                    let rewritten = Self.rewriteLocationHeader(location, baseURL: finalURL)
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

                // For HTML responses, rewrite subresource URLs to use our custom
                // scheme so subresources on .onion pages also go through Tor.
                // Only rewrite URLs that resolve to .onion hosts -- external
                // resources (CDNs, etc.) load normally through WKWebView.
                var finalData = data ?? Data()
                let contentType = (stringHeaders["Content-Type"] ?? stringHeaders["content-type"] ?? "").lowercased()
                let isHTML = contentType.contains("text/html") || contentType.contains("application/xhtml+xml")
                let isCSS = contentType.contains("text/css")

                if isHTML, let htmlString = String(data: finalData, encoding: .utf8) {
                    let rewritten = Self.rewriteHTMLURLs(in: htmlString, baseURL: finalURL)
                    if let rewrittenData = rewritten.data(using: .utf8) {
                        finalData = rewrittenData
                    }
                } else if isCSS, let cssString = String(data: finalData, encoding: .utf8) {
                    let rewritten = Self.rewriteCSSURLs(in: cssString, baseURL: finalURL)
                    if let rewrittenData = rewritten.data(using: .utf8) {
                        finalData = rewrittenData
                    }
                }

                // URLSession already decompressed the body and dechunked the
                // stream. Forwarding these headers with the decoded data makes
                // WebKit try to decode again — gzip on plain HTML fails and
                // the page renders blank.
                for key in ["Content-Encoding", "content-encoding",
                            "Transfer-Encoding", "transfer-encoding",
                            "Content-Length", "content-length"] {
                    stringHeaders.removeValue(forKey: key)
                }
                stringHeaders["Content-Length"] = String(finalData.count)

                let finalResponse = HTTPURLResponse(
                    url: url, // Keep the custom scheme URL WebKit asked for
                    statusCode: httpResponse.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stringHeaders
                )!

                // Cache the fully-rewritten payload so returning to the page
                // (or a WebKit content-process reload) is instant and offline.
                if isReloadable {
                    Self.store(finalResponse, finalData, for: cacheKey)
                }

                urlSchemeTask.didReceive(finalResponse)
                urlSchemeTask.didReceive(finalData)
                urlSchemeTask.didFinish()
            }
        }

        addTask(id, task)
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        if let task = removeTask(ObjectIdentifier(urlSchemeTask)) {
            task.cancel()
        }
    }

    // MARK: - Task Management (thread-safe)

    private func addTask(_ id: ObjectIdentifier, _ task: URLSessionTask) {
        lock.lock()
        activeTasks[id] = task
        liveTasks.insert(id)
        lock.unlock()
    }

    /// Register a scheme task as live without a URLSession task, for responses
    /// served synchronously from cache. finishTask() still guards delivery
    /// against a stop() that arrives first.
    private func addLiveOnly(_ id: ObjectIdentifier) {
        lock.lock()
        liveTasks.insert(id)
        lock.unlock()
    }

    /// Marks the scheme task stopped and returns its URLSession task.
    private func removeTask(_ id: ObjectIdentifier) -> URLSessionTask? {
        lock.lock()
        let task = activeTasks.removeValue(forKey: id)
        liveTasks.remove(id)
        lock.unlock()
        return task
    }

    /// Atomically checks the scheme task is still live and retires it.
    /// Returns false if WebKit already stopped the task.
    private func finishTask(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let wasLive = liveTasks.remove(id) != nil
        activeTasks.removeValue(forKey: id)
        lock.unlock()
        return wasLive
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

        // Route through Tor's SOCKS5 proxy using the modern ProxyConfiguration
        // API with the NWEndpoint directly. The legacy connectionProxyDictionary
        // SOCKS path issues the request but never calls back on iOS 27 beta
        // (start fires, no response), which hung every .onion load. The modern
        // API is the same one TorManager.session() uses successfully.
        config.proxyConfigurations = [.init(socksv5Proxy: proxy)]
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let session = URLSession(configuration: config)
        self.session = session
        print("[TorSchemeHandler] URLSession created with SOCKS5 ProxyConfiguration at \(proxy)")
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

    /// Rewrite a single URL string to use our custom scheme.
    /// Only rewrites .onion URLs -- external URLs are left alone so they
    /// load through WKWebView's normal networking.
    private static func rewriteSingleURL(_ url: String, baseURL: URL) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return url }

        // Skip data: URLs, blob: URLs, javascript: URLs, mailto:, etc.
        if trimmed.hasPrefix("data:") || trimmed.hasPrefix("blob:")
            || trimmed.hasPrefix("javascript:") || trimmed.hasPrefix("mailto:")
            || trimmed.hasPrefix("about:") || trimmed.hasPrefix("tel:")
            || trimmed.hasPrefix("torhttp://") || trimmed.hasPrefix("torhttps://") {
            return url
        }

        // Resolve relative URLs against the base URL first. absoluteURL
        // matters: URLComponents on a relative URL wrapper sees only the
        // relative part and produces host-less garbage like "torhttps:/path".
        let resolvedURL: URL
        if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            resolvedURL = resolved
        } else {
            return url
        }

        // Only rewrite if the resolved URL is a .onion URL
        guard resolvedURL.host?.hasSuffix(".onion") == true else {
            return url
        }

        // Convert to our custom scheme
        if let torURL = toTorURL(resolvedURL) {
            return torURL.absoluteString
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
    /// tor-scheme version of the page's origin. Only for .onion pages.
    private static func addOrUpdateBaseTag(_ html: String, baseURL: URL) -> String {
        // Only add base tag for .onion pages
        guard baseURL.host?.hasSuffix(".onion") == true else {
            return html
        }

        let torBaseScheme = baseURL.scheme == "https" ? torHttpsScheme : torHttpScheme
        let portPart = baseURL.port.map { ":\($0)" } ?? ""
        let baseHref = "\(torBaseScheme)://\(baseURL.host ?? "")\(portPart)\(baseURL.path)"

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

        // No <base> tag found, insert one after <head...>. The ">" search
        // must start AFTER the tag name — searching inside the "<head"
        // range itself never matches, which used to prepend the base tag
        // before <!DOCTYPE and put WebKit into quirks mode.
        let baseTag = "<base href=\"\(baseHref)\">"
        if let headRange = html.range(of: "<head", options: .caseInsensitive),
           let closeHeadTagRange = html.range(of: ">", range: headRange.upperBound..<html.endIndex) {
            var result = html
            result.insert(contentsOf: baseTag, at: closeHeadTagRange.upperBound)
            return result
        }

        // No <head> tag found, try <html
        if let htmlRange = html.range(of: "<html", options: .caseInsensitive),
           let closeHtmlTagRange = html.range(of: ">", range: htmlRange.upperBound..<html.endIndex) {
            let headWithBase = "<head>\(baseTag)</head>"
            var result = html
            result.insert(contentsOf: headWithBase, at: closeHtmlTagRange.upperBound)
            return result
        }

        // Fallback: prepend
        return baseTag + html
    }

    /// Rewrite Location header value to use our custom scheme.
    /// Only .onion targets are rewritten — clearnet redirect targets load
    /// through WKWebView's normal networking.
    private static func rewriteLocationHeader(_ location: String, baseURL: URL) -> String {
        guard let resolved = URL(string: location, relativeTo: baseURL)?.absoluteURL else {
            return location
        }

        guard resolved.host?.lowercased().hasSuffix(".onion") == true else {
            return location
        }

        if let torLocURL = toTorURL(resolved) {
            return torLocURL.absoluteString
        }

        return location
    }

    /// Rewrite Content-Security-Policy header to allow our custom schemes.
    /// Appends the tor schemes next to standalone scheme-source tokens
    /// ("https:" → "https: torhttps:"). Never touches host sources like
    /// "https://cdn.example.com", which must keep matching the clearnet
    /// subresources that are deliberately not rewritten.
    private static func rewriteCSP(_ csp: String) -> String {
        var result = csp

        if let regex = try? NSRegularExpression(pattern: #"(?<=^|[\s;])https:(?=[\s;]|$)"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "https: \(torHttpsScheme):")
        }

        if let regex = try? NSRegularExpression(pattern: #"(?<=^|[\s;])http:(?=[\s;]|$)"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "http: \(torHttpScheme):")
        }

        // Sites like DuckDuckGo list their own onion address as an explicit
        // https:// host source with default-src 'none' and no 'self'. Our
        // rewritten torhttps:// subresources match nothing then, and every
        // script/stylesheet is blocked. Append a tor-scheme twin next to
        // every .onion host source.
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s;]*\.onion[^\s;]*"#, options: .caseInsensitive) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)

            for match in matches.reversed() {
                guard let r = Range(match.range, in: result) else { continue }

                let source = String(result[r])
                let twin: String
                if source.lowercased().hasPrefix("https://") {
                    twin = torHttpsScheme + "://" + source.dropFirst("https://".count)
                }
                else {
                    twin = torHttpScheme + "://" + source.dropFirst("http://".count)
                }

                result.replaceSubrange(r, with: "\(source) \(twin)")
            }
        }

        return result
    }
}
