import Foundation

// MARK: - Protobuf wire format helpers

/// Manual protobuf serialization for all WearLink protocol messages.
///
/// Wire types (per protobuf spec):
///   0 = varint  (int32/int64/uint32/uint64/bool/enum)
///   1 = 64-bit  (fixed64, double)
///   2 = length-delimited (string, bytes, embedded message, packed repeated)
///   5 = 32-bit  (fixed32, float)
///
/// Tag encoding: (field_number << 3) | wire_type
enum ProtoCodec {

    // MARK: - Varint

    /// Encode an unsigned integer as a base-128 varint.
    static func encodeVarint< T: UnsignedInteger>(_ value: T) -> Data {
        var v = UInt64(value)
        var data = Data()
        while v > 127 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
        return data
    }

    /// Decode a varint from `data` starting at `offset`. Advances `offset` past the varint.
    /// Returns nil on overflow or truncated data.
    static func decodeVarint(from data: Data, offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            if shift > 63 { return nil } // overflow
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                return result
            }
        }
        return nil // truncated
    }

    // MARK: - Fixed32 (wire type 5)

    static func encodeFixed32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    static func decodeFixed32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4
        return value
    }

    // MARK: - Fixed64 (wire type 1)

    static func encodeFixed64(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt64>.size)
    }

    static func decodeFixed64(from data: Data, offset: inout Int) -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        let value = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
        offset += 8
        return value
    }

    // MARK: - Tag

    /// Build a field tag: (field_number << 3) | wire_type
    static func tag(_ fieldNumber: UInt32, _ wireType: UInt8) -> Data {
        encodeVarint(UInt64(fieldNumber << 3) | UInt64(wireType))
    }

    /// Decode a field tag. Returns (fieldNumber, wireType) or nil.
    static func decodeTag(from data: Data, offset: inout Int) -> (UInt32, UInt8)? {
        guard let raw = decodeVarint(from: data, offset: &offset) else { return nil }
        return (UInt32(raw >> 3), UInt8(raw & 0x07))
    }

    // MARK: - Length-delimited helpers

    static func encodeLengthDelimited(_ payload: Data) -> Data {
        encodeVarint(UInt64(payload.count)) + payload
    }

    static func decodeLengthDelimited(from data: Data, offset: inout Int) -> Data? {
        guard let len = decodeVarint(from: data, offset: &offset),
              len <= UInt64(Int.max)
        else { return nil }
        let count = Int(len)
        guard offset + count <= data.count else { return nil }
        let slice = data[offset ..< offset + count]
        offset += count
        return slice
    }

    // MARK: - String / Bytes

    static func encodeString(_ value: String) -> Data {
        encodeLengthDelimited(Data(value.utf8))
    }

    static func decodeString(from data: Data, offset: inout Int) -> String? {
        guard let raw = decodeLengthDelimited(from: data, offset: &offset) else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    static func encodeBytes(_ value: Data) -> Data {
        encodeLengthDelimited(value)
    }

    static func decodeBytes(from data: Data, offset: inout Int) -> Data? {
        decodeLengthDelimited(from: data, offset: &offset)
    }

    // MARK: - Double / Float

    static func encodeDouble(_ value: Double) -> Data {
        encodeFixed64(value.bitPattern)
    }

    static func decodeDouble(from data: Data, offset: inout Int) -> Double? {
        guard let raw = decodeFixed64(from: data, offset: &offset) else { return nil }
        return Double(bitPattern: raw)
    }

    static func encodeFloat(_ value: Float) -> Data {
        encodeFixed32(value.bitPattern)
    }

    static func decodeFloat(from data: Data, offset: inout Int) -> Float? {
        guard let raw = decodeFixed32(from: data, offset: &offset) else { return nil }
        return Float(bitPattern: raw)
    }

    // MARK: - Bool

    static func encodeBool(_ value: Bool) -> Data {
        encodeVarint(value ? UInt64(1) : UInt64(0))
    }

    static func decodeBool(from data: Data, offset: inout Int) -> Bool? {
        guard let raw = decodeVarint(from: data, offset: &offset) else { return nil }
        return raw != 0
    }

    // MARK: - Enum (varint-backed)

    static func encodeEnum<T: RawRepresentable>(_ value: T) -> Data where T.RawValue == UInt32 {
        encodeVarint(UInt64(value.rawValue))
    }

    static func decodeEnum<T: RawRepresentable>(from data: Data, offset: inout Int) -> T? where T.RawValue == UInt32 {
        guard let raw = decodeVarint(from: data, offset: &offset) else { return nil }
        return T(rawValue: UInt32(raw))
    }

    // MARK: - Embedded message (length-delimited)

    static func encodeEmbeddedMessage(_ data: Data) -> Data {
        encodeLengthDelimited(data)
    }

    // MARK: - Skip field (for unknown fields during decode)

    static func skipField(wireType: UInt8, data: Data, offset: inout Int) {
        switch wireType {
        case 0: // varint
            _ = decodeVarint(from: data, offset: &offset)
        case 1: // 64-bit
            guard offset + 8 <= data.count else { return }
            offset += 8
        case 2: // length-delimited
            guard let len = decodeVarint(from: data, offset: &offset),
                  len <= UInt64(Int.max),
                  offset + Int(len) <= data.count
            else { return }
            offset += Int(len)
        case 5: // 32-bit
            guard offset + 4 <= data.count else { return }
            offset += 4
        default:
            break
        }
    }
}

