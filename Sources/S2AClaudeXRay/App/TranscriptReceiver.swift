import Foundation
import Network
import Security
import XRayCore

/// Receives transcript lines that cloud sessions push after every step (see cloud/xray-push.py)
/// and appends them to files under Application Support/S2AClaudeXRay/cloud, which X-Ray scans
/// like ~/.claude/projects. It also serves the logs, read-only, to X-Ray on the iPad (GET /v1/...),
/// with its own token, so a cloud session that holds the upload token cannot read anything back.
/// It listens on 127.0.0.1 only; a tunnel such as Tailscale Funnel makes it reachable from the
/// cloud and the iPad, and every request but /health must carry the matching token.
final class TranscriptReceiver: @unchecked Sendable {
    struct Status: Equatable {
        var listening = false
        var port: UInt16 = 0
        var error: String?
        var uploads = 0
        var lines = 0
        var lastUpload: Date?
        var lastPath: String?
        var rejectedAuth = 0
        /// Requests of the iPad app.
        var viewerRequests = 0
        var lastViewerRequest: Date?
        var viewerRejected = 0
    }

    /// What the receiver accepts. The listener runs while either part is on.
    struct Configuration: Equatable {
        var port: UInt16
        var acceptsUploads: Bool
        var uploadToken: String
        var servesViewer: Bool
        var viewerToken: String
        /// The folders the iPad may read: X-Ray's scan folders.
        var roots: [TranscriptCatalog.Root]
        /// This computer's name, shown on the iPad.
        var name: String

        var needsListener: Bool { acceptsUploads || servesViewer }
    }

    static let defaultPort: UInt16 = 47318
    /// The largest piece of a file one request returns.
    static let maxChunk = 16 * 1024 * 1024

    private let queue = DispatchQueue(label: "s2a.xray.receiver")
    private var listener: NWListener?
    private var configuration = Configuration(port: 0, acceptsUploads: false, uploadToken: "", servesViewer: false, viewerToken: "", roots: [], name: "")
    private var status = Status()
    /// The last listing, so file requests do not walk the folders again.
    private var catalog: TranscriptCatalog?
    private let onStatus: @Sendable (Status) -> Void

    init(onStatus: @escaping @Sendable (Status) -> Void) {
        self.onStatus = onStatus
    }

    /// Applies a configuration; the listener restarts only when the port changes or it was off.
    func update(_ new: Configuration) {
        queue.async { [self] in
            let previous = configuration
            configuration = new
            if previous.roots != new.roots { catalog = nil }
            if !new.needsListener {
                stopOnQueue()
                status.listening = false
                publish()
            } else if listener == nil || previous.port != new.port || status.error != nil {
                startOnQueue(port: new.port)
            }
        }
    }

