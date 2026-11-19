import Foundation
import Network
import Security
import XRayCore

/// Receives transcript lines that cloud sessions push after every step (see cloud/xray-push.py)
/// and appends them to files under Application Support/S2AClaudeXRay/cloud, which X-Ray scans
/// like ~/.claude/projects. It listens on 127.0.0.1 only; a tunnel such as Tailscale Funnel makes
/// it reachable from the cloud, and every upload must carry the access token.
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
    }

    static let defaultPort: UInt16 = 47318

    private let queue = DispatchQueue(label: "s2a.xray.receiver")
    private var listener: NWListener?
    private var token = ""
    private var status = Status()
    private let onStatus: @Sendable (Status) -> Void

    init(onStatus: @escaping @Sendable (Status) -> Void) {
        self.onStatus = onStatus
    }

    func start(port: UInt16, token: String) {
        queue.async { [self] in
            stopOnQueue()
            self.token = token
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
                listener.stateUpdateHandler = { [weak self] state in self?.update(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                status.listening = false
                status.error = error.localizedDescription
                publish()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue()
            status.listening = false
            publish()
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
    }

    private func update(_ state: NWListener.State) {
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
            guard TranscriptUpload.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(token)"), !token.isEmpty else {
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
        default:
            respond(connection, 404, ["error": "not found"])
        }
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
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error"]
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) \(reasons[code] ?? "OK")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Token

    /// The access token uploads must send as `Authorization: Bearer <token>`; created on first use.
    static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: XRayPaths.receiverToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        return createToken()
    }

    @discardableResult
    static func createToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let token = "xray_" + bytes.map { String(format: "%02x", $0) }.joined()
        let url = XRayPaths.receiverToken
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(token.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
