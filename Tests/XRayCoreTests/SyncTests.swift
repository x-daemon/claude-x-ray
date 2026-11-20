import XCTest
@testable import XRayCore

final class TranscriptCatalogTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("xray-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ relative: String, _ text: String, modified: Date) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testListsTranscriptsWithSafeIdsNewestFirst() throws {
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let cloud = base.appendingPathComponent("support/cloud", isDirectory: true)
        let imported = base.appendingPathComponent("support/imported", isDirectory: true)
        try write("projects/-Users-me-app/s1.jsonl", "{\"a\":1}\n", modified: Date(timeIntervalSince1970: 1_000))
        try write("projects/-Users-me-app/s1/subagents/agent-1.jsonl", "{}\n", modified: Date(timeIntervalSince1970: 3_000))
        try write("projects/-Users-me-app/notes.txt", "not a transcript", modified: Date(timeIntervalSince1970: 4_000))
        try write("projects/.hidden/x.jsonl", "{}\n", modified: Date(timeIntervalSince1970: 4_000))
        try write("support/cloud/-home-user-demo/c1.jsonl", "{}\n{}\n", modified: Date(timeIntervalSince1970: 2_000))
        try write("support/imported/sessions/my session (1).jsonl", "{}\n", modified: Date(timeIntervalSince1970: 500))

        let roots = TranscriptCatalog.roots(directories: [projects, projects, cloud, imported], cloud: cloud, imported: imported)
        XCTAssertEqual(roots.map(\.key).count, 3, "a folder listed twice is scanned once")
        XCTAssertTrue(roots[0].key.hasPrefix("local-"))
        XCTAssertEqual(roots[0].key.count, "local-".count + 8)
        XCTAssertEqual(Array(roots.map(\.key).dropFirst()), ["cloud", "imported"])
        let local = roots[0].key

        let catalog = TranscriptCatalog(roots: roots)
        XCTAssertEqual(catalog.files.map(\.id), [
            "\(local)/-Users-me-app/s1/subagents/agent-1.jsonl",
            "cloud/-home-user-demo/c1.jsonl",
            "\(local)/-Users-me-app/s1.jsonl",
            "imported/sessions/my_session__1_.jsonl",
        ])
        XCTAssertEqual(catalog.files.map(\.size), [3, 6, 8, 3])
        XCTAssertEqual(catalog.files.first?.modified, 3_000)
        XCTAssertEqual(catalog.files(since: 2_000).count, 2)
        XCTAssertEqual(catalog.url(for: "cloud/-home-user-demo/c1.jsonl")?.lastPathComponent, "c1.jsonl")
        XCTAssertNil(catalog.url(for: "cloud/../projects/-Users-me-app/s1.jsonl"))
        XCTAssertNil(catalog.url(for: "/etc/passwd"))
        for file in catalog.files {
            XCTAssertNotNil(TranscriptCatalog.components(of: file.id), file.id)
        }
    }

    func testRootKeysMatchTheWindowsApp() {
        XCTAssertEqual(TranscriptCatalog.shortHash("/Users/me/.claude/projects"), "8fe8b8e1", "same FNV-1a as windows/src/core/catalog.ts")
    }

    func testRootKeysStayTheSame() {
        let a = TranscriptCatalog.roots(directories: [URL(fileURLWithPath: "/Users/me/.claude/projects")], cloud: URL(fileURLWithPath: "/c"), imported: URL(fileURLWithPath: "/i"))
        let b = TranscriptCatalog.roots(directories: [URL(fileURLWithPath: "/x"), URL(fileURLWithPath: "/Users/me/.claude/projects/")], cloud: URL(fileURLWithPath: "/c"), imported: URL(fileURLWithPath: "/i"))
        XCTAssertEqual(a[0].key, b[1].key)
        XCTAssertNotEqual(b[0].key, b[1].key)
    }

    func testComponentsRejectWhatXRayWouldNotHandOut() {
        XCTAssertEqual(TranscriptCatalog.components(of: "cloud/-home-user/a.jsonl"), ["cloud", "-home-user", "a.jsonl"])
        XCTAssertNil(TranscriptCatalog.components(of: "a.jsonl"), "no root")
        XCTAssertNil(TranscriptCatalog.components(of: "cloud/../a.jsonl"))
        XCTAssertNil(TranscriptCatalog.components(of: "cloud/./a.jsonl"))
        XCTAssertNil(TranscriptCatalog.components(of: "/cloud/a.jsonl"))
        XCTAssertNil(TranscriptCatalog.components(of: "cloud//a.jsonl"))
        XCTAssertNil(TranscriptCatalog.components(of: "cloud/a b.jsonl"))
        XCTAssertNil(TranscriptCatalog.components(of: "cloud/a.txt"))
        XCTAssertNil(TranscriptCatalog.components(of: "cloud\\..\\a.jsonl"))
        XCTAssertEqual(TranscriptCatalog.safeComponent(".."), "_")
        XCTAssertEqual(TranscriptCatalog.safeComponent("Проект 1.jsonl"), "_______1.jsonl")
        XCTAssertEqual(TranscriptCatalog.safeComponent(String(repeating: "a", count: 300) + ".jsonl").count, 116)
    }

    func testMirrorPlan() {
        let files = [
            CatalogFile(id: "cloud/p/new.jsonl", size: 100, modified: 900),
            CatalogFile(id: "cloud/p/grown.jsonl", size: 80, modified: 800),
            CatalogFile(id: "cloud/p/same.jsonl", size: 50, modified: 700),
            CatalogFile(id: "cloud/p/replaced.jsonl", size: 10, modified: 600),
            CatalogFile(id: "cloud/p/old.jsonl", size: 10, modified: 100),
            CatalogFile(id: "cloud/p/old-but-copied.jsonl", size: 20, modified: 100),
            CatalogFile(id: "../evil.jsonl", size: 10, modified: 950),
        ]
        let local: [String: Int64] = ["cloud/p/grown.jsonl": 30, "cloud/p/same.jsonl": 50, "cloud/p/replaced.jsonl": 40, "cloud/p/old-but-copied.jsonl": 5]
        let plan = MirrorPlan.fetches(remote: files, local: local, cutoff: 500)
        XCTAssertEqual(plan.map(\.file.id), ["cloud/p/new.jsonl", "cloud/p/grown.jsonl", "cloud/p/replaced.jsonl", "cloud/p/old-but-copied.jsonl"])
        XCTAssertEqual(plan.map(\.from), [0, 30, 0, 5])
        XCTAssertEqual(plan.map(\.restart), [false, false, true, false])
        XCTAssertEqual(MirrorPlan.fetches(remote: files, local: [:], cutoff: nil).count, 6, "no cutoff: everything but the unsafe id")
    }
}

