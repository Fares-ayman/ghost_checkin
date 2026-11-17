package com.example.attendance_demo_app

import android.content.Context
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Turns raw "entered / left the office area" signals into confirmed events.
 *
 * A signal first becomes a pending event. It is confirmed only if the phone
 * stays on the same side of the boundary for the confirmation window
 * (5 minutes by default). If the opposite signal arrives first, the pending
 * event is discarded: that is someone passing by, or a GPS wobble.
 *
 * The recorded time is always the time of the original signal, never the time
 * of the confirmation.
 */
object AttendanceEngine {
    const val SOURCE_GEOFENCE = "geofence"
    const val SOURCE_INITIAL = "initial"
    const val SOURCE_MANUAL = "manual"

    /** An exit nobody detected, placed at the time motion says the person left. */
    const val SOURCE_MOTION = "motion"

    private const val DAY_MS = 24 * 60 * 60 * 1000L

    private const val RECENT_BOOT_MS = 15 * 60 * 1000L
    private const val RECENT_STOP_MS = 10 * 60 * 1000L
    private const val MIN_STILL_GAIN_MS = 5 * 60 * 1000L

    private fun formatTime(ts: Long): String =
        SimpleDateFormat("HH:mm", Locale.US).format(Date(ts))

    @Synchronized
    fun onTransition(context: Context, type: String, source: String) {
        val c = context.applicationContext
        reconcile(c)
        rolloverDay(c)

        val now = System.currentTimeMillis()
        val manual = source == SOURCE_MANUAL
        val pending = AttendanceStore.pendingEvent(c)

        if (pending != null) {
            if (pending.optString("type") == type) {
                // Same signal again. A manual action confirms it right away.
                if (manual) confirmPending(c, pending.optString("id"))
                return
            }
            val reason = if (type == AttendanceStore.TYPE_EXIT) {
                "Left again before the confirmation window ended (passing by)."
            } else {
                "Came back before the confirmation window ended (brief exit ignored)."
            }
            AttendanceStore.updateEvent(c, pending.optString("id")) {
                it.put("status", AttendanceStore.STATUS_DISCARDED)
                it.put("note", joinNotes(it.optString("note"), reason))
            }
            AttendanceStore.setPendingId(c, null)
            AttendanceAlarms.cancelConfirm(c)
            return
        }

        val resulting = if (type == AttendanceStore.TYPE_ENTER) {
            AttendanceStore.PRESENCE_INSIDE
        } else {
            AttendanceStore.PRESENCE_OUTSIDE
        }
        if (resulting == AttendanceStore.presence(c)) return

        val id = UUID.randomUUID().toString()
        val motion = AttendanceStore.currentActivity(c)
        val motionTs = AttendanceStore.currentActivityTs(c)
        val notes = ArrayList<String>()

        val event = JSONObject()
            .put("id", id)
            .put("type", type)
            .put("ts", now)
            .put("source", source)
            .put("status", AttendanceStore.STATUS_PENDING)
            .put("synced", false)
        if (motion != null) event.put("motion", motion)

        if (manual) notes.add("Recorded manually.")

        if (source == SOURCE_INITIAL && type == AttendanceStore.TYPE_ENTER) {
            notes.add("Detected when monitoring (re)started, so the real arrival may be earlier.")
            val boot = AttendanceStore.bootTime(c)
            if (boot > 0 && now - boot < RECENT_BOOT_MS) {
                notes.add("Phone was switched on at ${formatTime(boot)}.")
            }
            // The phone was found inside the office. If it has not moved since
            // it last stopped, it has been in the office since then: that is a
            // time we can record. Anything earlier stays a suggestion for the
            // manager, because motion cannot say where the phone was.
            val sessionStart = maxOf(AttendanceStore.startOfToday(), AttendanceStore.lastConfirmedTs(c))
            val still = AttendanceStore.stillSince(c, sessionStart, now)
            var recorded = now
            if (still != null && now - still >= MIN_STILL_GAIN_MS) {
                recorded = still
                event.put("ts", still)
                event.put("detectedTs", now)
                notes.add(
                    "Found inside at ${formatTime(now)}. The phone had not moved since " +
                        "${formatTime(still)}, so the check-in is set to ${formatTime(still)}.",
                )
            }
            val vehicleExit = AttendanceStore.lastVehicleExitToday(c, recorded)
            if (vehicleExit != null && vehicleExit > sessionStart &&
                recorded - vehicleExit >= MIN_STILL_GAIN_MS
            ) {
                event.put("estimatedTs", vehicleExit)
                notes.add("Motion history suggests arrival around ${formatTime(vehicleExit)}.")
            }
        }

        if (source == SOURCE_INITIAL && type == AttendanceStore.TYPE_EXIT) {
            // Found outside when monitoring restarted (Location was turned back
            // on, for example). The person left some time before now.
            notes.add("Detected when monitoring (re)started, so the real departure may be earlier.")
            val sessionStart = AttendanceStore.lastConfirmedTs(c)
            val vehicleEnter = AttendanceStore.lastVehicleEnterBetween(c, sessionStart, now)
            if (vehicleEnter != null) {
                event.put("estimatedTs", vehicleEnter)
                notes.add("Motion history suggests leaving around ${formatTime(vehicleEnter)}.")
            }
        }

        val fastConfirm = type == AttendanceStore.TYPE_ENTER &&
            source == SOURCE_GEOFENCE &&
            AttendanceStore.motionFastConfirm(c) &&
            isOnFootOrJustStopped(motion, motionTs, now)
        if (fastConfirm) {
            notes.add("Confirmed immediately: motion sensor reports ${motion ?: "on foot"}.")
        }

        // The wait always runs from when the signal arrived, even when the
        // recorded time is earlier.
        val confirmAt = now + AttendanceStore.confirmSeconds(c) * 1000L
        event.put("confirmAfter", confirmAt)
        event.put("note", notes.joinToString(" "))
        AttendanceStore.addEvent(c, event)
        AttendanceStore.setPendingId(c, id)

        if (manual || fastConfirm) {
            confirmPending(c, id)
        } else {
            AttendanceAlarms.scheduleConfirm(c, id, confirmAt)
        }
    }

