# WearLink — Packet Framing & Codec

Both apps MUST encode/decode identically. Reference implementations:
- iOS: `WearLink/BLE/PacketCodec.swift`
- Wear OS: `wear_app/lib/ble/packet_codec.dart` (Dart) + native Kotlin for the GATT server path.

## Frame layout

```
 offset  field        size  notes
 0       seq         u16   monotonic per-direction counter; ack/dedup key
 2       flags       u8    bit0 = continuation (more chunks for same seq); bits 1-7 reserved
 3       len         u16   payload byte count (excludes header + crc)
 5       payload     len   protobuf message bytes (or chunk of one)
 5+len   crc8        u8    CRC-8/SMBUS-style (poly 0x07) over bytes [0 .. 5+len-1]
```

Header = 5 B, CRC = 1 B. Effective per-frame payload ≤ MTU − 6.

## Chunking (payloads > MTU)
1. Sender splits payload into chunks ≤ (MTU − 6).
2. Each chunk gets the SAME `seq`, with `flags.continuation = 1` on all but the
   last chunk (last chunk: continuation = 0).
3. Receiver buffers chunks keyed by `seq` until it sees continuation = 0,
   then concatenates in arrival order, validates CRC per chunk, decodes protobuf.
4. Out-of-order chunks are accepted (sort by nothing — order is implicit; if
   strict order needed later, add a `chunkIndex` to flags extension).
5. After decoding, receiver acks the whole `seq` via `LinkControl.ack`.

## CRC-8 / SMBUS-style
- Polynomial: 0x07, init: 0x00, no input/output reflection, no final XOR.
- Known-answer: CRC("123456789") = 0xF4.
- Purpose: catch BLE bit errors not caught by the link-layer CRC (24-bit CRC is
  good but not perfect over long sessions). Not a security boundary.
- (Name is SMBUS-style, not Maxim — Maxim CRC-8 uses poly 0x31 + reflection and
  would give 0xA1; we do NOT use that.)

## seq counters
- Independent per direction (phone→watch, watch→phone).
- Per-characteristic? No — per-direction global is sufficient; dedup is by
  `seq` + source. Wrap at u16 max — fine; monotonic only matters within a
  retransmit window (~seconds).
- On reconnect, both sides reset their `seq` to 0. Stale pre-reconnect frames
  from a half-open connection are dropped by supervision timeout before reset.

## Replay protection (action commands)
`CallAction`, `NotifAction`, `MusicCommand` carry a `nonce` (u32, random per
command). Receiver tracks last N nonces per source; drops duplicates. Prevents
a retransmitted accept/reject from firing twice.

## Compression
Health batches MAY be gzip-compressed before chunking. Compression is indicated
by the `HealthFrame.compressed` proto field, not by frame header flags. Receiver
decompresses after reassembly, before protobuf decode. Music/notification
payloads are small enough to skip compression.