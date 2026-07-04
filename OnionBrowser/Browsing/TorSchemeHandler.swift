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

    private var activeTasks: [Int: URLSessionTask] = [:]
    private var session: URLSession?

    // Custom schemes that map to http and https
    static let torHttpScheme = "torhttp"
    static let torHttpsScheme = "torhttps"

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
            // Not our scheme, fail
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
        request.allHTTPHeaderFields = urlSchemeTask.request.allHTTPHeaderFields
        request.httpBody = urlSchemeTask.request.httpBody

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            self.activeTasks.removeValue(forKey: urlSchemeTask.hash)

            if let error = error {
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
                // Location can be absolute (https://...) or relative (/search?q=...)
                if let locURL = URL(string: location),
                   let torLocURL = Self.toTorURL(locURL) {
                    // Absolute URL
                    modifiedHeaders["Location"] = torLocURL.absoluteString
                } else if location.hasPrefix("/") {
                    // Relative URL -- resolve against the real URL's origin
                    var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
                    components?.path = location
                    if let resolved = components?.url, let torLocURL = Self.toTorURL(resolved) {
                        modifiedHeaders["Location"] = torLocURL.absoluteString
                    }
                }
            }

            // Rewrite Content-Security-Policy to allow our custom scheme
            if let csp = modifiedHeaders["Content-Security-Policy"] as? String {
                // Replace https: and http: in CSP with our schemes
                let modifiedCSP = csp
                    .replacingOccurrences(of: "https:", with: "\(Self.torHttpsScheme):")
                    .replacingOccurrences(of: "http:", with: "\(Self.torHttpScheme):")
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
            var finalData = data
            let contentType = stringHeaders["Content-Type"]
            if contentType?.contains("text/html") == true {
                if let htmlString = String(data: data ?? Data(), encoding: .utf8) {
                    let rewritten = Self.rewriteURLs(in: htmlString, baseURL: realURL)
                    finalData = rewritten.data(using: .utf8)
                }
            }

            urlSchemeTask.didReceive(modifiedResponse)
            urlSchemeTask.didReceive(finalData ?? Data())
            urlSchemeTask.didFinish()
        }

        activeTasks[urlSchemeTask.hash] = task
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        if let task = activeTasks.removeValue(forKey: urlSchemeTask.hash) {
            task.cancel()
        }
    }

    // MARK: - Private

    private func getSession() -> URLSession? {
        if let session = session {
            return session
        }

        guard let proxy = TorManager.shared.torSocks5 else {
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        // URLSession DOES support ProxyConfiguration correctly on iOS 27
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: proxy)]
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let session = URLSession(configuration: config)
        self.session = session
        return session
    }

    /// Rewrite http/https URLs in HTML to use our custom scheme
    private static func rewriteURLs(in html: String, baseURL: URL) -> String {
        var result = html

        // Rewrite src="https://" and href="https://" etc.
        // Use regex to find http/https URLs in src and href attributes
        let patterns = [
            #"src\s*=\s*["']https?://"#,
            #"src\s*=\s*["']//"#,
            #"href\s*=\s*["']https?://"#,
            #"href\s*=\s*["']//"#,
            #"action\s*=\s*["']https?://"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..., in: result)
                regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                    guard let match = match else { return }
                    // This is a simplified approach - full CSS/JS rewriting would be more complex
                }
            }
        }

        // Simpler approach: just replace https:// and http:// in src/href attributes
        result = result.replacingOccurrences(
            of: "src=\"https://",
            with: "src=\"\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "src=\"http://",
            with: "src=\"\(torHttpScheme)://"
        )
        result = result.replacingOccurrences(
            of: "src='https://",
            with: "src='\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "src='http://",
            with: "src='\(torHttpScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href=\"https://",
            with: "href=\"\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href=\"http://",
            with: "href=\"\(torHttpScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href='https://",
            with: "href='\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href='http://",
            with: "href='\(torHttpScheme)://"
        )

        // Also rewrite form action URLs
        result = result.replacingOccurrences(
            of: "action=\"https://",
            with: "action=\"\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "action=\"http://",
            with: "action=\"\(torHttpScheme)://"
        )
        result = result.replacingOccurrences(
            of: "action='https://",
            with: "action='\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "action='http://",
            with: "action='\(torHttpScheme)://"
        )

        // Rewrite protocol-relative URLs (//example.com -> torhttps://example.com)
        result = result.replacingOccurrences(
            of: "src=\"//",
            with: "src=\"\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "src='//",
            with: "src='\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href=\"//",
            with: "href=\"\(torHttpsScheme)://"
        )
        result = result.replacingOccurrences(
            of: "href='//",
            with: "href='\(torHttpsScheme)://"
        )

        // Add a <base> tag so relative URLs resolve correctly
        if !result.contains("<base") {
            let baseTag = "<base href=\"\(torHttpsScheme)://\(baseURL.host ?? "")\(baseURL.path)\">"
            if let headRange = result.range(of: "<head", options: .caseInsensitive) {
                if let closeHeadRange = result.range(of: ">", range: headRange) {
                    result.insert(contentsOf: baseTag, at: closeHeadRange.upperBound)
                }
            }
        }

        return result
    }

    /// Called when Tor restarts or SOCKS5 port changes.
    func resetSession() {
        session?.invalidateAndCancel()
        session = nil
    }
}
