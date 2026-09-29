import Foundation

/// Version 1 retains the existing path sums and last-ten-frame averaging.
struct FacialAggregates: Codable, Equatable {
    static let version = 1
    static let labels = [("nose_mm", "Nose"), ("strap_mm", "Strap"),
                         ("top_cheek_mm", "Top cheek"), ("mid_cheek_mm", "Mid-cheek"), ("chin_mm", "Chin")]
    let values: [String: Double]

    init?(meters: [String: Float]) {
        guard let values = Self.aggregate(millimeters: meters.mapValues { Double($0 * 1000) }) else { return nil }
        self.values = values
    }

    init?(values: [String: Double]) {
        guard Set(values.keys) == Set(Self.labels.map { $0.0 }),
              values.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        self.values = values
    }

    var text: String {
        Self.labels.map { "\($0.1): \(String(format: "%.1f", values[$0.0] ?? 0)) mm" }.joined(separator: "\n")
    }
    var csv: String {
        "measurement,value,unit\n" + Self.labels.map {
            "\($0.0),\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), values[$0.0] ?? 0)),mm"
        }.joined(separator: "\n")
    }

    static func aggregate(millimeters: [String: Double]) -> [String: Double]? {
        let noseKeys = [
            "160-371", "371-367", "367-387", "387-14",
            "609-802", "802-798", "798-14", "14-818"
        ]
        let strapKeys = [
            "967-464", "464-456", "456-451", "451-455",
            "999-1027", "1027-884", "884-883", "883-879"
        ]
        let topCheekKeys = [
            "879-600", "600-756", "756-862", "862-753", "753-594", "594-582", "582-609",
            "451-151", "151-321", "321-434", "434-318", "318-145", "145-133", "133-160"
        ]
        let midCheekKeys = [
            "509-893", "893-894", "894-881", "881-880", "880-879",
            "60-478", "478-479", "479-453", "453-452", "452-451"
        ]
        let chinKeys = [
            "1049-983", "983-982", "982-1050", "1050-1051", "1051-1052", "1052-1053", "1053-509",
            "1049-984", "984-985", "985-986", "986-987", "987-988", "988-989", "989-60"
        ]

        func sum(keys: [String]) -> Double? {
            var total = 0.0
            for key in keys {
                guard let value = millimeters[key], value.isFinite, value > 0 else { return nil }
                total += value
            }
            return total.isFinite ? total : nil
        }

        guard let nose = sum(keys: noseKeys),
              let strap = sum(keys: strapKeys),
              let topCheek = sum(keys: topCheekKeys),
              let midCheek = sum(keys: midCheekKeys),
              let chin = sum(keys: chinKeys) else {
            return nil
        }

        return [
            "nose_mm": nose,
            "strap_mm": strap,
            "top_cheek_mm": topCheek,
            "mid_cheek_mm": midCheek,
            "chin_mm": chin
        ]
    }
}
