package com.wearlink.app

import java.util.UUID

/// UUIDs mirror protocol/GATT.md + ios_app BluetoothUUIDs.swift.
/// 16-bit short handles expanded over the Bluetooth SIG base UUID for dev.
/// TODO before ship: generate a random 128-bit base (see protocol/GATT.md).
object Uuids {
    private fun s(h: String) =
        UUID.fromString("0000${h}-0000-1000-8000-00805F9B34FB")

    val service            = s("FE01")
    val deviceInfo          = s("FE10")
    val healthStream        = s("FE20")
    val healthControl       = s("FE21")
    val callEvent           = s("FE30")
    val callAction          = s("FE31")
    val notification        = s("FE40")
    val notificationAction  = s("FE41")
    val musicNowPlaying     = s("FE50")
    val musicCommand        = s("FE51")
    val linkControl         = s("FE60")

    val all = listOf(
        deviceInfo, healthStream, healthControl,
        callEvent, callAction, notification, notificationAction,
        musicNowPlaying, musicCommand, linkControl,
    )
}