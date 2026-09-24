import CoreGraphics
import Foundation

struct Device: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let radius: Int

    var isRound: Bool { radius > 0 && radius >= min(width, height) / 2 - 1 }
    var aspect: CGFloat { CGFloat(height) / CGFloat(width) }
    var screenSize: CGSize { CGSize(width: width, height: height) }

    var previewSize: CGSize {
        let sizes = Device.previewSizes[id] ?? [width, height]
        return CGSize(width: sizes[0], height: sizes[1])
    }
}

extension Device {
    static let all: [Device] = [
        .init(id: "xiaomi_color", name: "Xiaomi Watch Color", width: 454, height: 454, radius: 227),
        .init(id: "xiaomi_color_sport", name: "Xiaomi Watch Color Sport", width: 454, height: 454, radius: 227),
        .init(id: "xiaomi_color_2/s1/s2", name: "Xiaomi Watch S1/S2/Color 2", width: 466, height: 466, radius: 233),
        .init(id: "xiaomi_watch_s1_pro", name: "Xiaomi Watch S1 Pro", width: 480, height: 480, radius: 240),
        .init(id: "xiaomi_watch_s3", name: "Xiaomi Watch S3", width: 466, height: 466, radius: 233),
        .init(id: "xiaomi_watch_s4", name: "Xiaomi Watch S4", width: 466, height: 466, radius: 233),
        .init(id: "redmi/poco_watch", name: "Redmi/Poco Watch", width: 320, height: 360, radius: 60),
        .init(id: "redmi_watch_2_lite", name: "Redmi Watch 2 Lite", width: 320, height: 360, radius: 60),
        .init(id: "redmi_watch_3", name: "Redmi Watch 3", width: 390, height: 450, radius: 86),
        .init(id: "redmi_watch_3_active", name: "Redmi Watch 3 Active", width: 240, height: 280, radius: 55),
        .init(id: "redmi_watch_4", name: "Redmi Watch 4", width: 390, height: 450, radius: 90),
        .init(id: "redmi_watch_5", name: "Redmi Watch 5", width: 432, height: 514, radius: 103),
        .init(id: "redmi_watch_5_active", name: "Redmi Watch 5 Active", width: 320, height: 385, radius: 82),
        .init(id: "redmi_watch_5_lite", name: "Redmi Watch 5 Lite", width: 410, height: 502, radius: 110),
        .init(id: "redmi_band_pro", name: "Redmi Band Pro", width: 194, height: 368, radius: 28),
        .init(id: "xiaomi_band_7_pro", name: "Xiaomi Band 7 Pro", width: 280, height: 456, radius: 28),
        .init(id: "xiaomi_band_8", name: "Xiaomi Band 8", width: 192, height: 490, radius: 100),
        .init(id: "xiaomi_band_8_pro", name: "Xiaomi Band 8 Pro", width: 336, height: 480, radius: 48),
        .init(id: "xiaomi_band_9", name: "Xiaomi Band 9", width: 192, height: 490, radius: 100),
        .init(id: "xiaomi_band_9_pro", name: "Xiaomi Band 9 Pro", width: 336, height: 480, radius: 48),
        .init(id: "xiaomi_band_10", name: "Xiaomi Band 10", width: 212, height: 520, radius: 106),
        .init(id: "xiaomi_band_10_pro", name: "Xiaomi Smart Band 10 Pro", width: 336, height: 480, radius: 48),
        .init(id: "70mai_saphir", name: "70mai Saphir", width: 368, height: 448, radius: 60),
    ]

    static func find(_ id: String) -> Device? { all.first { $0.id == id } }

    private static let previewSizes: [String: [Int]] = [
        "xiaomi_color": [246, 246],
        "xiaomi_color_sport": [246, 246],
        "xiaomi_color_2/s1/s2": [246, 246],
        "xiaomi_watch_s1_pro": [280, 280],
        "xiaomi_watch_s3": [326, 326],
        "xiaomi_watch_s4": [326, 326],
        "xiaomi_band_7_pro": [220, 358],
        "redmi_watch_3": [234, 270],
        "redmi_watch_3_active": [156, 182],
        "redmi_watch_4": [234, 270],
        "redmi_watch_5": [432, 514],
        "redmi_watch_5_active": [180, 216],
        "redmi_watch_5_lite": [244, 298],
        "redmi_band_pro": [110, 208],
        "xiaomi_band_8": [122, 310],
        "xiaomi_band_8_pro": [230, 328],
        "xiaomi_band_9": [122, 310],
        "xiaomi_band_9_pro": [230, 328],
        "xiaomi_band_10": [212, 520],
    ]
}
