package com.example.attendance_demo_app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

/**
 * Subscribes to motion changes (in a vehicle, walking, still). Motion never
 * records attendance on its own: it only supports what the geofence reports.
 */
object ActivityMonitor {
    private const val REQ_ACTIVITY = 301

    private val watched = listOf(
        DetectedActivity.IN_VEHICLE,
        DetectedActivity.ON_BICYCLE,
        DetectedActivity.WALKING,
        DetectedActivity.RUNNING,
        DetectedActivity.STILL,
    )

    fun label(activityType: Int): String = when (activityType) {
        DetectedActivity.IN_VEHICLE -> "in_vehicle"
        DetectedActivity.ON_BICYCLE -> "on_bicycle"
        DetectedActivity.WALKING -> "walking"
        DetectedActivity.RUNNING -> "running"
        DetectedActivity.STILL -> "still"
        else -> "unknown"
    }

    private fun pendingIntent(c: Context): PendingIntent {
        val flags = if (Build.VERSION.SDK_INT >= 31) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(
            c,
            REQ_ACTIVITY,
            Intent(c, ActivityTransitionReceiver::class.java),
            flags,
        )
    }

    @SuppressLint("MissingPermission")
    fun start(c: Context) {
        if (!Perms.activityRecognition(c)) return

        val transitions = ArrayList<ActivityTransition>()
        for (type in watched) {
            transitions.add(
                ActivityTransition.Builder()
                    .setActivityType(type)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                    .build(),
            )
            transitions.add(
                ActivityTransition.Builder()
                    .setActivityType(type)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                    .build(),
            )
        }

        try {
            ActivityRecognition.getClient(c)
                .requestActivityTransitionUpdates(
                    ActivityTransitionRequest(transitions),
                    pendingIntent(c),
                )
        } catch (e: Exception) {
            // Motion is optional. Attendance still works without it.
        }
    }
}

class ActivityTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        val c = context.applicationContext

        val nowWall = System.currentTimeMillis()
        val nowElapsedNanos = SystemClock.elapsedRealtimeNanos()

        for (event in result.transitionEvents) {
            val ageMs = (nowElapsedNanos - event.elapsedRealTimeNanos) / 1_000_000L
            val transition = if (event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER) {
                "enter"
            } else {
                "exit"
            }
            val type = ActivityMonitor.label(event.activityType)
            val ts = nowWall - ageMs
            AttendanceStore.addActivity(c, type, transition, ts)
            if (type == "still" && transition == "enter") {
                AttendanceEngine.maybeNudgeArrival(c, ts)
            }
        }
    }
}
