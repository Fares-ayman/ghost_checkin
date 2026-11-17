package com.example.attendance_demo_app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

/**
 * Registers one circular geofence around the office with Google Play
 * services. The system then watches the boundary and wakes [GeofenceReceiver]
 * on entry and exit, even when the app is not running.
 */
object GeofenceManager {
    private const val GEOFENCE_ID = "office"
    private const val REQ_GEOFENCE = 201

    private fun pendingIntent(c: Context): PendingIntent {
        // Play services fills in the transition details, so the intent must be mutable.
        val flags = if (Build.VERSION.SDK_INT >= 31) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(
            c,
            REQ_GEOFENCE,
            Intent(c, GeofenceReceiver::class.java),
            flags,
        )
    }

    /** Why monitoring cannot run right now, or null when it can. */
    fun blocker(c: Context): String? = when {
        AttendanceStore.office(c) == null -> "Office location is not set."
        !Perms.fineLocation(c) -> "Precise location permission is missing."
        !Perms.backgroundLocation(c) -> "Location permission must be \"Allow all the time\"."
        !Perms.locationEnabled(c) -> "Location is turned off on this phone."
        else -> null
    }

    /** Marks the geofence as inactive when something it depends on was switched off. */
    fun refreshStatus(c: Context) {
        val reason = blocker(c)
        if (reason != null) {
            AttendanceStore.setGeofenceStatus(c, false, reason)
        }
    }

    @SuppressLint("MissingPermission")
    fun register(c: Context) {
        val reason = blocker(c)
        val office = AttendanceStore.office(c)
        if (reason != null || office == null) {
            AttendanceStore.setGeofenceStatus(c, false, reason)
            return
        }

        val geofence = Geofence.Builder()
            .setRequestId(GEOFENCE_ID)
            .setCircularRegion(
                office.first,
                office.second,
                AttendanceStore.radiusMeters(c).toFloat(),
            )
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(
                Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT,
            )
            .build()

        // The initial trigger reports where the phone is at registration time,
        // which covers "phone was switched on while already at the office".
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(
                GeofencingRequest.INITIAL_TRIGGER_ENTER or GeofencingRequest.INITIAL_TRIGGER_EXIT,
            )
            .addGeofence(geofence)
            .build()

        AttendanceStore.setLastRegisterTs(c, System.currentTimeMillis())
        try {
            LocationServices.getGeofencingClient(c)
                .addGeofences(request, pendingIntent(c))
                .addOnSuccessListener {
                    AttendanceStore.setGeofenceStatus(c, true, null)
                }
                .addOnFailureListener { e ->
                    AttendanceStore.setGeofenceStatus(
                        c,
                        false,
                        e.message ?: "Could not register the geofence.",
                    )
                }
        } catch (e: Exception) {
            AttendanceStore.setGeofenceStatus(c, false, e.message ?: "Could not register the geofence.")
        }
    }
}

class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val c = context.applicationContext
        val event = GeofencingEvent.fromIntent(intent) ?: return

        if (event.hasError()) {
            // Typically GEOFENCE_NOT_AVAILABLE: Location was turned off and the
            // system dropped the geofence. The health check registers it again.
            AttendanceStore.setGeofenceStatus(
                c,
                false,
                GeofenceStatusCodes.getStatusCodeString(event.errorCode),
            )
            return
        }

        val type = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> AttendanceStore.TYPE_ENTER
            Geofence.GEOFENCE_TRANSITION_EXIT -> AttendanceStore.TYPE_EXIT
            else -> return
        }

        // A transition right after registration is the initial trigger, not a
        // real crossing of the boundary.
        val sinceRegister = System.currentTimeMillis() - AttendanceStore.lastRegisterTs(c)
        val source = if (sinceRegister in 0..30_000L) {
            AttendanceEngine.SOURCE_INITIAL
        } else {
            AttendanceEngine.SOURCE_GEOFENCE
        }

        AttendanceEngine.onTransition(c, type, source)
    }
}
