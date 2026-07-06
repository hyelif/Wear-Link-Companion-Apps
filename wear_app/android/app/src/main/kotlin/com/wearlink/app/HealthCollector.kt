package com.wearlink.app

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.MeasureClient
import androidx.health.services.client.PassiveListenerCallback
import androidx.health.services.client.PassiveMonitoringClient
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.IntervalDataPoint
import androidx.health.services.client.data.PassiveListenerConfig
import androidx.health.services.client.data.SampleDataPoint
import androidx.health.services.client.data.UserActivityState
import java.time.Duration
import java.time.Instant
import java.util.concurrent.Executors

/// Collects health data via Wear OS Health Services API.
///
/// Two modes:
///   - **Passive** (default): background HR, steps, calories, distance, sleep.
///   - **Active** (on-demand): high-rate HR capture when screen on / workout.
///
/// Batches samples and emits via `onBatch` callback. Flutter reads batches
/// through HealthServicesPlugin platform channel.
///
/// Data available in health-services-client 1.1.0-rc02:
///   heart_rate, steps, calories, distance, sleep (awake/asleep only)
/// NOT available: SpO2, HRV, sleep stages (see Software-Structure §9)
class HealthCollector(private val context: Context) {

    data class Sample(
        val type: String,       // "heart_rate" | "steps" | "calories" | "distance" | "sleep"
        val value: Double,
        val timestampMs: Long
    )

    var onBatch: ((List<Sample>) -> Unit)? = null

    private val executor = Executors.newSingleThreadExecutor()
    private var passiveClient: PassiveMonitoringClient? = null
    private var measureClient: MeasureClient? = null
    private val buffer = mutableListOf<Sample>()
    private var active = false

    // ---- Data types we monitor --------------------------------------------

    private val passiveTypes = setOf<DataType<*, *>>(
        DataType.HEART_RATE_BPM,
        DataType.STEPS,
        DataType.CALORIES,
        DataType.DISTANCE,
    )

    private val activeTypes = setOf(
        DataType.HEART_RATE_BPM,
    )

    // ---- Lifecycle --------------------------------------------------------

    fun start() {
        val client = HealthServices.getClient(context)
        passiveClient = client.passiveMonitoringClient
        measureClient = client.measureClient
        registerPassive()
    }

    fun stop() {
        unregisterPassive()
        stopActive()
        executor.shutdown()
    }

    // ---- Passive monitoring (background, low power) -----------------------

    private val passiveCallback = object : PassiveListenerCallback {
        override fun onNewDataPointsReceived(container: DataPointContainer) {
            val samples = mutableListOf<Sample>()
            val bootInstant = bootInstant()

            // Heart rate
            for (dp in container.getData(DataType.HEART_RATE_BPM)) {
                val sdp = dp as? SampleDataPoint<Double> ?: continue
                samples.add(Sample("heart_rate", sdp.value, sdp.getTimeInstant(bootInstant).toEpochMilli()))
            }

            // Steps
            for (dp in container.getData(DataType.STEPS)) {
                val idp = dp as? IntervalDataPoint<Long> ?: continue
                samples.add(Sample("steps", (idp.value ?: 0L).toDouble(), idp.getStartInstant(bootInstant).toEpochMilli()))
            }

            // Calories
            for (dp in container.getData(DataType.CALORIES)) {
                val idp = dp as? IntervalDataPoint<Double> ?: continue
                samples.add(Sample("calories", idp.value ?: 0.0, idp.getStartInstant(bootInstant).toEpochMilli()))
            }

            // Distance
            for (dp in container.getData(DataType.DISTANCE)) {
                val idp = dp as? IntervalDataPoint<Double> ?: continue
                samples.add(Sample("distance", idp.value ?: 0.0, idp.getStartInstant(bootInstant).toEpochMilli()))
            }

            if (samples.isNotEmpty()) flush(samples)
        }

        override fun onUserActivityInfoReceived(info: androidx.health.services.client.data.UserActivityInfo) {
            val state = info.userActivityState
            val isAsleep = state == UserActivityState.USER_ACTIVITY_ASLEEP
            val sample = Sample("sleep", if (isAsleep) 1.0 else 0.0, info.stateChangeTime.toEpochMilli())
            flush(listOf(sample))
        }
    }

    private fun registerPassive() {
        try {
            val config = PassiveListenerConfig.builder()
                .setDataTypes(passiveTypes)
                .setShouldUserActivityInfoBeRequested(true)
                .build()
            passiveClient?.setPassiveListenerCallback(config, executor, passiveCallback)
        } catch (e: Exception) {
            Log.e("HealthCollector", "passive register failed", e)
        }
    }

    private fun unregisterPassive() {
        try {
            passiveClient?.clearPassiveListenerCallbackAsync()
        } catch (_: Exception) {}
    }

    // ---- Active monitoring (on-demand, high rate) -------------------------

    private val measureCallback = object : MeasureCallback {
        override fun onAvailabilityChanged(type: DeltaDataType<*, *>, availability: androidx.health.services.client.data.Availability) {}
        override fun onDataReceived(container: DataPointContainer) {
            val samples = mutableListOf<Sample>()
            val bootInstant = bootInstant()

            for (dp in container.getData(DataType.HEART_RATE_BPM)) {
                val sdp = dp as? SampleDataPoint<Double> ?: continue
                samples.add(Sample("heart_rate", sdp.value, sdp.getTimeInstant(bootInstant).toEpochMilli()))
            }

            if (samples.isNotEmpty()) flush(samples)
        }
    }

    fun startActive() {
        if (active) return
        active = true
        try {
            measureClient?.registerMeasureCallback(DataType.HEART_RATE_BPM, executor, measureCallback)
        } catch (e: Exception) {
            Log.e("HealthCollector", "active register failed", e)
        }
    }

    fun stopActive() {
        if (!active) return
        active = false
        try {
            measureClient?.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, measureCallback)
        } catch (_: Exception) {}
    }

    // ---- Batching & flush -------------------------------------------------

    private val batchIntervalMs = 60_000L  // flush every 60 s
    private var lastFlushMs = System.currentTimeMillis()

    private fun flush(samples: List<Sample>) {
        buffer.addAll(samples)
        val now = System.currentTimeMillis()
        if (now - lastFlushMs >= batchIntervalMs || buffer.size >= 50) {
            val batch = buffer.toList()
            buffer.clear()
            lastFlushMs = now
            onBatch?.invoke(batch)
        }
    }

    // ---- Helpers ----------------------------------------------------------

    private fun bootInstant(): Instant =
        Instant.now().minus(Duration.ofMillis(SystemClock.elapsedRealtime()))
}
