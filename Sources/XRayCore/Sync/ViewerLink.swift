import Foundation

/// The link that connects the iPad app to X-Ray on a computer:
/// `s2a-xray://connect?server=<address>&token=<iPad token>&name=<computer>`. X-Ray on the computer
/// shows it as a QR code; the iPad's camera opens it in the app.
public struct ViewerLink: Equatable, Sendable {
    public static let scheme = "s2a-xray"

    /// Where the iPad reaches X-Ray, for example https://my-mac.tailnet.ts.net.
    public var server: URL
    public var token: String
    public var name: String?

    public init?(server: URL, token: String, name: String? = nil) {
        guard let normalized = Self.normalize(server), Self.isValidToken(token) else { return nil }
        self.server = normalized
        self.token = token
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
    }

    /// A link opened from a QR code or pasted as text.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let serverText = value("server"), let server = URL(string: serverText), let token = value("token") else { return nil }
        self.init(server: server, token: token, name: value("name"))
    }

    public init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "connect"
        var items = [URLQueryItem(name: "server", value: server.absoluteString), URLQueryItem(name: "token", value: token)]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        components.queryItems = items
        // "+" would read as a space in some decoders; "&" and "=" are encoded by queryItems already.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// An address typed by hand: "my-mac.tailnet.ts.net" becomes https://my-mac.tailnet.ts.net.
    /// Only http and https, no user name or password, path and query dropped.
    public static func normalize(_ server: URL) -> URL? {
        var text = server.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func normalize(text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: candidate).flatMap(normalize)
    }

    /// X-Ray's tokens: letters, digits, "_" and "-", 16 to 200 of them.
    public static func isValidToken(_ token: String) -> Bool {
        (16...200).contains(token.count) && token.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }

    /// The computer's address from `tailscale status --json`: https://<machine>.<tailnet>.ts.net,
    /// which `tailscale funnel` and `tailscale serve` publish.
    public static func tailscaleAddress(statusJSON data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = object["Self"] as? [String: Any],
              var name = me["DNSName"] as? String else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return normalize(text: "https://" + name)
    }
}
