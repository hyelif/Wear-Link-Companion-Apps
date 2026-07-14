import Foundation

struct WearableDevice: Identifiable, Codable {
    let id: String
    var name: String
    var model: String
    var firmware: String
    var androidVersion: String
    var appVersion: String
    var batteryLevel: Int
    var isCharging: Bool
    var isConnected: Bool
    var lastSeen: Date
}

struct DeviceSettings: Codable {
    var autoConnect: Bool = true
    var analytics: Bool = true
    var enableNotifications: Bool = true
    var bidirectionalSync: Bool = false
    var collectHealthData: Bool = true
    var showAlbumArt: Bool = false
    var watchFaceAlwaysOn: Bool = true

    /// Parameterless init using the defaults above. Required because the
    /// explicit `init(from:)` below suppresses the synthesized memberwise
    /// initializer, which would otherwise make `DeviceSettings()` unavailable.
    init() {}

    enum CodingKeys: String, CodingKey {
        case autoConnect
        case analytics
        case enableNotifications
        case bidirectionalSync
        case collectHealthData
        case showAlbumArt
        case watchFaceAlwaysOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        analytics = try container.decodeIfPresent(Bool.self, forKey: .analytics) ?? true
        enableNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableNotifications) ?? true
        bidirectionalSync = try container.decodeIfPresent(Bool.self, forKey: .bidirectionalSync) ?? false
        collectHealthData = try container.decodeIfPresent(Bool.self, forKey: .collectHealthData) ?? true
        showAlbumArt = try container.decodeIfPresent(Bool.self, forKey: .showAlbumArt) ?? false
        watchFaceAlwaysOn = try container.decodeIfPresent(Bool.self, forKey: .watchFaceAlwaysOn) ?? true
    }
}
