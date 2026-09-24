import Foundation

struct DataSource: Identifiable, Hashable, Codable {
    /// fprj source id as string ("0" = none)
    let id: String
    let name: String
    let tip: String
    /// GMF counterpart id, when known
    let gmfID: String?

    init(_ id: String, _ name: String, _ tip: String = "", gmfID: String? = nil) {
        self.id = id
        self.name = name
        self.tip = tip
        self.gmfID = gmfID
    }
}

enum DataSourceCatalog {
    /// Common value sources shared by most Xiaomi wearables (fprj id space).
    static let common: [DataSource] = [
        .init("0", "None", "No data source used"),
        .init("8", "Hour", "Hour in 24h format, 0-23"),
        .init("9", "Minute", "Minute, 0-59"),
        .init("10", "Second", "Second, 0-59"),
        .init("11", "Day", "Day of month"),
        .init("12", "Week", "Weekday, 0 = Sunday"),
        .init("13", "Month", "Month, 1-12"),
        .init("14", "Year", "Gregorian year"),
        .init("15", "Current temperature", "Temperature in °C"),
        .init("19", "Battery charging status", "0 = discharging, 1 = charging"),
        .init("20", "Battery percent", "Battery percentage"),
        .init("21", "Heart rate", "Real-time heart rate"),
        .init("23", "Current step count", "Real-time step count"),
        .init("24", "Step target", "Step goal"),
        .init("25", "Active Calorie", "Active calories"),
        .init("26", "Active calorie target value", "Active calorie goal"),
        .init("27", "Stand Up value", "Stand hours count"),
    ]

    static func forDevice(_ deviceID: String) -> [DataSource] { common }

    static func name(for id: String, deviceID: String) -> String {
        common.first { $0.id == id }?.name ?? "Source \(id)"
    }

    /// Simulated values used by the live preview, keyed by source name.
    static let previewValues: [String: String] = [
        "Hour": "10", "Minute": "08", "Second": "56",
        "Day": "21", "Month": "05", "Year": "2025", "Week": "2",
        "Heart rate": "68", "Current temperature": "24",
        "Weather temp": "24", "Battery percent": "80",
        "Current step count": "7645", "Step target": "8000",
        "Active Calorie": "465", "Active calorie target value": "600",
        "Stand Up value": "8",
    ]

    static func previewValue(forSourceID id: String, deviceID: String) -> String {
        guard let source = common.first(where: { $0.id == id }) else { return "0" }
        if source.id == "0" { return "0" }
        if let value = previewValues[source.name] { return value }
        return "0"
    }
}
