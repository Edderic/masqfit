import Foundation

@main struct AnonymousCoreTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }
    static func fixture(_ name: String) throws -> String {
        try String(contentsOfFile: "Tests/Fixtures/\(name).txt", encoding: .utf8)
    }
    static func rejects(_ value: String) {
        do { _ = try MFTCImport.decode(value); check(false, "Accepted invalid QR") }
        catch { checks += 1 }
    }
    static func main() throws {
        for host in ["algorhythmical", "emcee5601"] {
            let complete = try MFTCImport.decode(fixture("\(host)-completed"))
            check(complete.allSatisfy { $0.test.testingMode == .unknown }, "QR imports must not infer testing mode")
            check(complete.count == 3, "Completed example should contain three tests")
            check(complete.map { $0.test.final! } == [211, 242, 176], "Numeric strings must preserve final scores")
            check(complete[0].test.exercises["1"] == 400, "Preserve exercise score")
            let incomplete = try MFTCImport.decode(fixture("\(host)-aborted"))
            check(incomplete.count == 4, "Aborted example should contain four tests")
            check(incomplete.filter { $0.test.status == "incomplete" }.count == 3, "Retain aborted records")
            check(incomplete[0].test.exercises == ["1": 21], "Exclude aborted exercise marker from numeric results")
            check(incomplete[3].test.final == 92, "Keep completed test alongside aborted tests")
            let encoded = try JSONEncoder().encode(incomplete.map { $0.test })
            let text = String(decoding: encoded, as: UTF8.self)
            for forbidden in ["Participant", "PRIVATE_SENTINEL", "PRIVATE_DEVICE", "Notes", "Time", "ParticleCounts", "sourceKey"] {
                check(!text.contains(forbidden), "Leaked source field: \(forbidden)")
            }
            check(try MFTCImport.decode(fixture("\(host)-completed")).map { $0.sourceKey } == complete.map { $0.sourceKey }, "Repeat scan keys must be stable")
            check(Set(complete.map { $0.sourceKey }).count == 3, "Different test attempts must stay distinct")
            let roundTrip = try JSONDecoder().decode([AnonymousFitTest].self, from: encoded)
            check(roundTrip == incomplete.map { $0.test }, "Offline JSON round trip must preserve tests")
        }
        for mode in FitTestingMode.allCases {
            var test = AnonymousFitTest(exercises: [:], final: nil, mask: "Example N95 mask", protocolName: "w1")
            test.testingMode = mode
            let encoded = try JSONEncoder().encode(test)
            let decoded = try JSONDecoder().decode(AnonymousFitTest.self, from: encoded)
            check(decoded.testingMode == mode, "Preserve each user-selected testing mode")
        }
        let legacy = Data(#"{"exercises":{},"status":"incomplete","mask":"Example","protocol_name":"w1"}"#.utf8)
        let oldTest = try JSONDecoder().decode(AnonymousFitTest.self, from: legacy)
        check(oldTest.testingMode == nil, "Old queued tests retain an absent mode")
        let oldRoundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldTest)) as! [String: Any]
        check(oldRoundTrip["testing_mode"] == nil, "Do not change the consented wire payload of old queue items")
        let earlyAbort = try MFTCImport.decode(fixture("early-abort"))
        check(earlyAbort[0].test.exercises.isEmpty && earlyAbort[0].test.status == "incomplete", "Retain tests aborted before the first score")
        let unicode = try MFTCImport.decode(fixture("unicode"))
        check(unicode[0].test.mask == "マスク 😷", "LZ UTF-16 decoding must preserve Unicode")
        for name in ["boolean", "malformed_final", "expansion"] { rejects(try fixture(name)) }
        rejects("https://example.org/#/view-results?data=abc")
        rejects("masqfit-anonymous-v1:" + String(repeating: "a", count: 64))
        rejects("https://algorhythmical.github.io/#/view-results?data=invalid")
        rejects(String(repeating: "a", count: 16001))
        let pairs = "160-371 371-367 367-387 387-14 609-802 802-798 798-14 14-818 967-464 464-456 456-451 451-455 999-1027 1027-884 884-883 883-879 879-600 600-756 756-862 862-753 753-594 594-582 582-609 451-151 151-321 321-434 434-318 318-145 145-133 133-160 509-893 893-894 894-881 881-880 880-879 60-478 478-479 479-453 453-452 452-451 1049-983 983-982 982-1050 1050-1051 1051-1052 1052-1053 1053-509 1049-984 984-985 985-986 986-987 987-988 988-989 989-60".split(separator: " ").map(String.init)
        let meters = Dictionary(uniqueKeysWithValues: pairs.map { ($0, Float(0.001)) })
        let measurements = FacialAggregates(meters: meters)!
        check(measurements.values == ["nose_mm": 8, "strap_mm": 8, "top_cheek_mm": 14, "mid_cheek_mm": 10, "chin_mm": 14], "Path sums and meter conversion changed")
        for key in pairs {
            var missing = meters; missing.removeValue(forKey: key)
            check(FacialAggregates(meters: missing) == nil, "Accepted missing constituent \(key)")
        }
        for bad in [Float.nan, Float.infinity, 0, -1] {
            var invalid = meters; invalid["14-818"] = bad
            check(FacialAggregates(meters: invalid) == nil, "Accepted invalid distance")
        }
        check(measurements.csv.contains("nose_mm,8.0,mm"), "CSV should include units and rounded values")
        try testQueue(measurements)
        try testMeasurementLookup(measurements)
        print("Passed \(checks) anonymous core checks")
    }
}
