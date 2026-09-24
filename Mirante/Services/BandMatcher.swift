import Foundation

enum BandMatcher {
    static func matches(advertisedName: String) -> Device? {
        let cleaned = advertisedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let exact = Device.all.first(where: { $0.name.lowercased() == cleaned }) {
            return exact
        }

        let normalizedAdvertised = normalized(cleaned)
        let candidates = Device.all.filter { device in
            let name = device.name.lowercased()
            if cleaned.contains(name) { return true }
            let normalizedDevice = normalized(name)
            guard !normalizedDevice.isEmpty else { return false }
            return normalizedAdvertised.contains(normalizedDevice)
        }
        return candidates.max { $0.name.count < $1.name.count }
    }

    static func isLikelyBand(advertisedName: String) -> Bool {
        if matches(advertisedName: advertisedName) != nil { return true }
        let lower = advertisedName.lowercased()
        let keywords = ["xiaomi", "redmi", "amazfit", "poco", "70mai", "mi band", "smart band", "band", "watch"]
        return keywords.contains { lower.contains($0) }
    }

    private static func normalized(_ name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "smart" }
            .joined(separator: " ")
    }
}