    /** Walking or running, or stopped moving only a few minutes ago. */
    private fun isOnFootOrJustStopped(motion: String?, motionTs: Long, now: Long): Boolean =
        when (motion) {
            "walking", "running" -> true
            "still" -> now - motionTs <= RECENT_STOP_MS
            else -> false
        }

    private fun joinNotes(existing: String, extra: String): String =
        if (existing.isBlank()) extra else "$existing $extra"

    @Synchronized
    fun confirmPending(context: Context, id: String?) {
        val c = context.applicationContext
        val pending = AttendanceStore.pendingEvent(c) ?: return
        val pendingId = pending.optString("id")
        if (id != null && id != pendingId) return

        val type = pending.optString("type")
        val ts = pending.optLong("ts")
        AttendanceStore.updateEvent(c, pendingId) {
            it.put("status", AttendanceStore.STATUS_CONFIRMED)
            it.put("confirmedAt", System.currentTimeMillis())
        }
        AttendanceStore.setPendingId(c, null)
        AttendanceAlarms.cancelConfirm(c)

        if (type == AttendanceStore.TYPE_ENTER) {
            AttendanceStore.setPresence(c, AttendanceStore.PRESENCE_INSIDE)
            val estimated = pending.optLong("estimatedTs", 0L)
            if (estimated > 0L && ts - estimated >= 5 * 60 * 1000L) {
                Notifier.event(
                    c,
                    "Entered the office",
                    "Recorded at ${formatTime(ts)}. Motion suggests you arrived around " +
                        "${formatTime(estimated)}. Open the app to send the real time to your manager.",
                )
            } else {
                Notifier.event(c, "Entered the office", "Recorded at ${formatTime(ts)}.")
            }
        } else {
            AttendanceStore.setPresence(c, AttendanceStore.PRESENCE_OUTSIDE)
            Notifier.event(
                c,
                "Left the office",
                "Recorded at ${formatTime(ts)}. Counts as a break if you return within " +
                    "${AttendanceStore.breakMinutes(c)} minutes.",
            )
        }
    }

    /** Confirms a pending event whose window has passed (missed alarm, reboot). */
    @Synchronized
    fun reconcile(context: Context) {
        val c = context.applicationContext
        val pending = AttendanceStore.pendingEvent(c) ?: return
        val due = AttendanceStore.confirmDue(c, pending)
        if (System.currentTimeMillis() >= due) {
            confirmPending(c, pending.optString("id"))
        }
    }

