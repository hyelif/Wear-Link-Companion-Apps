import Foundation
import CoreBluetooth

/// Central place for GATT UUIDs. Mirrors `protocol/GATT.md`.
/// Uses a random 128-bit base to avoid collision with Bluetooth SIG-assigned
/// UUIDs. Base: 96812f26-7d24-4287-98cc-736bc4d49a61
/// Short handles are substituted into the first 4 hex chars of the base.
enum WearLinkUUID {
    static let service            = CBUUID(string: "FE012f26-7d24-4287-98cc-736bc4d49a61")

    static let deviceInfo          = CBUUID(string: "FE102f26-7d24-4287-98cc-736bc4d49a61")
    static let healthStream        = CBUUID(string: "FE202f26-7d24-4287-98cc-736bc4d49a61")
    static let healthControl       = CBUUID(string: "FE212f26-7d24-4287-98cc-736bc4d49a61")
    static let callEvent           = CBUUID(string: "FE302f26-7d24-4287-98cc-736bc4d49a61")
    static let callAction          = CBUUID(string: "FE312f26-7d24-4287-98cc-736bc4d49a61")
    static let notification        = CBUUID(string: "FE402f26-7d24-4287-98cc-736bc4d49a61")
    static let notificationAction  = CBUUID(string: "FE412f26-7d24-4287-98cc-736bc4d49a61")
    static let musicNowPlaying     = CBUUID(string: "FE502f26-7d24-4287-98cc-736bc4d49a61")
    static let musicCommand        = CBUUID(string: "FE512f26-7d24-4287-98cc-736bc4d49a61")
    static let linkControl         = CBUUID(string: "FE602f26-7d24-4287-98cc-736bc4d49a61")
}