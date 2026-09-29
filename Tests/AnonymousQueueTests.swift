import Foundation

private final class MemoryCredentials: AnonymousCredentialStorage {
    var values: [UUID: String] = [:]
    func store(_ credential: String, id: UUID) throws { values[id] = credential }
    func read(_ id: UUID) -> String? { values[id] }
    func remove(_ id: UUID) { values.removeValue(forKey: id) }
}

private final class SubmissionProtocol: URLProtocol {
    static var respond: ((URLRequest, Data, SubmissionProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        Self.respond?(request, data, self)
    }
    override func stopLoading() {}
    func reply(_ status: Int, _ body: [String: String]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension AnonymousCoreTests {
    static func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(condition(), "Queue operation timed out")
    }
    static func testQueue(_ measurements: FacialAggregates) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubmissionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); SubmissionProtocol.respond = nil }
        let credentials = MemoryCredentials()
        let token = try AnonymousIdentity.create()
        check(AnonymousIdentity.parse(AnonymousIdentity.prefix + token) == token, "Recovery code round trip")
        check(AnonymousIdentity.parse("bad-code") == nil, "Reject malformed recovery code")
        var imported = try MFTCImport.decode(fixture("algorhythmical-completed"))
        // Mirror the review screenshot: match the first two tests and leave the third unresolved.
        for index in 0..<2 {
            imported[index].test.maskID = 727
            imported[index].test.mask = "Zimi B95-XL"
        }
        imported[2].test.mask = "Zimi B95-XL-01 White"
        imported[2].test.proposeMask = true
        imported[0].test.testingMode = .n95
        imported[1].test.testingMode = .n99
        let reviewedTests = imported.map { $0.test }
        let payload = AnonymousContribution(measurements: measurements, tests: reviewedTests)
        var sentBodies: [Data] = []
        SubmissionProtocol.respond = { request, data, handler in
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Use participant credential")
            check(request.value(forHTTPHeaderField: "Cookie") == nil, "Do not send account cookies")
            sentBodies.append(data)
            handler.client?.urlProtocol(handler, didFailWithError: URLError(.networkConnectionLost))
        }
        let store = AnonymousSubmissionStore(directory: directory, urlSession: session, credentialStorage: credentials)
        check(store.storageError == nil, "Queue should open")
        try store.enqueue(payload, credential: token)
        waitFor { store.items.first?.state == "queued" && store.items.first?.attempts == 1 }
        let disk = try String(contentsOf: directory.appendingPathComponent("queue.json"), encoding: .utf8)
        check(!disk.contains(token), "Never persist recovery credential in queue JSON")
        check(disk.contains("nose_mm"), "Consented aggregates should survive offline")
        let reloaded = AnonymousSubmissionStore(directory: directory, urlSession: session, credentialStorage: credentials)
        check(reloaded.items.first?.id == payload.contribution_id, "Keep receipt ID across restart")
        check(reloaded.items.first?.payload?.fit_tests == reviewedTests, "Keep catalog IDs and selected names across queue persistence and restart")
        SubmissionProtocol.respond = { _, data, handler in
            sentBodies.append(data)
            handler.reply(200, ["contribution_id": payload.contribution_id.uuidString.lowercased()])
        }
        reloaded.retry(force: true)
        waitFor { reloaded.items.first?.state == "submitted" }
        let first = try JSONSerialization.jsonObject(with: sentBodies[0]) as! NSDictionary
        let second = try JSONSerialization.jsonObject(with: sentBodies[1]) as! NSDictionary
        check(first == second, "Retry must use exactly the consented payload and receipt")
        let contribution = first["contribution"] as! [String: Any]
        let tests = contribution["fit_tests"] as! [[String: Any]]
        check(tests.compactMap { $0["testing_mode"] as? String } == ["n95", "n99", "unknown"], "Preserve all testing modes through offline storage and retry")
        check(tests.count == 3, "Send all three reviewed fit tests")
        for index in 0..<2 {
            check(tests[index]["mask_id"] as? Int == 727, "Send the catalog ID under the backend's mask_id key")
            check(tests[index]["mask"] as? String == "Zimi B95-XL", "Send the selected catalog name")
        }
        check(tests[2]["propose_mask"] as? Bool == true, "Preserve explicit proposal through offline queue and retry")
        check(tests[0]["propose_mask"] == nil, "Confirmed matches do not propose new masks")
        check(tests[2]["mask_id"] == nil, "Do not invent a catalog match for the unresolved test")
        check(tests[2]["mask"] as? String == "Zimi B95-XL-01 White", "Keep the unresolved test's reviewed name")
        check(reloaded.items.first?.payload == nil, "Remove delivered payload from queue")
        check(credentials.read(payload.contribution_id) == nil, "Delete credential after acknowledged delivery")
        try reloaded.remove(payload.contribution_id)
        check(reloaded.items.isEmpty, "Remove local receipt")
        SubmissionProtocol.respond = { _, _, handler in handler.reply(422, ["error": "Invalid"]) }
        let rejected = AnonymousContribution(measurements: measurements, tests: [])
        try reloaded.enqueue(rejected, credential: token)
        waitFor { reloaded.items.first?.state == "failed" }
        check(reloaded.items.first?.payload != nil, "Keep rejected data available until removed")
        try reloaded.remove(rejected.contribution_id)
        check(credentials.values.isEmpty, "Removing a failed item clears its credential")
        try Data("corrupt queue".utf8).write(to: directory.appendingPathComponent("queue.json"))
        let corrupt = AnonymousSubmissionStore(directory: directory, urlSession: session, credentialStorage: credentials)
        check(corrupt.storageError != nil, "Surface unreadable queue")
        do { try corrupt.enqueue(payload, credential: token); check(false, "Must not overwrite unreadable queue") }
        catch { checks += 1 }
        check(try String(contentsOf: directory.appendingPathComponent("queue.json"), encoding: .utf8) == "corrupt queue", "Preserve unreadable file")
    }
}
