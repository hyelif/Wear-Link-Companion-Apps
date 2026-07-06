import Foundation
import CoreBluetooth

/// Central place for GATT UUIDs. Mirrors `protocol/GATT.md`.
/// TODO: replace with 128-bit UUIDs derived from a base once finalized.
enum WearLinkUUID {
    static let service            = CBUUID(string: "FE01")

    static let deviceInfo          = CBUUID(string: "FE10")
    static let healthStream        = CBUUID(string: "FE20")
    static let healthControl       = CBUUID(string: "FE21")
    static let callEvent           = CBUUID(string: "FE30")
    static let callAction          = CBUUID(string: "FE31")
    static let notification        = CBUUID(string: "FE40")
    static let notificationAction  = CBUUID(string: "FE41")
    static let musicNowPlaying     = CBUUID(string: "FE50")
    static let musicCommand        = CBUUID(string: "FE51")
    static let linkControl         = CBUUID(string: "FE60")
}