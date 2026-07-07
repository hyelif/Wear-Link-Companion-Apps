import Foundation

// =============================================================================================
// MARK: - DeviceInfo
// =============================================================================================

struct DeviceInfo {
    var model: String
    var firmware: String
    var batteryPercent: UInt32
    var preferredMtu: UInt32
}

// =============================================================================================
// MARK: - LinkControl
// =============================================================================================

struct LinkControl {
    enum Kind: UInt32 {
        case kindUnspecified = 0
        case heartbeat = 1
        case ack = 2
        case nack = 3
        case reconnectToken = 4
    }
    var kind: Kind
    var seq: UInt32
    var timestampMs: UInt64
    var payload: Data
}

// =============================================================================================
// MARK: - Health
// =============================================================================================

struct HealthSample {
    enum `Type`: UInt32 {
        case typeUnspecified = 0
        case heartRateBpm = 1
        case steps = 2
        case spo2Percent = 3
        case hrvMs = 4
        case sleep = 5
        case calories = 6
        case distanceMeters = 7
    }
    /// Alias so call sites can write `HealthSample.SampleType(rawValue:)` without
    /// the parser resolving `HealthSample.Type` as the metatype expression.
    typealias SampleType = `Type`
    var type: `Type`
    var timestampMs: Int64
    var value: Double
}

struct HealthFrame {
    var sequence: UInt32
    var samples: [HealthSample]
    var compressed: Bool
}

struct HealthControl {
    enum Command: UInt32 {
        case cmdUnspecified = 0
        case sendNow = 1
        case setIntervalMs = 2
        case setTypes = 3
        case startActive = 4
        case stopActive = 5
    }
    var command: Command
    var intervalMs: UInt32
    var types: [HealthSample.`Type`]
}

// =============================================================================================
// MARK: - Call
// =============================================================================================

struct CallEvent {
    var callId: String
    var caller: String
    var hasVideo: Bool
    var timestampMs: UInt64
}

struct CallAction {
    enum Action: UInt32 {
        case actionUnspecified = 0
        case accept = 1
        case reject = 2
        case mute = 3
        case end = 4
    }
    var callId: String
    var action: Action
    var nonce: UInt32
}

// =============================================================================================
// MARK: - WearNotification
// =============================================================================================

struct WearNotification {
    var notifId: String
    var appName: String
    var title: String
    var body: String
    var timestampMs: UInt64
    var replyChoices: [String]
}

struct NotifAction {
    enum Action: UInt32 {
        case actionUnspecified = 0
        case dismiss = 1
        case reply = 2
    }
    var notifId: String
    var action: Action
    var replyText: String
    var nonce: UInt32
}

// =============================================================================================
// MARK: - Music
// =============================================================================================

struct MusicNowPlaying {
    var title: String
    var artist: String
    var album: String
    var art: Data
    var durationMs: Double
    var positionMs: Double
    var playing: Bool
    var volume: Float
}

struct MusicCommand {
    enum Command: UInt32 {
        case cmdUnspecified = 0
        case play = 1
        case pause = 2
        case next = 3
        case previous = 4
        case seek = 5
        case setVolume = 6
    }
    var command: Command
    var positionMs: Double
    var volume: Float
    var nonce: UInt32
}
