import Foundation
import Observation
import XRayCore

/// A computer with X-Ray (Mac or Windows) that the iPad reads.
struct Computer: Codable, Identifiable, Hashable {
    var id: UUID
    /// Where the iPad reaches X-Ray, for example https://my-mac.tailnet.ts.net.
    var server: URL
    var name: String
    var platform: String?
    var added: Date
}

/// Keeps the iPad's copies of the computers' transcripts up to date: downloads what is new while
/// the app is open (every few seconds, only the bytes added since the last time), and the account
/// limits. X-Ray on the iPad then reads the copies like the Mac app reads ~/.claude/projects.
@MainActor
@Observable
final class DesktopSync {
    enum State: Equatable, Sendable {
        case waiting
        case connecting
        /// Downloading: files done of the files to get, bytes received.
        case downloading(done: Int, total: Int, bytes: Int64)
        case live
        case offline(String)
        /// The token was not accepted: the computer has a new one, or the link was wrong.
        case unauthorized
        /// iPad access is switched off in X-Ray on the computer.
        case accessOff
        case failed(String)
    }

    struct Status: Equatable, Sendable {
        var state: State = .waiting
        var info: ViewerInfo?
        var lastSync: Date?
        var files = 0
        var bytes: Int64 = 0
    }

    static let retentionKey = "ipad.retentionDays"
    static let computersKey = "ipad.computers"
    static let retentionChoices = [7, 30, 90, 365, 0]

    private(set) var computers: [Computer] = []
    private(set) var status: [UUID: Status] = [:]
    /// Days of logs to download; 0 means all of them.
    private(set) var retentionDays: Int
    /// The last error saving a token to the keychain, shown in settings.
    private(set) var keychainWarning: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var planUsage: [UUID: PlanUsage] = [:]
    @ObservationIgnored private var active = false
    @ObservationIgnored private var rescanPending = false

