import Foundation

/// Abstraction over the (future) path that delivers a compiled watchface to a
/// paired band. Deliberately conservative: nothing is ever pushed to a device
/// without explicit user action, and every payload is validated first.
protocol WatchFaceTransport {
    var isAvailable: Bool { get }
    func validate(payload: Data, for device: Device) -> TransportValidation
    func install(payload: Data, on device: Device) async throws
}

/// Mirante's hard safety ceiling for a compiled face payload (bytes). This is a
/// sanity bound, not the band's own limit — real faces for 10 Pro-class bands
/// routinely exceed 512 KB, so the cap is deliberately generous. The band
/// itself rejects anything it cannot accept.
let maxFacePayloadBytes = 16 * 1024 * 1024

enum TransportValidation: Equatable {
    case ok
    case empty
    case tooLarge(Int)
    case wrongExtension
    case deviceMismatch(expected: String, found: String?)
    case notCompiled

    var isOk: Bool { self == .ok }

    var message: String {
        switch self {
        case .ok: return String(localized: "Ready to install.")
        case .empty: return String(localized: "The file is empty.")
        case .tooLarge(let limit):
            return String(localized: "The file is larger than Mirante's \(String(limit))-byte safety cap. This cap is a guardrail, not the band's own limit.")
        case .wrongExtension: return String(localized: "Expected a compiled .bin or .face file.")
        case .deviceMismatch(let expected, let found):
            return String(localized: "Built for \(expected), file targets \(found ?? "unknown").")
        case .notCompiled:
            return String(localized: "Only compiled .bin / .face files can be installed to a band. Export and compile your face first, or import a compiled file from Explore.")
        }
    }
}

enum TransportError: LocalizedError {
    case validation(TransportValidation)
    case bluetoothUnavailable
    case deviceNotPaired
    case transferFailed(String)
    case sendingUnavailable
    case abortedByUser
    case authKeyRequired
    case authKeyMalformed
    case authRejected(String)

    var errorDescription: String? {
        switch self {
        case .validation(let v): return v.message
        case .bluetoothUnavailable: return String(localized: "Bluetooth is unavailable.")
        case .deviceNotPaired: return String(localized: "No supported band is paired.")
        case .transferFailed(let reason): return String(localized: "Transfer failed: \(reason)")
        case .sendingUnavailable:
            return String(localized: "This band doesn't expose the Xiaomi BLE protocol channel (GATT service FE95). Its install channel is Classic-SPP only, which iOS apps can't reach — keep it paired to Mi Fitness for now.")
        case .abortedByUser: return String(localized: "Installation cancelled.")
        case .authKeyRequired:
            return String(localized: "This band requires its auth key (32 hex characters) before it accepts files. Paste it from your Mi Fitness registration data (phone backup or Android root) to enable installation.")
        case .authKeyMalformed:
            return String(localized: "The auth key must be exactly 32 hexadecimal characters (0-9, a-f).")
        case .authRejected(let reason):
            return String(localized: "The band rejected the auth key (\(reason)). Double-check it was pulled from Mi Fitness for this exact band.")
        }
    }
}

/// The header every compiled Xiaomi face file shares.
enum CompiledFaceMagic {
    static let bytes: [UInt8] = [0x5A, 0xA5, 0x34, 0x12]

    static func matches(_ data: Data) -> Bool {
        guard data.count >= bytes.count else { return false }
        return data.prefix(bytes.count).elementsEqual(bytes)
    }
}

/// Placeholder transport. Real BLE plumbing lands in a later milestone; until
/// then every install call fails closed (never bricks, never half-writes).
struct NoopTransport: WatchFaceTransport {
    var isAvailable: Bool { false }

    func validate(payload: Data, for device: Device) -> TransportValidation {
        guard !payload.isEmpty else { return .empty }
        guard payload.count <= maxFacePayloadBytes else { return .tooLarge(maxFacePayloadBytes) }
        guard CompiledFaceMagic.matches(payload) else { return .notCompiled }
        return .ok
    }

    func install(payload: Data, on device: Device) async throws {
        let validation = validate(payload: payload, for: device)
        guard validation.isOk else { throw TransportError.validation(validation) }
        throw TransportError.sendingUnavailable
    }
}
