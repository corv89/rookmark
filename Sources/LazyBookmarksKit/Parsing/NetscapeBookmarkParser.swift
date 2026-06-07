import Foundation
import CryptoKit

/// Stable, content-derived bookmark identifiers.
public enum BookmarkID {
    /// SHA-256 hex of the *normalized* URL. Deterministic across runs so that
    /// dedup, resume, and re-import behave idempotently.
    public static func make(forNormalizedURL normalized: String) -> String {
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Parses a browser-exported "Netscape Bookmark File Format" HTML document.
///
/// The real-world format is irregular: browsers frequently omit closing
/// `</DL>`/`</p>` tags, vary attribute order/casing, and embed base64 favicons.
/// Rather than a strict DOM parse we scan the document for the handful of
/// tokens that matter (`<H3>`, `<A>`, `<DL>`, `</DL>`) in document order and
/// drive a folder-stack state machine. This is the pragmatic approach every
/// robust importer uses.
public struct NetscapeBookmarkParser: Sendable {

    public init() {}

    public func parse(_ html: String) -> ParseResult {
        var stack: [String] = []          // current folder path, outermost first
        var pendingFolderName: String?    // <H3> seen, awaiting its <DL>
        var bookmarks: [Bookmark] = []
        var seenIDs = Set<String>()
        var existingFolders: [String] = []
        var existingFolderSet = Set<String>()

        for token in Self.tokenize(html) {
            switch token {
            case .folderOpen(let name):
                // The <H3> names the folder; the *following* <DL> scopes it.
                pendingFolderName = Self.decodeEntities(name).trimmingCharacters(in: .whitespacesAndNewlines)

            case .listOpen:
                // Push the pending folder name (nil for the implicit root <DL>).
                let name = pendingFolderName ?? ""
                stack.append(name)
                pendingFolderName = nil
                if !name.isEmpty, existingFolderSet.insert(name).inserted {
                    existingFolders.append(name)
                }

            case .listClose:
                if !stack.isEmpty { stack.removeLast() }

            case .anchor(let attrs, let title):
                guard let rawHref = attrs["href"], !rawHref.isEmpty else { continue }
                let href = Self.decodeEntities(rawHref)
                let normalized = URLNormalizer.normalize(href)
                let id = BookmarkID.make(forNormalizedURL: normalized)
                // Skip exact duplicates at parse time; richer dedup is its own command.
                guard seenIDs.insert(id).inserted else { continue }

                let path = stack.filter { !$0.isEmpty }
                let added = attrs["add_date"].flatMap(Self.parseUnixSeconds)
                bookmarks.append(
                    Bookmark(
                        id: id,
                        title: Self.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
                        url: href,
                        originalFolderPath: path,
                        addedAt: added
                    )
                )
            }
        }

        return ParseResult(bookmarks: bookmarks, existingFolders: existingFolders)
    }

    // MARK: - Tokenization

    enum Token {
        case folderOpen(String)            // <H3 ...>name</H3>
        case listOpen                       // <DL>
        case listClose                      // </DL>
        case anchor([String: String], String) // <A ...>title</A>  (attrs keyed lowercase)
    }

    /// Single pass over the document collecting tokens of interest in order.
    static func tokenize(_ html: String) -> [Token] {
        // One alternation, matched in document order. `[\s\S]` = dotall.
        // Group 1: H3 attributes (unused), Group 2: H3 inner text
        // Group 3: A attributes,            Group 4: A inner text
        // Group 5: <DL  (open),             Group 6: </DL> (close)
        let pattern =
            #"<H3\b([^>]*)>([\s\S]*?)</H3>"# +
            #"|<A\b([^>]*)>([\s\S]*?)</A>"# +
            #"|(<DL\b)"# +
            #"|(</DL>)"#

        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        var tokens: [Token] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let name = group(2) {
                tokens.append(.folderOpen(name))
            } else if let attrsRaw = group(3) {
                tokens.append(.anchor(parseAttributes(attrsRaw), group(4) ?? ""))
            } else if group(5) != nil {
                tokens.append(.listOpen)
            } else if group(6) != nil {
                tokens.append(.listClose)
            }
        }
        return tokens
    }

    /// Extracts `key="value"` pairs from a raw tag attribute string. Keys are
    /// lowercased; values are returned raw (entity-decoded by callers as needed).
    static func parseAttributes(_ raw: String) -> [String: String] {
        guard let re = try? NSRegularExpression(
            pattern: #"([A-Za-z_][\w-]*)\s*=\s*"([^"]*)""#
        ) else { return [:] }
        let ns = raw as NSString
        var out: [String: String] = [:]
        re.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            out[key] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    // MARK: - Helpers

    static func parseUnixSeconds(_ s: String) -> Date? {
        guard let secs = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    /// Minimal HTML entity decode covering what browsers actually emit in
    /// bookmark titles/URLs. Avoids pulling in a full HTML library.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        // Numeric entities like &#x2014; / &#8212;
        if r.contains("&#") { r = decodeNumericEntities(r) }
        return r
    }

    static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return s }
        let ns = s as NSString
        var result = s
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let isHex = !ns.substring(with: m.range(at: 1)).isEmpty
            let body = ns.substring(with: m.range(at: 2))
            if let code = UInt32(body, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                let full = ns.substring(with: m.range(at: 0))
                result = result.replacingOccurrences(of: full, with: String(scalar))
            }
        }
        return result
    }
}