    init(model: AppModel) {
        self.model = model
        let stored = UserDefaults.standard.object(forKey: Self.retentionKey) as? Int
        retentionDays = stored ?? 30
        if let data = UserDefaults.standard.data(forKey: Self.computersKey),
           let saved = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = saved
        }
        Self.prepareMirror()
        addFromLaunchArguments()
    }

    // MARK: Computers

    /// The computer a link points to: added, or updated when it is already there.
    @discardableResult
    func add(_ link: ViewerLink) -> UUID {
        let id: UUID
        if let index = computers.firstIndex(where: { $0.server == link.server }) {
            id = computers[index].id
            if let name = link.name { computers[index].name = name }
        } else {
            id = UUID()
            computers.append(Computer(id: id, server: link.server, name: link.name ?? link.server.host ?? link.server.absoluteString, platform: nil, added: Date()))
        }
        setToken(link.token, for: id)
        save()
        restart(id)
        return id
    }

    func update(_ id: UUID, server: URL, name: String, token: String?) {
        guard let index = computers.firstIndex(where: { $0.id == id }) else { return }
        let moved = computers[index].server != server
        computers[index].server = server
        computers[index].name = name.isEmpty ? (server.host ?? server.absoluteString) : name
        if let token, !token.isEmpty { setToken(token, for: id) }
        save()
        if moved { removeMirror(of: id) }
        restart(id)
    }

    /// Forgets a computer and the logs that came from it.
    func remove(_ id: UUID) {
        workers[id]?.cancel()
        workers[id] = nil
        computers.removeAll { $0.id == id }
        status[id] = nil
        planUsage[id] = nil
        tokens[id] = nil
        Keychain.delete(account: id.uuidString)
        save()
        removeMirror(of: id)
        Task { await model?.fullRescan() }
    }

    func token(for id: UUID) -> String? {
        if let token = tokens[id] { return token }
        let token = Keychain.read(account: id.uuidString)
        tokens[id] = token
        return token
    }

    private func setToken(_ token: String, for id: UUID) {
        tokens[id] = token
        keychainWarning = Keychain.save(token, account: id.uuidString) ? nil : L("Не удалось сохранить токен в связке ключей: после перезапуска его придётся ввести снова.")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(computers) {
            UserDefaults.standard.set(data, forKey: Self.computersKey)
        }
    }

    /// CI and testing: `-XRayServer <address> -XRayToken <token> [-XRayName <name>]` adds a computer.
    private func addFromLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "XRayServer").flatMap(ViewerLink.normalize(text:)),
              let token = defaults.string(forKey: "XRayToken"),
              let link = ViewerLink(server: server, token: token, name: defaults.string(forKey: "XRayName")) else { return }
        add(link)
    }

    // MARK: Settings

    func setRetention(_ days: Int) {
        retentionDays = days
        UserDefaults.standard.set(days, forKey: Self.retentionKey)
        syncNow()
    }

    /// Deletes every downloaded log; the next sync downloads them again.
    func deleteDownloads() {
        for id in computers.map(\.id) { workers[id]?.cancel(); workers[id] = nil }
        try? FileManager.default.removeItem(at: XRayPaths.mirror)
        Self.prepareMirror()
        Task {
            await model?.fullRescan()
            syncNow()
        }
    }

    /// Bytes the copies take on the iPad.
    func downloadedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: XRayPaths.mirror, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Running

    /// Syncs while the app is in the foreground; iPadOS stops apps in the background anyway.
    func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive {
            for computer in computers { restart(computer.id) }
        } else {
            for task in workers.values { task.cancel() }
            workers.removeAll()
            for id in status.keys where status[id]?.state != .unauthorized && status[id]?.state != .accessOff {
                status[id]?.state = .waiting
            }
        }
    }

    /// Asks every computer for news at once (the refresh button, a new retention).
    func syncNow() {
        guard active else { return }
        for computer in computers { restart(computer.id) }
    }

    private func restart(_ id: UUID) {
        workers[id]?.cancel()
        workers[id] = nil
        guard active, let computer = computers.first(where: { $0.id == id }) else { return }
        guard let token = token(for: id) else {
            status[id, default: Status()].state = .unauthorized
            return
        }
        status[id, default: Status()].state = .connecting
        let worker = MirrorWorker(
            computer: computer,
            token: token,
            folder: XRayPaths.mirror.appendingPathComponent(computer.id.uuidString, isDirectory: true),
            retentionDays: retentionDays
        )
        workers[id] = Task { [weak self] in
            await worker.run { event in
                await self?.handle(event, from: id)
            }
        }
    }

    private func handle(_ event: MirrorWorker.Event, from id: UUID) {
        guard computers.contains(where: { $0.id == id }) else { return }
        var current = status[id, default: Status()]
        switch event {
        case .info(let info):
            current.info = info
            if let index = computers.firstIndex(where: { $0.id == id }) {
                if computers[index].name != info.name || computers[index].platform != info.platform {
                    computers[index].name = info.name
                    computers[index].platform = info.platform
                    save()
                }
            }
        case .state(let state):
            current.state = state
        case .synced(let files, let bytes):
            current.state = .live
            current.lastSync = Date()
            current.files = files
            current.bytes = bytes
        case .changed:
            scheduleRescan()
        case .planUsage(let usage):
            planUsage[id] = usage
            savePlanUsage()
        }
        status[id] = current
    }

    /// One rescan for a burst of downloads.
    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.rescanPending = false
            await self.model?.rescan()
        }
    }

    /// The newest account limits any computer reported; the screens read them from the usual file.
    private func savePlanUsage() {
        let ordered = planUsage.values.sorted { $0.capturedAt < $1.capturedAt }
        guard var merged = ordered.first else { return }
        for usage in ordered.dropFirst() { merged = usage.merged(with: merged) }
        if merged != PlanUsageFile.load() {
            PlanUsageFile.save(merged)
            model?.reloadPlanUsage()
        }
    }

    // MARK: Summary for the screens

    /// The most recent successful sync of any computer.
    var lastSync: Date? { status.values.compactMap(\.lastSync).max() }

    /// One line for the sidebar.
    var summaryState: State {
        let states = computers.compactMap { status[$0.id]?.state }
        if let downloading = states.first(where: { if case .downloading = $0 { return true } else { return false } }) { return downloading }
        if states.contains(.live) { return .live }
        if states.contains(.connecting) { return .connecting }
        return states.first ?? .waiting
    }

    private static func prepareMirror() {
        var folder = XRayPaths.mirror
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Copies of the computers' logs: they can be downloaded again, so not in the iPad's backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private func removeMirror(of id: UUID) {
        try? FileManager.default.removeItem(at: XRayPaths.mirror.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}

/// Talks to one computer: lists its transcripts, downloads what the iPad's copy lacks, repeats.
actor MirrorWorker {
    enum Event: Sendable {
        case info(ViewerInfo)
        case state(DesktopSync.State)
        case synced(files: Int, bytes: Int64)
        case changed
        case planUsage(PlanUsage)
    }

    enum Failure: Error {
        case unauthorized, accessOff, notXRay(Int), offline(String)
    }

    static let poll: UInt64 = 3_000_000_000
    static let chunk = 8 * 1024 * 1024
    static let parallel = 4

    let computer: Computer
    let token: String
    let folder: URL
    let retentionDays: Int
    private let session: URLSession
    private var local: [String: Int64] = [:]
    private var serverNow: Double?
    private var lastFullListing = Date.distantPast
    private var lastPlanUsage = Date.distantPast

    init(computer: Computer, token: String, folder: URL, retentionDays: Int) {
        self.computer = computer
        self.token = token
        self.folder = folder
        self.retentionDays = retentionDays
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = Self.parallel
        session = URLSession(configuration: configuration)
    }

    func run(report: @escaping @Sendable (Event) async -> Void) async {
        loadLocalSizes()
        var failures = 0
        while !Task.isCancelled {
            do {
                await report(.state(.connecting))
                let info: ViewerInfo = try await json("/v1/info")
                await report(.info(info))
                failures = 0
                while !Task.isCancelled {
                    try await syncOnce(report: report)
                    try await Task.sleep(nanoseconds: Self.poll)
                }
            } catch is CancellationError {
                return
            } catch Failure.unauthorized {
                await report(.state(.unauthorized))
                return
            } catch Failure.accessOff {
                await report(.state(.accessOff))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            } catch Failure.notXRay(let code) {
                await report(.state(.failed(L("Ответ \(code): по этому адресу не X-Ray, или он устарел. Нужна версия 0.9 или новее."))))
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                if Task.isCancelled { return }
                failures += 1
                await report(.state(.offline(Self.describe(error))))
                // 3, 6, 12, 24, then every 30 seconds.
                let delay = min(30, 3 * (1 << min(failures - 1, 4)))
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    // MARK: One round

    private func syncOnce(report: @escaping @Sendable (Event) async -> Void) async throws {
        // A short listing of what changed; the whole list every 5 minutes, in case a file came in
        // with an old date (an import, a copied folder).
        let full = Date().timeIntervalSince(lastFullListing) > 300 || serverNow == nil
        var path = "/v1/files"
        if !full, let serverNow { path += "?since=\(Int(serverNow - 30))" }
        let listing: CatalogListing = try await json(path)
        if full { lastFullListing = Date() }
        let cutoff = retentionDays > 0 ? listing.now - Double(retentionDays) * 86_400 : nil
        let fetches = MirrorPlan.fetches(remote: listing.files, local: local, cutoff: cutoff)
        serverNow = listing.now

        if !fetches.isEmpty {
            let total = fetches.count
            var done = 0
            var received: Int64 = 0
            await report(.state(.downloading(done: 0, total: total, bytes: 0)))
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var pending = fetches.makeIterator()
                for _ in 0..<Self.parallel {
                    if let fetch = pending.next() {
                        group.addTask { try await self.download(fetch) }
                    }
                }
                while let bytes = try await group.next() {
                    done += 1
                    received += bytes
                    if bytes > 0 { await report(.changed) }
                    await report(.state(.downloading(done: done, total: total, bytes: received)))
                    if let fetch = pending.next() {
                        group.addTask { try await self.download(fetch) }
                    }
                }
            }
        }

        if Date().timeIntervalSince(lastPlanUsage) > 20 {
            lastPlanUsage = Date()
            if let usage = try await planUsage() {
                await report(.planUsage(usage))
            }
        }
        await report(.synced(files: local.count, bytes: local.values.reduce(0, +)))
    }

    /// Appends what the copy lacks, chunk by chunk; returns the bytes written.
    private func download(_ fetch: MirrorPlan.Fetch) async throws -> Int64 {
        guard let components = TranscriptCatalog.components(of: fetch.file.id) else { return 0 }
        let url = components.reduce(folder) { $0.appendingPathComponent($1) }
        let fileManager = FileManager.default
        if fetch.restart {
            try? fileManager.removeItem(at: url)
            local[fetch.file.id] = nil
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        // Continue from what is really on disk, whatever the plan assumed.
        var offset = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if offset > fetch.file.size {
            try? fileManager.removeItem(at: url)
            fileManager.createFile(atPath: url.path, contents: nil)
            offset = 0
        }
        var written: Int64 = 0
        var target = fetch.file.size
        while offset < target {
            try Task.checkCancellation()
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "id", value: fetch.file.id),
                URLQueryItem(name: "from", value: String(offset)),
                URLQueryItem(name: "max", value: String(Self.chunk)),
                URLQueryItem(name: "z", value: "1"),
            ]
            let (data, response) = try await get("/v1/file?" + (components.percentEncodedQuery ?? ""))
            guard response.statusCode == 200 else {
                if response.statusCode == 404 { return written } // gone meanwhile
                throw Self.failure(for: response.statusCode)
            }
            let from = Int64(response.value(forHTTPHeaderField: "X-From") ?? "") ?? offset
            guard from == offset else { throw Failure.offline(L("Компьютер прислал не тот кусок файла")) }
            if let size = Int64(response.value(forHTTPHeaderField: "X-File-Size") ?? "") {
                if size < offset {
                    // Replaced while we were reading it: start again next round.
                    try? fileManager.removeItem(at: url)
                    local[fetch.file.id] = nil
                    return written
                }
                target = max(target, size)
            }
            var bytes = data
            if response.value(forHTTPHeaderField: "X-Encoding") == "deflate-raw" {
                guard let unpacked = try? (data as NSData).decompressed(using: .zlib) as Data else {
                    throw Failure.offline(L("Не удалось распаковать данные"))
                }
                bytes = unpacked
            }
            guard !bytes.isEmpty else { break }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()
            offset += Int64(bytes.count)
            written += Int64(bytes.count)
            local[fetch.file.id] = offset
        }
        return written
    }

    private func planUsage() async throws -> PlanUsage? {
        let (data, response) = try await get("/v1/plan-usage")
        guard response.statusCode == 200 else { return nil }
        return PlanUsage.decode(data)
    }

    // MARK: HTTP

    private func json<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await get(path)
        guard response.statusCode == 200 else { throw Self.failure(for: response.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.notXRay(response.statusCode)
        }
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: computer.server.absoluteString + path) else { throw Failure.offline(L("Неверный адрес")) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.offline(L("Нет ответа")) }
            return (data, http)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw Failure.offline(error.localizedDescription)
        }
    }

    private static func describe(_ error: Error) -> String {
        if case Failure.offline(let text)? = error as? Failure { return text }
        return error.localizedDescription
    }

    private static func failure(for code: Int) -> Failure {
        switch code {
        case 401: return .unauthorized
        case 403: return .accessOff
        case 502, 503, 504: return .offline(L("Компьютер не отвечает (\(code)): X-Ray закрыт или компьютер спит"))
        default: return .notXRay(code)
        }
    }

    /// Sizes of the copies already on the iPad, by id.
    private func loadLocalSizes() {
        local = [:]
        let base = folder.resolvingSymlinksInPath().pathComponents
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let parts = url.resolvingSymlinksInPath().pathComponents
            guard parts.starts(with: base) else { continue }
            let id = parts.dropFirst(base.count).joined(separator: "/")
            local[id] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
