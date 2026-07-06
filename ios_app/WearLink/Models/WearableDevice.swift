import Foundation

struct WearableDevice: Identifiable, Codable {
    let id: String
    var name: String
    var model: String
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
}
