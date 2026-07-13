import Foundation

// Port of server/tools.py: web search (DuckDuckGo HTML endpoint) + webpage reader.

enum Toolbox {

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func toolSpecs() -> [ToolSpec] {
        [
            ToolSpec(
                name: "web_search",
                description: "Search the internet. Use for anything current, factual, or outside your certain knowledge: news, weather, prices, releases, people, places.",
                parameters: [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "The search query."]],
                    "required": ["query"]
                ]
            ),
            ToolSpec(
                name: "read_webpage",
                description: "Fetch a URL and return its readable text content. Use after web_search to read a promising result in full.",
                parameters: [
                    "type": "object",
                    "properties": ["url": ["type": "string", "description": "Full http(s) URL to read."]],
                    "required": ["url"]
                ]
            ),
            ToolSpec(
                name: "look_at_screen",
                description: "Fetch the user's most recent screenshot so you can see what they are doing or looking at. Use when the user refers to their screen or current activity. Works when they took a screenshot in the last few minutes (Top button + Volume Up).",
                parameters: [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ),
            ToolSpec(
                name: "set_quiet",
                description: "Silence your own proactive conversation-starting. Call when the user asks you to be quiet, stop interrupting, or leave them alone. minutes=0 turns proactive chatter back on.",
                parameters: [
                    "type": "object",
                    "properties": ["minutes": ["type": "number", "description": "How long to stay quiet, in minutes. 0 to re-enable."]],
                    "required": ["minutes"]
                ]
            )
        ]
    }

    // ------------------------------------------------------------- fetching

    private static func fetch(_ url: URL, postBody: String? = nil, timeout: TimeInterval = 20) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if let postBody {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = postBody.data(using: .utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw BuddyError("HTTP \(http.statusCode)")
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // ------------------------------------------------------------- web search
    // Three attempts: DDG html GET → DDG html POST → DDG lite, then diagnostics
    // (so the model can tell the user what went wrong instead of guessing).

    static func webSearch(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "Empty search query." }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        var failures: [String] = []

        // 1 + 2: full html endpoint (GET, then POST — one sometimes works when the other is blocked)
        for postBody in [nil, "q=\(enc)"] as [String?] {
            do {
                let url = postBody == nil
                    ? URL(string: "https://html.duckduckgo.com/html/?q=\(enc)")!
                    : URL(string: "https://html.duckduckgo.com/html/")!
                let html = try await fetch(url, postBody: postBody)
                let titles = captureAll(html, pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#)
                let snippets = captureAll(html, pattern: #"class="result__snippet"[^>]*>(.*?)</(?:a|div|td)>"#)
                if !titles.isEmpty {
                    return format(query: q, results: titles.prefix(6).enumerated().map { i, t in
                        (resolveDDGLink(t[0]), stripTags(t[1]), i < snippets.count ? stripTags(snippets[i][0]) : "")
                    })
                }
                failures.append("html/\(postBody == nil ? "GET" : "POST"): page returned but no results parsed")
            } catch {
                failures.append("html/\(postBody == nil ? "GET" : "POST"): \(error.localizedDescription)")
            }
        }

        // 3: lite endpoint (different HTML shape)
        do {
            let html = try await fetch(URL(string: "https://lite.duckduckgo.com/lite/?q=\(enc)")!)
            let links = captureAll(html, pattern: #"<a rel="nofollow" href="([^"]+)"[^>]*>(.*?)</a>"#)
            let snippets = captureAll(html, pattern: #"class=['"]result-snippet['"][^>]*>(.*?)</td>"#)
            if !links.isEmpty {
                return format(query: q, results: links.prefix(6).enumerated().map { i, t in
                    (resolveDDGLink(t[0]), stripTags(t[1]), i < snippets.count ? stripTags(snippets[i][0]) : "")
                })
            }
            failures.append("lite: page returned but no results parsed")
        } catch {
            failures.append("lite: \(error.localizedDescription)")
        }

        return "Search is temporarily unavailable (tried 3 endpoints — " + failures.joined(separator: "; ")
            + "). Tell the user plainly that the search failed just now; do NOT invent results."
    }

    private static func format(query: String, results: [(String, String, String)]) -> String {
        let lines = results.map { "- \($0.1)\n  \($0.0)\n  \($0.2)" }
        return "Search results for '\(query)':\n" + lines.joined(separator: "\n")
    }

    /// DDG wraps links as //duckduckgo.com/l/?uddg=<encoded>&rut=… — unwrap them.
    private static func resolveDDGLink(_ href: String) -> String {
        if let range = href.range(of: "uddg=") {
            var enc = String(href[range.upperBound...])
            if let amp = enc.range(of: "&") { enc = String(enc[..<amp.lowerBound]) }
            if let dec = enc.removingPercentEncoding { return dec }
        }
        if href.hasPrefix("//") { return "https:" + href }
        return href
    }

    // ------------------------------------------------------------- webpage reader

    static func readWebpage(urlString: String) async -> String {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http://") || s.hasPrefix("https://"), let url = URL(string: s) else {
            return "Invalid URL — must start with http:// or https://."
        }
        var html: String
        do { html = try await fetch(url) }
        catch { return "Could not fetch page: \(error.localizedDescription)" }

        if html.count > 400_000 { html = String(html.prefix(400_000)) }
        var text = html
        for pattern in [#"(?s)<script[^>]*>.*?</script>"#,
                        #"(?s)<style[^>]*>.*?</style>"#,
                        #"(?s)<(?:noscript|header|footer|nav|aside)[^>]*>.*?</(?:noscript|header|footer|nav|aside)>"#,
                        #"(?s)<!--.*?-->"#] {
            text = replaceAll(text, pattern: pattern, with: " ")
        }
        text = replaceAll(text, pattern: #"<[^>]+>"#, with: " ")
        text = decodeEntities(text)
        text = replaceAll(text, pattern: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Page had no readable text." }
        if text.count > 6000 { text = String(text.prefix(6000)) + " …[truncated]" }
        return "Content of \(s):\n\(text)"
    }

    // ------------------------------------------------------------- string helpers

    static func stripTags(_ s: String) -> String {
        decodeEntities(replaceAll(s, pattern: #"<[^>]+>"#, with: ""))
            .trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#x27;": "'", "&#39;": "'", "&nbsp;": " ", "&#x2F;": "/"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    private static func replaceAll(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// All matches' capture groups (group 1..n) as arrays of strings.
    private static func captureAll(_ s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).compactMap { i in
                Range(m.range(at: i), in: s).map { String(s[$0]) }
            }
        }
    }
}