// =============================================================================================
// MARK: - DeviceInfo
// =============================================================================================

extension ProtoCodec {

    static func encodeDeviceInfo(_ msg: DeviceInfo) -> Data {
        var data = Data()
        // model (string, field 1)
        if !msg.model.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.model))
        }
        // firmware (string, field 2)
        if !msg.firmware.isEmpty {
            data.append(tag(2, 2))
            data.append(encodeString(msg.firmware))
        }
        // battery_percent (uint32, field 3)
        data.append(tag(3, 0))
        data.append(encodeVarint(UInt64(msg.batteryPercent)))
        // preferred_mtu (uint32, field 4)
        data.append(tag(4, 0))
        data.append(encodeVarint(UInt64(msg.preferredMtu)))
        return data
    }

    static func decodeDeviceInfo(from data: Data) -> DeviceInfo? {
        var offset = 0
        var model = ""
        var firmware = ""
        var batteryPercent: UInt32 = 0
        var preferredMtu: UInt32 = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                model = v
            case (2, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                firmware = v
            case (3, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                batteryPercent = UInt32(v)
            case (4, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                preferredMtu = UInt32(v)
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return DeviceInfo(
            model: model,
            firmware: firmware,
            batteryPercent: batteryPercent,
            preferredMtu: preferredMtu
        )
    }
}

// =============================================================================================
// MARK: - LinkControl
// =============================================================================================

extension ProtoCodec {

    static func encodeLinkControl(_ msg: LinkControl) -> Data {
        var data = Data()
        // kind (enum, field 1)
        data.append(tag(1, 0))
        data.append(encodeVarint(UInt64(msg.kind.rawValue)))
        // seq (uint32, field 2)
        data.append(tag(2, 0))
        data.append(encodeVarint(UInt64(msg.seq)))
        // timestamp_ms (uint64, field 3)
        data.append(tag(3, 0))
        data.append(encodeVarint(msg.timestampMs))
        // payload (bytes, field 4)
        data.append(tag(4, 2))
        data.append(encodeBytes(msg.payload))
        return data
    }

    static func decodeLinkControl(from data: Data) -> LinkControl? {
        var offset = 0
        var kind: LinkControl.Kind = .kindUnspecified
        var seq: UInt32 = 0
        var timestampMs: UInt64 = 0
        var payload = Data()

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = LinkControl.Kind(rawValue: UInt32(raw))
                else { return nil }
                kind = v
            case (2, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                seq = UInt32(v)
            case (3, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                timestampMs = v
            case (4, 2):
                guard let v = decodeBytes(from: data, offset: &offset) else { return nil }
                payload = v
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return LinkControl(kind: kind, seq: seq, timestampMs: timestampMs, payload: payload)
    }
}

// =============================================================================================
// MARK: - HealthSample
// =============================================================================================

extension ProtoCodec {

    static func encodeHealthSample(_ msg: HealthSample) -> Data {
        var data = Data()
        // type (enum, field 1)
        data.append(tag(1, 0))
        data.append(encodeVarint(UInt64(msg.type.rawValue)))
        // timestamp_ms (int64, field 2)
        data.append(tag(2, 0))
        data.append(encodeVarint(UInt64(bitPattern: Int64(msg.timestampMs))))
        // value (double, field 3)
        data.append(tag(3, 1))
        data.append(encodeDouble(msg.value))
        return data
    }

    static func decodeHealthSample(from data: Data) -> HealthSample? {
        var offset = 0
        var type: HealthSample.`Type` = .typeUnspecified
        var timestampMs: Int64 = 0
        var value: Double = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = HealthSample.`Type`(rawValue: UInt32(raw))
                else { return nil }
                type = v
            case (2, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                timestampMs = Int64(bitPattern: v)
            case (3, 1):
                guard let v = decodeDouble(from: data, offset: &offset) else { return nil }
                value = v
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return HealthSample(type: type, timestampMs: timestampMs, value: value)
    }
}

// =============================================================================================
// MARK: - HealthFrame
// =============================================================================================

extension ProtoCodec {

    static func encodeHealthFrame(_ msg: HealthFrame) -> Data {
        var data = Data()
        // sequence (uint32, field 1)
        data.append(tag(1, 0))
        data.append(encodeVarint(UInt64(msg.sequence)))
        // samples (repeated HealthSample, field 2) — each as embedded message
        for sample in msg.samples {
            data.append(tag(2, 2))
            data.append(encodeEmbeddedMessage(encodeHealthSample(sample)))
        }
        // compressed (bool, field 3)
        data.append(tag(3, 0))
        data.append(encodeBool(msg.compressed))
        return data
    }

    static func decodeHealthFrame(from data: Data) -> HealthFrame? {
        var offset = 0
        var sequence: UInt32 = 0
        var samples: [HealthSample] = []
        var compressed: Bool = false

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                sequence = UInt32(v)
            case (2, 2):
                guard let raw = decodeLengthDelimited(from: data, offset: &offset),
                      let sample = decodeHealthSample(from: raw)
                else { return nil }
                samples.append(sample)
            case (3, 0):
                guard let v = decodeBool(from: data, offset: &offset) else { return nil }
                compressed = v
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return HealthFrame(sequence: sequence, samples: samples, compressed: compressed)
    }
}

// =============================================================================================
// MARK: - HealthControl
// =============================================================================================

extension ProtoCodec {

    static func encodeHealthControl(_ msg: HealthControl) -> Data {
        var data = Data()
        // command (enum, field 1)
        data.append(tag(1, 0))
        data.append(encodeVarint(UInt64(msg.command.rawValue)))
        // interval_ms (uint32, field 2)
        data.append(tag(2, 0))
        data.append(encodeVarint(UInt64(msg.intervalMs)))
        // types (repeated enum, field 3) — packed in proto3
        if !msg.types.isEmpty {
            data.append(tag(3, 2))
            var packed = Data()
            for t in msg.types {
                packed.append(encodeVarint(UInt64(t.rawValue)))
            }
            data.append(encodeLengthDelimited(packed))
        }
        return data
    }

    static func decodeHealthControl(from data: Data) -> HealthControl? {
        var offset = 0
        var command: HealthControl.Command = .cmdUnspecified
        var intervalMs: UInt32 = 0
        var types: [HealthSample.`Type`] = []

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = HealthControl.Command(rawValue: UInt32(raw))
                else { return nil }
                command = v
            case (2, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                intervalMs = UInt32(v)
            case (3, 0):
                // Unpacked varint (non-packed repeated enum)
                guard let raw = decodeVarint(from: data, offset: &offset) else { return nil }
                if let t = HealthSample.`Type`(rawValue: UInt32(raw)) {
                    types.append(t)
                }
            case (3, 2):
                // Packed repeated enum
                guard let packed = decodeLengthDelimited(from: data, offset: &offset) else { return nil }
                var packedOffset = 0
                while packedOffset < packed.count {
                    guard let raw = ProtoCodec.decodeVarint(from: packed, offset: &packedOffset) else { break }
                    if let t = HealthSample.`Type`(rawValue: UInt32(raw)) {
                        types.append(t)
                    }
                }
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return HealthControl(command: command, intervalMs: intervalMs, types: types)
    }
}

// =============================================================================================
// MARK: - CallEvent
// =============================================================================================

extension ProtoCodec {

    static func encodeCallEvent(_ msg: CallEvent) -> Data {
        var data = Data()
        // call_id (string, field 1)
        if !msg.callId.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.callId))
        }
        // caller (string, field 2)
        if !msg.caller.isEmpty {
            data.append(tag(2, 2))
            data.append(encodeString(msg.caller))
        }
        // has_video (bool, field 3)
        data.append(tag(3, 0))
        data.append(encodeBool(msg.hasVideo))
        // timestamp_ms (uint64, field 4)
        data.append(tag(4, 0))
        data.append(encodeVarint(msg.timestampMs))
        return data
    }

    static func decodeCallEvent(from data: Data) -> CallEvent? {
        var offset = 0
        var callId = ""
        var caller = ""
        var hasVideo = false
        var timestampMs: UInt64 = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                callId = v
            case (2, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                caller = v
            case (3, 0):
                guard let v = decodeBool(from: data, offset: &offset) else { return nil }
                hasVideo = v
            case (4, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                timestampMs = v
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return CallEvent(callId: callId, caller: caller, hasVideo: hasVideo, timestampMs: timestampMs)
    }
}

// =============================================================================================
// MARK: - CallAction
// =============================================================================================

extension ProtoCodec {

    static func encodeCallAction(_ msg: CallAction) -> Data {
        var data = Data()
        // call_id (string, field 1)
        if !msg.callId.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.callId))
        }
        // action (enum, field 2)
        data.append(tag(2, 0))
        data.append(encodeVarint(UInt64(msg.action.rawValue)))
        // nonce (uint32, field 3)
        data.append(tag(3, 0))
        data.append(encodeVarint(UInt64(msg.nonce)))
        return data
    }

    static func decodeCallAction(from data: Data) -> CallAction? {
        var offset = 0
        var callId = ""
        var action: CallAction.Action = .actionUnspecified
        var nonce: UInt32 = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                callId = v
            case (2, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = CallAction.Action(rawValue: UInt32(raw))
                else { return nil }
                action = v
            case (3, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                nonce = UInt32(v)
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return CallAction(callId: callId, action: action, nonce: nonce)
    }
}

// =============================================================================================
// MARK: - WearNotification
// =============================================================================================

extension ProtoCodec {

    static func encodeWearNotification(_ msg: WearNotification) -> Data {
        var data = Data()
        // notif_id (string, field 1)
        if !msg.notifId.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.notifId))
        }
        // app_name (string, field 2)
        if !msg.appName.isEmpty {
            data.append(tag(2, 2))
            data.append(encodeString(msg.appName))
        }
        // title (string, field 3)
        if !msg.title.isEmpty {
            data.append(tag(3, 2))
            data.append(encodeString(msg.title))
        }
        // body (string, field 4)
        if !msg.body.isEmpty {
            data.append(tag(4, 2))
            data.append(encodeString(msg.body))
        }
        // timestamp_ms (uint64, field 5)
        data.append(tag(5, 0))
        data.append(encodeVarint(msg.timestampMs))
        // reply_choices (repeated string, field 6)
        for choice in msg.replyChoices {
            data.append(tag(6, 2))
            data.append(encodeString(choice))
        }
        return data
    }

    static func decodeWearNotification(from data: Data) -> WearNotification? {
        var offset = 0
        var notifId = ""
        var appName = ""
        var title = ""
        var body = ""
        var timestampMs: UInt64 = 0
        var replyChoices: [String] = []

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                notifId = v
            case (2, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                appName = v
            case (3, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                title = v
            case (4, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                body = v
            case (5, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                timestampMs = v
            case (6, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                replyChoices.append(v)
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return WearNotification(
            notifId: notifId,
            appName: appName,
            title: title,
            body: body,
            timestampMs: timestampMs,
            replyChoices: replyChoices
        )
    }
}

// =============================================================================================
// MARK: - NotifAction
// =============================================================================================

extension ProtoCodec {

    static func encodeNotifAction(_ msg: NotifAction) -> Data {
        var data = Data()
        // notif_id (string, field 1)
        if !msg.notifId.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.notifId))
        }
        // action (enum, field 2)
        data.append(tag(2, 0))
        data.append(encodeVarint(UInt64(msg.action.rawValue)))
        // reply_text (string, field 3)
        if !msg.replyText.isEmpty {
            data.append(tag(3, 2))
            data.append(encodeString(msg.replyText))
        }
        // nonce (uint32, field 4)
        data.append(tag(4, 0))
        data.append(encodeVarint(UInt64(msg.nonce)))
        return data
    }

    static func decodeNotifAction(from data: Data) -> NotifAction? {
        var offset = 0
        var notifId = ""
        var action: NotifAction.Action = .actionUnspecified
        var replyText = ""
        var nonce: UInt32 = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                notifId = v
            case (2, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = NotifAction.Action(rawValue: UInt32(raw))
                else { return nil }
                action = v
            case (3, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                replyText = v
            case (4, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                nonce = UInt32(v)
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return NotifAction(notifId: notifId, action: action, replyText: replyText, nonce: nonce)
    }
}

// =============================================================================================
// MARK: - MusicNowPlaying
// =============================================================================================

extension ProtoCodec {

    static func encodeMusicNowPlaying(_ msg: MusicNowPlaying) -> Data {
        var data = Data()
        // title (string, field 1)
        if !msg.title.isEmpty {
            data.append(tag(1, 2))
            data.append(encodeString(msg.title))
        }
        // artist (string, field 2)
        if !msg.artist.isEmpty {
            data.append(tag(2, 2))
            data.append(encodeString(msg.artist))
        }
        // album (string, field 3)
        if !msg.album.isEmpty {
            data.append(tag(3, 2))
            data.append(encodeString(msg.album))
        }
        // art (bytes, field 4)
        if !msg.art.isEmpty {
            data.append(tag(4, 2))
            data.append(encodeBytes(msg.art))
        }
        // duration_ms (double, field 5)
        data.append(tag(5, 1))
        data.append(encodeDouble(msg.durationMs))
        // position_ms (double, field 6)
        data.append(tag(6, 1))
        data.append(encodeDouble(msg.positionMs))
        // playing (bool, field 7)
        data.append(tag(7, 0))
        data.append(encodeBool(msg.playing))
        // volume (float, field 8)
        data.append(tag(8, 5))
        data.append(encodeFloat(msg.volume))
        return data
    }

    static func decodeMusicNowPlaying(from data: Data) -> MusicNowPlaying? {
        var offset = 0
        var title = ""
        var artist = ""
        var album = ""
        var art = Data()
        var durationMs: Double = 0
        var positionMs: Double = 0
        var playing = false
        var volume: Float = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                title = v
            case (2, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                artist = v
            case (3, 2):
                guard let v = decodeString(from: data, offset: &offset) else { return nil }
                album = v
            case (4, 2):
                guard let v = decodeBytes(from: data, offset: &offset) else { return nil }
                art = v
            case (5, 1):
                guard let v = decodeDouble(from: data, offset: &offset) else { return nil }
                durationMs = v
            case (6, 1):
                guard let v = decodeDouble(from: data, offset: &offset) else { return nil }
                positionMs = v
            case (7, 0):
                guard let v = decodeBool(from: data, offset: &offset) else { return nil }
                playing = v
            case (8, 5):
                guard let v = decodeFloat(from: data, offset: &offset) else { return nil }
                volume = v
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return MusicNowPlaying(
            title: title,
            artist: artist,
            album: album,
            art: art,
            durationMs: durationMs,
            positionMs: positionMs,
            playing: playing,
            volume: volume
        )
    }
}

// =============================================================================================
// MARK: - MusicCommand
// =============================================================================================

extension ProtoCodec {

    static func encodeMusicCommand(_ msg: MusicCommand) -> Data {
        var data = Data()
        // command (enum, field 1)
        data.append(tag(1, 0))
        data.append(encodeVarint(UInt64(msg.command.rawValue)))
        // position_ms (double, field 2)
        data.append(tag(2, 1))
        data.append(encodeDouble(msg.positionMs))
        // volume (float, field 3)
        data.append(tag(3, 5))
        data.append(encodeFloat(msg.volume))
        // nonce (uint32, field 4)
        data.append(tag(4, 0))
        data.append(encodeVarint(UInt64(msg.nonce)))
        return data
    }

    static func decodeMusicCommand(from data: Data) -> MusicCommand? {
        var offset = 0
        var command: MusicCommand.Command = .cmdUnspecified
        var positionMs: Double = 0
        var volume: Float = 0
        var nonce: UInt32 = 0

        while offset < data.count {
            guard let (fieldNum, wireType) = decodeTag(from: data, offset: &offset) else {
                return nil
            }
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let raw = decodeVarint(from: data, offset: &offset),
                      let v = MusicCommand.Command(rawValue: UInt32(raw))
                else { return nil }
                command = v
            case (2, 1):
                guard let v = decodeDouble(from: data, offset: &offset) else { return nil }
                positionMs = v
            case (3, 5):
                guard let v = decodeFloat(from: data, offset: &offset) else { return nil }
                volume = v
            case (4, 0):
                guard let v = decodeVarint(from: data, offset: &offset) else { return nil }
                nonce = UInt32(v)
            default:
                skipField(wireType: wireType, data: data, offset: &offset)
            }
        }
        return MusicCommand(command: command, positionMs: positionMs, volume: volume, nonce: nonce)
    }
}