    /**
     * Location is off, so nothing can record the arrival. When motion shows
     * the shape of an arrival (out of a vehicle, a walk, then still) on a work
     * day with no check-in yet, nudge once to turn Location on.
     */
    @Synchronized
    fun maybeNudgeArrival(context: Context, stillTs: Long) {
        val c = context.applicationContext
        if (!AttendanceStore.arrivalNudge(c)) return
        if (Perms.locationEnabled(c)) return
        if (!AttendanceStore.isWorkday(c)) return
        if (AttendanceStore.nudgedToday(c)) return
        if (AttendanceStore.hasConfirmedEnterToday(c) || AttendanceStore.pendingEvent(c) != null) return

        val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        if (hour < NUDGE_FROM_HOUR || hour >= NUDGE_UNTIL_HOUR) return

        val vehicleExit = AttendanceStore.lastVehicleExitToday(c, stillTs) ?: return
        if (stillTs - vehicleExit > NUDGE_WINDOW_MS) return
        val walked = AttendanceStore.activityStartedBetween(
            c, setOf("walking", "running"), vehicleExit, stillTs,
        )
        if (!walked) return

        AttendanceStore.markNudgedToday(c)
        Notifier.arrivalNudge(c)
        AttendanceAlarms.startLocationWatch(c)
    }

    private const val NUDGE_WINDOW_MS = 30 * 60 * 1000L
    private const val NUDGE_FROM_HOUR = 6
    private const val NUDGE_UNTIL_HOUR = 16

    /**
     * A new day starts outside. Without this, someone whose exit was never
     * recorded (Location off, no manual check-out) would still count as
     * "inside" the next morning, and that day's entry would be ignored.
     *
     * The missed exit is filled in from motion when possible: the last time
     * that day the phone got into a vehicle after the check-in. It is stored
     * as an estimate and can be corrected. With no motion evidence the day
     * stays without an exit, flagged for review.
     *
     * Returns true when the state was reset.
     */
    @Synchronized
    fun rolloverDay(context: Context): Boolean {
        val c = context.applicationContext
        if (AttendanceStore.presence(c) != AttendanceStore.PRESENCE_INSIDE) return false
        if (AttendanceStore.pendingEvent(c) != null) return false
        val last = AttendanceStore.lastConfirmedTs(c)
        if (last == 0L || last >= AttendanceStore.startOfToday()) return false

        val endOfThatDay = AttendanceStore.startOfDay(last) + DAY_MS - 1
        val left = AttendanceStore.lastVehicleEnterBetween(c, last, endOfThatDay)
        if (left != null) {
            AttendanceStore.addEvent(
                c,
                JSONObject()
                    .put("id", UUID.randomUUID().toString())
                    .put("type", AttendanceStore.TYPE_EXIT)
                    .put("ts", left)
                    .put("source", SOURCE_MOTION)
                    .put("status", AttendanceStore.STATUS_CONFIRMED)
                    .put("confirmedAt", System.currentTimeMillis())
                    .put("motion", "in_vehicle")
                    .put("synced", false)
                    .put(
                        "note",
                        "No exit was detected that day. Estimated from motion: got into a " +
                            "vehicle at ${formatTime(left)}.",
                    ),
            )
        }
        AttendanceStore.setPresence(c, AttendanceStore.PRESENCE_OUTSIDE)
        return true
    }

    /**
     * Makes sure everything that runs in the background is registered:
     * geofence, motion updates, the reminder and the health check.
     * Safe to call often.
     */
    fun ensureMonitoring(context: Context, force: Boolean) {
        val c = context.applicationContext
        reconcile(c)
        // After a reset the geofence is registered again, so its initial
        // trigger reports whether the phone is at the office right now.
        val newDay = rolloverDay(c)

        val pending = AttendanceStore.pendingEvent(c)
        if (pending != null) {
            AttendanceAlarms.scheduleConfirm(c, pending.optString("id"), AttendanceStore.confirmDue(c, pending))
        }

        AttendanceAlarms.scheduleReminder(c)
        AttendanceAlarms.scheduleHealthCheck(c)
        AttendanceAlarms.scheduleDayEnd(c)
        ActivityMonitor.start(c)

        GeofenceManager.refreshStatus(c)
        if (force || newDay || !AttendanceStore.geofenceActive(c)) {
            GeofenceManager.register(c)
        }
    }
}
