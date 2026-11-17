package com.example.attendance_demo_app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Flutter UI talks to the native attendance code through one method
 * channel. All background work happens in the receivers, not here.
 */
class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AttendanceEngine.ensureMonitoring(applicationContext, true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val c = applicationContext
        when (call.method) {
            "getState" -> {
                AttendanceEngine.reconcile(c)
                AttendanceEngine.rolloverDay(c)
                GeofenceManager.refreshStatus(c)
                result.success(buildState())
            }

            "getEvents" -> result.success(AttendanceStore.allEvents(c).toString())

            "getActivityLog" -> result.success(AttendanceStore.activityLog(c).toString())

            "getCorrections" -> result.success(AttendanceStore.corrections(c).toString())

            "requestCorrection" -> {
                val eventId = call.argument<String>("eventId")
                val requestedTs = call.argument<Number>("requestedTs")?.toLong()
                if (eventId == null || requestedTs == null) {
                    result.error("bad_request", "eventId and requestedTs are required.", null)
                } else {
                    AttendanceStore.requestCorrection(
                        c,
                        eventId,
                        requestedTs,
                        call.argument<String>("reason") ?: "",
                    )
                    result.success(null)
                }
            }

            "resolveCorrection" -> {
                val eventId = call.argument<String>("eventId")
                if (eventId == null) {
                    result.error("bad_request", "eventId is required.", null)
                } else {
                    AttendanceStore.resolveCorrection(
                        c,
                        eventId,
                        call.argument<Boolean>("approved") == true,
                    )
                    result.success(null)
                }
            }

            "requestPermission" -> requestPermission(call.argument<String>("name") ?: "", result)

            "openAppSettings" -> {
                openSettings(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ),
                    null,
                )
                result.success(null)
            }

            "openLocationSettings" -> {
                openSettings(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS), null)
                result.success(null)
            }

            "requestBatteryExemption" -> {
                openSettings(
                    Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName"),
                    ),
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                )
                result.success(null)
            }

            "setOfficeHere" -> setOfficeHere(result)

            "updateSettings" -> {
                val oldRadius = AttendanceStore.radiusMeters(c)
                AttendanceStore.updateSettings(
                    c,
                    call.argument<Number>("confirmSeconds")?.toInt(),
                    call.argument<Number>("breakMinutes")?.toInt(),
                    call.argument<Number>("radiusMeters")?.toInt(),
                    call.argument<Number>("reminderHour")?.toInt(),
                    call.argument<Number>("reminderMinute")?.toInt(),
                    call.argument<Boolean>("motionFastConfirm"),
                    call.argument<Boolean>("eventNotifications"),
                    call.argument<Boolean>("arrivalNudge"),
                    call.argument<List<*>>("workdays")?.mapNotNull { (it as? Number)?.toInt() },
                )
                // A new radius needs a new geofence. The rest only needs alarms.
                val radiusChanged = oldRadius != AttendanceStore.radiusMeters(c)
                AttendanceEngine.ensureMonitoring(c, radiusChanged)
                result.success(buildState())
            }

            "manualTransition" -> {
                val type = if (call.argument<String>("type") == AttendanceStore.TYPE_EXIT) {
                    AttendanceStore.TYPE_EXIT
                } else {
                    AttendanceStore.TYPE_ENTER
                }
                AttendanceEngine.onTransition(c, type, AttendanceEngine.SOURCE_MANUAL)
                result.success(buildState())
            }

            "refreshMonitoring" -> {
                AttendanceEngine.ensureMonitoring(c, true)
                result.success(buildState())
            }

            "clearData" -> {
                AttendanceAlarms.cancelConfirm(c)
                AttendanceStore.clearData(c)
                AttendanceEngine.ensureMonitoring(c, true)
                result.success(buildState())
            }

            else -> result.notImplemented()
        }
    }

    // ---- State ----------------------------------------------------------

    private fun buildState(): HashMap<String, Any?> {
        val c = applicationContext

        val permissions = HashMap<String, Any?>()
        permissions["location"] = Perms.fineLocation(c)
        permissions["backgroundLocation"] = Perms.backgroundLocation(c)
        permissions["activity"] = Perms.activityRecognition(c)
        permissions["notifications"] = Perms.notifications(c)
        permissions["batteryUnrestricted"] = Perms.batteryUnrestricted(c)

        val settings = HashMap<String, Any?>()
        settings["confirmSeconds"] = AttendanceStore.confirmSeconds(c)
        settings["breakMinutes"] = AttendanceStore.breakMinutes(c)
        settings["radiusMeters"] = AttendanceStore.radiusMeters(c)
        settings["reminderHour"] = AttendanceStore.reminderHour(c)
        settings["reminderMinute"] = AttendanceStore.reminderMinute(c)
        settings["motionFastConfirm"] = AttendanceStore.motionFastConfirm(c)
        settings["eventNotifications"] = AttendanceStore.eventNotifications(c)
        settings["arrivalNudge"] = AttendanceStore.arrivalNudge(c)
        settings["workdays"] = AttendanceStore.workdays(c)

        val state = HashMap<String, Any?>()
        state["permissions"] = permissions
        state["settings"] = settings
        state["locationEnabled"] = Perms.locationEnabled(c)
        state["exactAlarms"] = AttendanceAlarms.canScheduleExact(c)
        state["geofenceActive"] = AttendanceStore.geofenceActive(c)
        state["geofenceError"] = AttendanceStore.geofenceError(c)
        state["presence"] = AttendanceStore.presence(c)
        state["androidSdk"] = Build.VERSION.SDK_INT

        val office = AttendanceStore.office(c)
        if (office != null) {
            val map = HashMap<String, Any?>()
            map["lat"] = office.first
            map["lng"] = office.second
            state["office"] = map
        }

        val pending = AttendanceStore.pendingEvent(c)
        if (pending != null) {
            val ts = pending.optLong("ts")
            val map = HashMap<String, Any?>()
            map["type"] = pending.optString("type")
            map["ts"] = ts
            map["confirmAt"] = AttendanceStore.confirmDue(c, pending)
            state["pending"] = map
        }

        val activity = AttendanceStore.currentActivity(c)
        if (activity != null) {
            val map = HashMap<String, Any?>()
            map["type"] = activity
            map["ts"] = AttendanceStore.currentActivityTs(c)
            state["motion"] = map
        }

        val suggestion = AttendanceStore.arrivalSuggestion(c)
        if (suggestion != null) {
            val map = HashMap<String, Any?>()
            map["eventId"] = suggestion.optString("id")
            map["ts"] = suggestion.optLong("ts")
            map["estimatedTs"] = suggestion.optLong("estimatedTs")
            state["suggestion"] = map
        }
        return state
    }

    // ---- Permissions ----------------------------------------------------

    private fun requestPermission(name: String, result: MethodChannel.Result) {
        val permissions: Array<String> = when (name) {
            "location" -> arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )

            "backgroundLocation" ->
                if (Build.VERSION.SDK_INT >= 29) {
                    arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                } else {
                    emptyArray()
                }

            "activity" ->
                if (Build.VERSION.SDK_INT >= 29) {
                    arrayOf(Manifest.permission.ACTIVITY_RECOGNITION)
                } else {
                    emptyArray()
                }

            "notifications" ->
                if (Build.VERSION.SDK_INT >= 33) {
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    emptyArray()
                }

            else -> emptyArray()
        }

        if (permissions.isEmpty()) {
            result.success(buildState())
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "Another permission request is still open.", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(permissions, REQ_PERMISSION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSION) return
        val result = pendingPermissionResult
        pendingPermissionResult = null
        AttendanceEngine.ensureMonitoring(applicationContext, true)
        result?.success(buildState())
    }

    private fun openSettings(primary: Intent, fallback: Intent?) {
        try {
            startActivity(primary)
        } catch (e: Exception) {
            if (fallback != null) {
                try {
                    startActivity(fallback)
                } catch (ignored: Exception) {
                    // No settings screen available on this device.
                }
            }
        }
    }

    // ---- Office location ------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun setOfficeHere(result: MethodChannel.Result) {
        val c = applicationContext
        if (!Perms.fineLocation(c)) {
            result.error("no_permission", "Location permission is missing.", null)
            return
        }
        if (!Perms.locationEnabled(c)) {
            result.error("location_off", "Location is turned off on this phone.", null)
            return
        }
        try {
            LocationServices.getFusedLocationProviderClient(this)
                .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, CancellationTokenSource().token)
                .addOnSuccessListener { location ->
                    if (location == null) {
                        result.error(
                            "no_location",
                            "Could not get a location fix. Try again near a window or outdoors.",
                            null,
                        )
                    } else {
                        AttendanceStore.setOffice(c, location.latitude, location.longitude)
                        AttendanceEngine.ensureMonitoring(c, true)
                        val state = buildState()
                        state["accuracy"] = location.accuracy.toDouble()
                        result.success(state)
                    }
                }
                .addOnFailureListener { e ->
                    result.error("location_failed", e.message ?: "Could not get the location.", null)
                }
        } catch (e: Exception) {
            result.error("location_failed", e.message ?: "Could not get the location.", null)
        }
    }

    companion object {
        private const val CHANNEL = "attendance/native"
        private const val REQ_PERMISSION = 4101
    }
}
