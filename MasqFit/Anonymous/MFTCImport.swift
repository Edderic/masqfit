import Foundation
import CoreFoundation
import CryptoKit

enum FitTestingMode: String, Codable, CaseIterable {
    case n95, n99, unknown
    var label: String { self == .unknown ? "Unknown" : rawValue.uppercased() }
}

struct AnonymousFitTest: Codable, Equatable {
    var exercises: [String: Double]
    var final: Double?
    var status: String { final == nil ? "incomplete" : "completed" }
    var mask: String
    var protocolName: String
    var maskID: Int?
    var proposeMask: Bool = false
    // nil preserves the wire format of queued submissions created before this field existed.
    var testingMode: FitTestingMode?

    enum CodingKeys: String, CodingKey {
        case exercises, final, mask, status
        case testingMode = "testing_mode"
        case protocolName = "protocol_name", maskID = "mask_id", proposeMask = "propose_mask"
    }
    init(exercises: [String: Double], final: Double?, mask: String, protocolName: String, maskID: Int? = nil, testingMode: FitTestingMode = .unknown) {
        self.exercises = exercises; self.final = final; self.mask = mask
        self.protocolName = protocolName; self.maskID = maskID; self.testingMode = testingMode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exercises = try c.decode([String: Double].self, forKey: .exercises)
        final = try c.decodeIfPresent(Double.self, forKey: .final)
        mask = try c.decode(String.self, forKey: .mask)
        protocolName = try c.decode(String.self, forKey: .protocolName)
        maskID = try c.decodeIfPresent(Int.self, forKey: .maskID)
        testingMode = try c.decodeIfPresent(FitTestingMode.self, forKey: .testingMode)
        proposeMask = try c.decodeIfPresent(Bool.self, forKey: .proposeMask) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(testingMode, forKey: .testingMode)
        if proposeMask { try c.encode(true, forKey: .proposeMask) }
        try c.encode(exercises, forKey: .exercises); try c.encodeIfPresent(final, forKey: .final)
        try c.encode(status, forKey: .status); try c.encode(mask, forKey: .mask)
        try c.encode(protocolName, forKey: .protocolName); try c.encodeIfPresent(maskID, forKey: .maskID)
    }
}

/// Source identifiers are used only in memory to select participants and deduplicate QR scans.
struct MFTCRecord {
    let sourceKey: String
    let participant: String
    var test: AnonymousFitTest
}

enum MFTCImport {
    enum ImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "This is not a supported MFTC results QR code, or its data is invalid or too large. Export a smaller selection of results and try again." }
    }
    static func decode(_ text: String) throws -> [MFTCRecord] {
        guard text.utf8.count <= 16000, let url = URLComponents(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["algorhythmical.github.io", "emcee5601.github.io"].contains(url.host?.lowercased() ?? "") else {
            throw ImportError.invalid
        }
        // MFTC uses HashRouter; also accept the BrowserRouter representation.
        let route = url.fragment ?? (url.path + (url.percentEncodedQuery.map { "?" + $0 } ?? ""))
        guard route.components(separatedBy: "?").first?.hasSuffix("/view-results") == true,
              let query = route.firstIndex(of: "?"),
              let parts = URLComponents(string: "https://local.invalid/?" + route[route.index(after: query)...]),
              let compressed = parts.queryItems?.first(where: { $0.name == "data" })?.value else { throw ImportError.invalid }
        let json = try decompress(compressed)
        guard let data = json.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty, rows.count <= 100 else { throw ImportError.invalid }
        return try rows.map { row in
            var exercises: [String: Double] = [:]
            var aborted = false
            for index in 1...12 {
                let key = "Ex \(index)"
                if let raw = row[key], !(raw is NSNull) {
                    if let value = number(raw) { exercises[String(index)] = value }
                    else if !isIncompleteMarker(raw) { throw ImportError.invalid }
                    else if (raw as? String)?.lowercased() == "aborted" { aborted = true }
                }
            }
            var final: Double?
            if let raw = row["Final"], !(raw is NSNull), !(raw is String && (raw as? String) == "") {
                // MFTC represents aborted/incomplete finals as text in some releases.
                if let value = number(raw) { final = value }
                else if !isIncompleteMarker(raw) { throw ImportError.invalid }
                else if (raw as? String)?.lowercased() == "aborted" { aborted = true }
            }
            guard (!exercises.isEmpty || final != nil || aborted), !(aborted && final != nil) else { throw ImportError.invalid }
            let identity = ["ID", "Time", "Participant", "Mask", "ProtocolName", "Final"] + (1...12).map { "Ex \($0)" }
            let source = row.filter { identity.contains($0.key) }
            let key = SHA256.hash(data: try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
            return MFTCRecord(sourceKey: key, participant: String((row["Participant"] as? String ?? "Unnamed participant").prefix(200)),
                              test: AnonymousFitTest(exercises: exercises, final: final,
                                  mask: String((row["Mask"] as? String ?? "").prefix(200)),
                                  protocolName: String((row["ProtocolName"] as? String ?? "").prefix(200))))
        }
    }
    private static func isIncompleteMarker(_ raw: Any) -> Bool {
        guard let text = raw as? String else { return false }
        return ["", "aborted", "incomplete"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    private static func number(_ raw: Any) -> Double? {
        let value: Double
        if let text = raw as? String {
            guard let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            value = parsed
        } else {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            value = n.doubleValue
        }
        return value.isFinite && value > 0 ? value : nil
    }

    /// Bounded implementation of the LZ-string URI bitstream (UTF-16 code units).
    static func decompress(_ compressed: String) throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$")
        let input = try compressed.map { char -> Int in
            guard let value = alphabet.firstIndex(of: char == " " ? "+" : char), value < 64 else { throw ImportError.invalid }
            return value
        }
        guard !input.isEmpty, input.count <= 16000 else { throw ImportError.invalid }
        var offset = 0
        func bits(_ count: Int) throws -> Int {
            var result = 0
            for bit in 0..<count {
                guard offset < input.count * 6 else { throw ImportError.invalid }
                result |= ((input[offset / 6] >> (5 - offset % 6)) & 1) << bit
                offset += 1
            }
            return result
        }
        var dictionary: [[UInt16]] = [[], [], []]
        let first = try bits(2)
        guard first == 0 || first == 1 else { throw ImportError.invalid }
        var previous = [UInt16(try bits(first == 0 ? 8 : 16))]
        dictionary.append(previous)
        var result = previous
        var width = 3, enlarge = 4
        while result.count <= 262144 && dictionary.count < 65536 {
            var code = try bits(width)
            if code == 2 { return String(decoding: result, as: UTF16.self) }
            if code == 0 || code == 1 {
                dictionary.append([UInt16(try bits(code == 0 ? 8 : 16))])
                code = dictionary.count - 1
                enlarge -= 1
            }
            if enlarge == 0 { enlarge = 1 << width; width += 1 }
            let entry: [UInt16]
            if code < dictionary.count { entry = dictionary[code] }
            else if code == dictionary.count { entry = previous + [previous[0]] }
            else { throw ImportError.invalid }
            guard !entry.isEmpty, result.count + entry.count <= 262144 else { throw ImportError.invalid }
            result += entry
            dictionary.append(previous + [entry[0]])
            enlarge -= 1
            previous = entry
            if enlarge == 0 { enlarge = 1 << width; width += 1 }
        }
        throw ImportError.invalid
    }
}