    private func startOnQueue(port: UInt16) {
        stopOnQueue()
        status.port = port
        status.error = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status.error = L("Недопустимый порт \(port)")
            publish()
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status.listening = false
            status.error = error.localizedDescription
            publish()
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status.listening = true
            status.error = nil
        case .failed(let error):
            status.listening = false
            status.error = error.localizedDescription
        case .cancelled:
            status.listening = false
        default:
            return
        }
        publish()
    }

    private func publish() {
        let snapshot = status
        onStatus(snapshot)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .tooLarge:
                self.respond(connection, 413, ["error": "too large"])
            case .invalid:
                self.respond(connection, 400, ["error": "bad request"])
            case .complete(let request):
                self.handle(request, on: connection)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/health"):
            respond(connection, 200, ["app": "S2A Claude X-Ray", "receiver": "ok"])
        case ("POST", "/v1/transcript"):
            receiveUpload(request, on: connection)
        case ("GET", "/v1/info"), ("GET", "/v1/files"), ("GET", "/v1/file"), ("GET", "/v1/plan-usage"):
            guard configuration.servesViewer else {
                respond(connection, 403, ["error": "iPad access is off"])
                return
            }
            guard !configuration.viewerToken.isEmpty,
                  TranscriptUpload.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(configuration.viewerToken)") else {
                status.viewerRejected += 1
                publish()
                respond(connection, 401, ["error": "unauthorized"])
                return
            }
            status.viewerRequests += 1
            status.lastViewerRequest = Date()
            publish()
            serveViewer(request, on: connection)
        default:
            respond(connection, 404, ["error": "not found"])
        }
    }

    private func receiveUpload(_ request: HTTPRequest, on connection: NWConnection) {
        guard configuration.acceptsUploads else {
            respond(connection, 403, ["error": "cloud uploads are off"])
            return
        }
        guard !configuration.uploadToken.isEmpty,
              TranscriptUpload.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(configuration.uploadToken)") else {
            status.rejectedAuth += 1
            publish()
            respond(connection, 401, ["error": "unauthorized"])
            return
        }
        guard let relative = TranscriptUpload.relativePath(
            path: request.headers["x-path"],
            session: request.headers["x-session-id"],
            project: request.headers["x-project"]
        ) else {
            respond(connection, 400, ["error": "bad path"])
            return
        }
        let lines = TranscriptUpload.validLines(request.body)
        do {
            if lines.accepted > 0 {
                try append(lines.data, to: XRayPaths.cloud.appendingPathComponent(relative))
                catalog = nil
            }
            status.uploads += 1
            status.lines += lines.accepted
            status.lastUpload = Date()
            status.lastPath = relative
            publish()
            respond(connection, 200, ["accepted": lines.accepted, "rejected": lines.rejected])
        } catch {
            respond(connection, 500, ["error": error.localizedDescription])
        }
    }

    // MARK: iPad (read-only)

    private func serveViewer(_ request: HTTPRequest, on connection: NWConnection) {
        switch request.path {
        case "/v1/info":
            let catalog = freshCatalog()
            let info = ViewerInfo(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                platform: "macOS",
                name: configuration.name,
                files: catalog.files.count,
                bytes: catalog.files.reduce(0) { $0 + $1.size },
                newest: catalog.files.first?.modified,
                planUsage: FileManager.default.fileExists(atPath: XRayPaths.planUsage.path)
            )
            respondJSON(connection, info)
        case "/v1/files":
            let catalog = freshCatalog()
            let since = request.query["since"].flatMap(Double.init)
            respondJSON(connection, CatalogListing(files: catalog.files(since: since), now: Date().timeIntervalSince1970))
        case "/v1/file":
            serveFile(request, on: connection)
        default: // /v1/plan-usage
            if let data = try? Data(contentsOf: XRayPaths.planUsage), PlanUsage.decode(data) != nil {
                send(connection, 200, contentType: "application/json", body: data)
            } else {
                send(connection, 204, contentType: "application/json", body: Data())
            }
        }
    }

    private func freshCatalog() -> TranscriptCatalog {
        let catalog = TranscriptCatalog(roots: configuration.roots)
        self.catalog = catalog
        return catalog
    }

    /// `?id=<id>&from=<offset>&max=<bytes>&z=1`: the bytes of a listed transcript from an offset,
    /// raw-deflate compressed with z=1. `X-File-Size` says how long the file is now.
    private func serveFile(_ request: HTTPRequest, on connection: NWConnection) {
        guard let id = request.query["id"] else {
            respond(connection, 400, ["error": "id missing"])
            return
        }
        var url = catalog?.url(for: id)
        if url == nil { url = freshCatalog().url(for: id) }
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else {
            respond(connection, 404, ["error": "not found"])
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = min(UInt64(max(0, Int64(request.query["from"] ?? "") ?? 0)), size)
        let limit = min(max(Int(request.query["max"] ?? "") ?? 4 * 1024 * 1024, 1024), Self.maxChunk)
        var chunk = Data()
        if from < size {
            try? handle.seek(toOffset: from)
            chunk = (try? handle.read(upToCount: limit)) ?? Data()
        }
        var headers = ["X-File-Size": String(size), "X-From": String(from), "X-Length": String(chunk.count)]
        if request.query["z"] == "1", chunk.count > 512, let packed = try? (chunk as NSData).compressed(using: .zlib) as Data {
            headers["X-Encoding"] = "deflate-raw"
            chunk = packed
        }
        send(connection, 200, contentType: "application/octet-stream", headers: headers, body: chunk)
    }

    private func append(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func respond(_ connection: NWConnection, _ code: Int, _ body: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        send(connection, code, contentType: "application/json", body: payload)
    }

    private func respondJSON<T: Encodable>(_ connection: NWConnection, _ value: T) {
        guard let payload = try? JSONEncoder().encode(value) else {
            respond(connection, 500, ["error": "encoding failed"])
            return
        }
        send(connection, 200, contentType: "application/json", body: payload)
    }

    private func send(_ connection: NWConnection, _ code: Int, contentType: String, headers: [String: String] = [:], body: Data) {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(code) \(reasons[code] ?? "OK")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Token

    /// The access token uploads must send as `Authorization: Bearer <token>`; created on first use.
    static func loadOrCreateToken() -> String {
        loadOrCreate(at: XRayPaths.receiverToken, prefix: "xray_")
    }

    @discardableResult
    static func createToken() -> String {
        create(at: XRayPaths.receiverToken, prefix: "xray_")
    }

    /// The token of the iPad app, which may only read; created on first use.
    static func loadOrCreateViewerToken() -> String {
        loadOrCreate(at: XRayPaths.viewerToken, prefix: "xrayv_")
    }

    @discardableResult
    static func createViewerToken() -> String {
        create(at: XRayPaths.viewerToken, prefix: "xrayv_")
    }

    private static func loadOrCreate(at url: URL, prefix: String) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        return create(at: url, prefix: prefix)
    }

    private static func create(at url: URL, prefix: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let token = prefix + bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(token.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