final class ViewerLinkTests: XCTestCase {
    func testRoundTrip() throws {
        let link = try XCTUnwrap(ViewerLink(server: try XCTUnwrap(URL(string: "https://My-Mac.tailnet.ts.net/some/path?x=1")), token: "xrayv_0123456789abcdef", name: "Dimitri's Mac + PC"))
        XCTAssertEqual(link.server.absoluteString, "https://my-mac.tailnet.ts.net")
        let parsed = try XCTUnwrap(ViewerLink(url: link.url))
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(ViewerLink(text: "  \(link.url.absoluteString)\n"), link)
        XCTAssertTrue(link.url.absoluteString.hasPrefix("s2a-xray://connect?server=https://my-mac.tailnet.ts.net&token=xrayv_"), link.url.absoluteString)
    }

    func testRejectsWhatIsNotAnXRayLink() throws {
        XCTAssertNil(ViewerLink(text: "https://example.com/?server=https://a.b&token=xrayv_0123456789abcdef"))
        XCTAssertNil(ViewerLink(text: "s2a-xray://connect?server=ftp://a.b&token=xrayv_0123456789abcdef"))
        XCTAssertNil(ViewerLink(text: "s2a-xray://connect?server=https://user:pw@a.b&token=xrayv_0123456789abcdef"))
        XCTAssertNil(ViewerLink(text: "s2a-xray://connect?server=https://a.b&token=short"))
        XCTAssertNil(ViewerLink(text: "s2a-xray://connect?server=https://a.b&token=has%20space%20in%20it%20too"))
        XCTAssertNil(ViewerLink(text: "s2a-xray://connect?token=xrayv_0123456789abcdef"))
    }

    func testTailscaleAddress() {
        let status = Data(#"{"Version":"1.90.0","Self":{"HostName":"MacBook","DNSName":"Dimitris-MacBook-Pro.tailcd66fc.ts.net.","Online":true}}"#.utf8)
        XCTAssertEqual(ViewerLink.tailscaleAddress(statusJSON: status)?.absoluteString, "https://dimitris-macbook-pro.tailcd66fc.ts.net")
        XCTAssertNil(ViewerLink.tailscaleAddress(statusJSON: Data(#"{"Self":{"DNSName":""}}"#.utf8)))
        XCTAssertNil(ViewerLink.tailscaleAddress(statusJSON: Data("not json".utf8)))
    }

    func testTypedAddresses() {
        XCTAssertEqual(ViewerLink.normalize(text: "my-pc.tailnet.ts.net")?.absoluteString, "https://my-pc.tailnet.ts.net")
        XCTAssertEqual(ViewerLink.normalize(text: " http://127.0.0.1:47318/ ")?.absoluteString, "http://127.0.0.1:47318")
        XCTAssertNil(ViewerLink.normalize(text: ""))
        XCTAssertNil(ViewerLink.normalize(text: "file:///etc"))
    }
}
