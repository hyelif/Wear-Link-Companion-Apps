import XCTest
@testable import WearLink

/// Verifies PacketCodec round-trip + CRC + reassembly.
/// Known-answer vector MUST match wear_app/test/ble/packet_codec_test.dart.
final class PacketCodecTests: XCTestCase {

    func testRoundTripSingleFrame() {
        let payload = Data([1, 2, 3, 4, 5])
        let enc = PacketCodec.encode(seq: 42, continuation: false, payload: payload)
        XCTAssertEqual(enc.count, PacketCodec.headerSize + payload.count + PacketCodec.crcSize)

        let frame = PacketCodec.decode(enc)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.seq, 42)
        XCTAssertEqual(frame?.isContinuation, false)
        XCTAssertEqual(frame?.payload, payload)
    }

    func testContinuationFlagSet() {
        let enc = PacketCodec.encode(seq: 1, continuation: true, payload: Data([0xAA, 0xBB]))
        XCTAssertEqual(PacketCodec.decode(enc)?.isContinuation, true)
    }

    func testCRCMismatchRejected() {
        var enc = PacketCodec.encode(seq: 1, continuation: false, payload: Data([9, 9, 9]))
        enc[enc.count - 1] ^= 0xFF
        XCTAssertNil(PacketCodec.decode(enc))
    }

    func testTruncatedFrameRejected() {
        let enc = PacketCodec.encode(seq: 1, continuation: false, payload: Data([1, 2, 3]))
        XCTAssertNil(PacketCodec.decode(enc.prefix(3)))
    }

    func testEmptyPayloadRoundTrips() {
        let enc = PacketCodec.encode(seq: 0, continuation: false, payload: Data())
        XCTAssertEqual(PacketCodec.decode(enc)?.payload, Data())
    }

    func testCRC8KnownAnswer() {
        // "123456789" => 0xF4 for CRC-8/SMBUS-style (poly 0x07, no reflection).
        let data = Data("123456789".utf8)
        XCTAssertEqual(PacketCodec.crc8(of: data), 0xF4)
    }

    func testReassemblerMultiChunk() {
        let big = Data((0..<100).map { UInt8($0) })
        let r = Reassembler()
        let c1 = PacketCodec.encode(seq: 7, continuation: true, payload: big.prefix(30))
        let c2 = PacketCodec.encode(seq: 7, continuation: true, payload: big.subdata(in: 30..<60))
        let c3 = PacketCodec.encode(seq: 7, continuation: false, payload: big.subdata(in: 60..<100))

        XCTAssertNil(r.add(PacketCodec.decode(c1)!))
        XCTAssertNil(r.add(PacketCodec.decode(c2)!))
        let got = r.add(PacketCodec.decode(c3)!)
        XCTAssertEqual(got, big)
    }

    func testReassemblerSingleFrame() {
        let r = Reassembler()
        let enc = PacketCodec.encode(seq: 5, continuation: false, payload: Data([1, 1, 1]))
        XCTAssertEqual(r.add(PacketCodec.decode(enc)!), Data([1, 1, 1]))
    }
}