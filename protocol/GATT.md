# WearLink — GATT Protocol

**iOS = Central. Watch = Peripheral.** Watch advertises the WearLink service;
iPhone scans, connects, bonds (LE Secure Connections), and subscribes.

> Single source of truth for both apps. The Swift `BluetoothUUIDs.swift` table
> and the Wear OS Kotlin service defs MUST mirror this file. Drift = bug.

## Service & characteristic map

| UUID (16-bit short handle, placeholder — finalize to 128-bit before ship) | Name | Direction | Properties | Payload (see `proto/`) |
|---|---|---|---|---|
| `0xFE01` | **WearLink Service** | — | — | — |
| `0xFE10` | DeviceInfo | watch→phone | read | `DeviceInfo` |
| `0xFE20` | HealthStream | watch→phone | **notify** | `HealthFrame` (batched) |
| `0xFE21` | HealthControl | phone→watch | write | `HealthControl` |
| `0xFE30` | CallEvent | phone→watch | write + notify | `CallEvent` |
| `0xFE31` | CallAction | watch→phone | write | `CallAction` |
| `0xFE40` | Notification | phone→watch | write | `Notification` |
| `0xFE41` | NotifAction | watch→phone | write | `NotifAction` |
| `0xFE50` | MusicNowPlaying | phone→watch | notify | `MusicNowPlaying` |
| `0xFE51` | MusicCommand | watch→phone | write | `MusicCommand` |
| `0xFE60` | LinkControl | bidirectional | write + notify | `LinkControl` |

### Direction convention
- "phone→watch" = iPhone **writes** to that characteristic on the watch.
- "watch→phone" = iPhone **subscribes (notify)** to that characteristic.
- Bidirectional = write + notify both enabled.

## UUID strategy
16-bit handles above are placeholders for readability. Before ship, derive
proper 128-bit UUIDs from a project base:
`0000XXXX-0000-1000-8000-00805F9B34FB` (Bluetooth SIG base) is RESERVED — do
NOT use it for proprietary services. Generate a random 128-bit base and suffix
the short handle, e.g. `a1b2c3d4-...-FE01-...`. Update both apps together.

## Connection parameters (battery-tuned)

| Parameter | Idle | Active (call in progress) |
|---|---|---|
| Advertising interval | 1000 ms | 100 ms |
| Connection interval (req) | 200–500 ms | 30–50 ms |
| Slave latency | 4 | 0 |
| Supervision timeout | 6 s | 4 s |
| MTU | 247 (negotiate up on connect) | 247 |
| Heartbeat (LinkControl) | 30 s | 5 s |

Phone scan duty-cycle (disconnected): scan 2 s, rest 8 s. Instant scan on a
call/notification/music event (no waiting for the cycle).

## Bonding
Bond via LE Secure Connections (pairing variant: Just Works for the first
pair, optional passkey if user wants verification). Bonded link encrypts all
traffic → no app-layer crypto needed except a replay-nonce on action commands
(`CallAction`, `NotifAction`, `MusicCommand`) to prevent accidental re-apply on
BLE retransmit.

## Ack model
Every write from either side is acknowledged via `LinkControl` carrying the
originating `seq`. Sender retries (idempotent) up to 3× with backoff. Notify
streams (health/music) are fire-and-forget; gaps tolerated — health batches are
self-describing and deduped on the phone by sample timestamp.

## Message sizes
- Single characteristic value ≤ MTU (247 B after negotiation).
- Larger payloads (health batches, art thumbnails) chunked — see `codec.md`.
- Album art: downscale to ≤64×64 JPEG, ≤2 KB, sent as a multi-chunk `MusicNowPlaying.art` field.