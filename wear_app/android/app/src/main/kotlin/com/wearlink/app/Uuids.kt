package com.wearlink.app

import java.util.UUID

/// UUIDs mirror protocol/GATT.md + ios_app BluetoothUUIDs.swift.
/// 16-bit short handles expanded over a random 128-bit base to avoid
/// collision with Bluetooth SIG-assigned UUIDs.
/// Base: 96812f26-7d24-4287-98cc-736bc4d49a61
object Uuids {
    private fun s(h: String) =
        UUID.fromString("${h}2f26-7d24-4287-98cc-736bc4d49a61")

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
