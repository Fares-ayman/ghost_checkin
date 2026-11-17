package com.example.attendance_demo_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * Local storage for everything the background code needs. It lives on the
 * native side because geofence events arrive while the Flutter engine is not
 * running. Events are kept as a JSON array, which is also the payload that
 * would be posted to the attendance API.
 */
object AttendanceStore {
    const val TYPE_ENTER = "ENTER"
    const val TYPE_EXIT = "EXIT"

    const val STATUS_PENDING = "pending"
    const val STATUS_CONFIRMED = "confirmed"
    const val STATUS_DISCARDED = "discarded"

    const val PRESENCE_INSIDE = "inside"
    const val PRESENCE_OUTSIDE = "outside"

    private const val PREFS = "attendance_store"
    private const val MAX_EVENTS = 500
    private const val MAX_ACTIVITY = 600

    private fun prefs(c: Context): SharedPreferences =
        c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Settings -------------------------------------------------------

    fun confirmSeconds(c: Context): Int = prefs(c).getInt("confirm_seconds", 300)
    fun breakMinutes(c: Context): Int = prefs(c).getInt("break_minutes", 60)
    fun radiusMeters(c: Context): Int = prefs(c).getInt("radius_m", 150)
    fun reminderHour(c: Context): Int = prefs(c).getInt("reminder_hour", 12)
    fun reminderMinute(c: Context): Int = prefs(c).getInt("reminder_minute", 0)
    fun motionFastConfirm(c: Context): Boolean = prefs(c).getBoolean("motion_fast_confirm", true)
    fun eventNotifications(c: Context): Boolean = prefs(c).getBoolean("event_notifications", true)
    fun arrivalNudge(c: Context): Boolean = prefs(c).getBoolean("arrival_nudge", true)

    /** Work days as Calendar.DAY_OF_WEEK values (Sunday = 1). Default Sunday to Thursday. */
    fun workdays(c: Context): List<Int> =
        (prefs(c).getString("workdays", "1,2,3,4,5") ?: "1,2,3,4,5")
            .split(",").mapNotNull { it.trim().toIntOrNull() }.filter { it in 1..7 }

    fun isWorkday(c: Context, ts: Long = System.currentTimeMillis()): Boolean {
        val cal = Calendar.getInstance()
        cal.timeInMillis = ts
        return cal.get(Calendar.DAY_OF_WEEK) in workdays(c)
    }

    private fun todayKey(): String {
        val cal = Calendar.getInstance()
        return "${cal.get(Calendar.YEAR)}-${cal.get(Calendar.DAY_OF_YEAR)}"
    }

    fun nudgedToday(c: Context): Boolean = prefs(c).getString("nudge_day", null) == todayKey()

    fun markNudgedToday(c: Context) {
        prefs(c).edit().putString("nudge_day", todayKey()).commit()
    }

    fun updateSettings(
        c: Context,
        confirmSeconds: Int?,
        breakMinutes: Int?,
        radiusMeters: Int?,
        reminderHour: Int?,
        reminderMinute: Int?,
        motionFastConfirm: Boolean?,
        eventNotifications: Boolean?,
        arrivalNudge: Boolean?,
        workdays: List<Int>?,
    ) {
        val e = prefs(c).edit()
        if (confirmSeconds != null) e.putInt("confirm_seconds", confirmSeconds.coerceIn(5, 3600))
        if (breakMinutes != null) e.putInt("break_minutes", breakMinutes.coerceIn(1, 600))
        if (radiusMeters != null) e.putInt("radius_m", radiusMeters.coerceIn(50, 2000))
        if (reminderHour != null) e.putInt("reminder_hour", reminderHour.coerceIn(0, 23))
        if (reminderMinute != null) e.putInt("reminder_minute", reminderMinute.coerceIn(0, 59))
        if (motionFastConfirm != null) e.putBoolean("motion_fast_confirm", motionFastConfirm)
        if (eventNotifications != null) e.putBoolean("event_notifications", eventNotifications)
        if (arrivalNudge != null) e.putBoolean("arrival_nudge", arrivalNudge)
        if (workdays != null) {
            val days = workdays.filter { it in 1..7 }.distinct().sorted()
            if (days.isNotEmpty()) e.putString("workdays", days.joinToString(","))
        }
        e.commit()
    }

    // ---- Office location ------------------------------------------------

    /** Returns latitude/longitude, or null when the office is not set yet. */
    fun office(c: Context): Pair<Double, Double>? {
        val lat = prefs(c).getString("office_lat", null)?.toDoubleOrNull() ?: return null
        val lng = prefs(c).getString("office_lng", null)?.toDoubleOrNull() ?: return null
        return Pair(lat, lng)
    }

    fun setOffice(c: Context, lat: Double, lng: Double) {
        prefs(c).edit()
            .putString("office_lat", lat.toString())
            .putString("office_lng", lng.toString())
            .commit()
    }

    // ---- Geofence status ------------------------------------------------

    fun geofenceActive(c: Context): Boolean = prefs(c).getBoolean("geofence_active", false)
    fun geofenceError(c: Context): String? = prefs(c).getString("geofence_error", null)
    fun lastRegisterTs(c: Context): Long = prefs(c).getLong("last_register_ts", 0L)

    fun setGeofenceStatus(c: Context, active: Boolean, error: String?) {
        prefs(c).edit()
            .putBoolean("geofence_active", active)
            .putString("geofence_error", error)
            .commit()
    }

    fun setLastRegisterTs(c: Context, ts: Long) {
        prefs(c).edit().putLong("last_register_ts", ts).commit()
    }

    // ---- Presence -------------------------------------------------------

    fun presence(c: Context): String =
        prefs(c).getString("presence", PRESENCE_OUTSIDE) ?: PRESENCE_OUTSIDE

    fun setPresence(c: Context, presence: String) {
        prefs(c).edit().putString("presence", presence).commit()
    }

    fun bootTime(c: Context): Long = prefs(c).getLong("boot_ts", 0L)

    fun setBootTime(c: Context, ts: Long) {
        prefs(c).edit().putLong("boot_ts", ts).commit()
    }

    // ---- Events ---------------------------------------------------------

    fun allEvents(c: Context): JSONArray =
        try {
            JSONArray(prefs(c).getString("events", "[]") ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }

    private fun saveEvents(c: Context, events: JSONArray) {
        prefs(c).edit().putString("events", events.toString()).commit()
    }

    fun addEvent(c: Context, event: JSONObject) {
        val all = allEvents(c)
        all.put(event)
        if (all.length() <= MAX_EVENTS) {
            saveEvents(c, all)
            return
        }
        val trimmed = JSONArray()
        for (i in (all.length() - MAX_EVENTS) until all.length()) {
            trimmed.put(all.get(i))
        }
        saveEvents(c, trimmed)
    }

    fun findEvent(c: Context, id: String): JSONObject? {
        val all = allEvents(c)
        for (i in 0 until all.length()) {
            val e = all.optJSONObject(i) ?: continue
            if (e.optString("id") == id) return e
        }
        return null
    }

    fun updateEvent(c: Context, id: String, change: (JSONObject) -> Unit) {
        val all = allEvents(c)
        for (i in 0 until all.length()) {
            val e = all.optJSONObject(i) ?: continue
            if (e.optString("id") == id) {
                change(e)
                break
            }
        }
        saveEvents(c, all)
    }

    fun pendingId(c: Context): String? = prefs(c).getString("pending_id", null)

    fun setPendingId(c: Context, id: String?) {
        prefs(c).edit().putString("pending_id", id).commit()
    }

    /** The event that is waiting for its confirmation window, if any. */
    fun pendingEvent(c: Context): JSONObject? {
        val id = pendingId(c) ?: return null
        val event = findEvent(c, id)
        if (event == null || event.optString("status") != STATUS_PENDING) {
            setPendingId(c, null)
            return null
        }
        return event
    }

    fun startOfToday(): Long = startOfDay(System.currentTimeMillis())

    /** Midnight at the start of the day that contains [ts]. */
    fun startOfDay(ts: Long): Long {
        val cal = Calendar.getInstance()
        cal.timeInMillis = ts
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }

    /** Time of the most recent confirmed event, or 0 when there is none. */
    fun lastConfirmedTs(c: Context): Long {
        val all = allEvents(c)
        for (i in all.length() - 1 downTo 0) {
            val e = all.optJSONObject(i) ?: continue
            if (e.optString("status") == STATUS_CONFIRMED) return e.optLong("ts")
        }
        return 0L
    }

    fun hasConfirmedEnterToday(c: Context): Boolean {
        val start = startOfToday()
        val all = allEvents(c)
        for (i in 0 until all.length()) {
            val e = all.optJSONObject(i) ?: continue
            if (e.optString("type") == TYPE_ENTER &&
                e.optString("status") == STATUS_CONFIRMED &&
                e.optLong("ts") >= start
            ) {
                return true
            }
        }
        return false
    }

    // ---- Motion ---------------------------------------------------------

    fun activityLog(c: Context): JSONArray =
        try {
            JSONArray(prefs(c).getString("activity_log", "[]") ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }

    fun addActivity(c: Context, type: String, transition: String, ts: Long) {
        val all = activityLog(c)
        // Play services reports the current activity again every time the
        // updates are registered. Keep only real changes.
        val last = all.optJSONObject(all.length() - 1)
        if (last != null &&
            last.optString("type") == type &&
            last.optString("transition") == transition
        ) {
            return
        }
        all.put(JSONObject().put("type", type).put("transition", transition).put("ts", ts))
        val kept = if (all.length() <= MAX_ACTIVITY) {
            all
        } else {
            val trimmed = JSONArray()
            for (i in (all.length() - MAX_ACTIVITY) until all.length()) {
                trimmed.put(all.get(i))
            }
            trimmed
        }
        val e = prefs(c).edit().putString("activity_log", kept.toString())
        if (transition == "enter") {
            e.putString("current_activity", type).putLong("current_activity_ts", ts)
        }
        e.commit()
    }

    fun currentActivity(c: Context): String? = prefs(c).getString("current_activity", null)
    fun currentActivityTs(c: Context): Long = prefs(c).getLong("current_activity_ts", 0L)

    /** Last time today the phone stopped being in a vehicle, or null. */
    fun lastVehicleExitToday(c: Context, before: Long): Long? {
        val start = startOfToday()
        val all = activityLog(c)
        for (i in all.length() - 1 downTo 0) {
            val a = all.optJSONObject(i) ?: continue
            val ts = a.optLong("ts")
            if (ts < start) break
            if (ts <= before &&
                a.optString("type") == "in_vehicle" &&
                a.optString("transition") == "exit"
            ) {
                return ts
            }
        }
        return null
    }

    /**
     * Last time between [from] and [to] the phone started being in a vehicle,
     * or null. Used to estimate when someone left the office when no exit was
     * detected. Motion keeps being recorded while Location is off.
     */
    fun lastVehicleEnterBetween(c: Context, from: Long, to: Long): Long? {
        val all = activityLog(c)
        for (i in all.length() - 1 downTo 0) {
            val a = all.optJSONObject(i) ?: continue
            val ts = a.optLong("ts")
            if (ts < from) break
            if (ts <= to &&
                a.optString("type") == "in_vehicle" &&
                a.optString("transition") == "enter"
            ) {
                return ts
            }
        }
        return null
    }

    /**
     * When the phone last stopped moving, if it has not moved since: the
     * latest motion change is "still" and it started after [after]. Null when
     * the phone is moving, or there is no motion data.
     */
    fun stillSince(c: Context, after: Long, before: Long): Long? {
        val all = activityLog(c)
        for (i in all.length() - 1 downTo 0) {
            val a = all.optJSONObject(i) ?: continue
            if (a.optString("transition") != "enter") continue
            val ts = a.optLong("ts")
            if (ts > before) continue
            if (a.optString("type") != "still") return null
            return if (ts > after) ts else null
        }
        return null
    }

    /** When a pending event's confirmation window ends. */
    fun confirmDue(c: Context, event: JSONObject): Long =
        if (event.has("confirmAfter")) {
            event.optLong("confirmAfter")
        } else {
            event.optLong("ts") + confirmSeconds(c) * 1000L
        }

    /** True when one of [types] started between [from] and [to]. */
    fun activityStartedBetween(c: Context, types: Set<String>, from: Long, to: Long): Boolean {
        val all = activityLog(c)
        for (i in all.length() - 1 downTo 0) {
            val a = all.optJSONObject(i) ?: continue
            val ts = a.optLong("ts")
            if (ts < from) break
            if (ts <= to && a.optString("transition") == "enter" && a.optString("type") in types) {
                return true
            }
        }
        return false
    }

    /**
     * Today's check-in when motion suggests an earlier arrival and no
     * correction has been requested for it yet, else null.
     */
    fun arrivalSuggestion(c: Context): JSONObject? {
        val start = startOfToday()
        val all = allEvents(c)
        for (i in 0 until all.length()) {
            val e = all.optJSONObject(i) ?: continue
            if (e.optString("type") != TYPE_ENTER || e.optString("status") != STATUS_CONFIRMED) continue
            if (e.optLong("ts") < start) continue
            // Only the first check-in of the day.
            if (!e.has("estimatedTs")) return null
            val ts = e.optLong("ts")
            val estimated = e.optLong("estimatedTs")
            if (ts - estimated < SUGGEST_MIN_GAP_MS) return null
            if (hasCorrection(c, e.optString("id"))) return null
            return e
        }
        return null
    }

    private const val SUGGEST_MIN_GAP_MS = 5 * 60 * 1000L

    fun hasCorrection(c: Context, eventId: String): Boolean {
        val all = corrections(c)
        for (i in 0 until all.length()) {
            if (all.optJSONObject(i)?.optString("eventId") == eventId) return true
        }
        return false
    }

    // ---- Time corrections ----------------------------------------------

    fun corrections(c: Context): JSONArray =
        try {
            JSONArray(prefs(c).getString("corrections", "[]") ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }

    private fun saveCorrections(c: Context, corrections: JSONArray) {
        prefs(c).edit().putString("corrections", corrections.toString()).commit()
    }

    /** One request per event. A new request replaces the previous one. */
    fun requestCorrection(c: Context, eventId: String, requestedTs: Long, reason: String) {
        val kept = JSONArray()
        val all = corrections(c)
        for (i in 0 until all.length()) {
            val item = all.optJSONObject(i) ?: continue
            if (item.optString("eventId") != eventId) kept.put(item)
        }
        kept.put(
            JSONObject()
                .put("eventId", eventId)
                .put("requestedTs", requestedTs)
                .put("reason", reason)
                .put("status", "pending")
                .put("createdAt", System.currentTimeMillis()),
        )
        saveCorrections(c, kept)
    }

    /** In the demo the manager's decision is made on the same phone. */
    fun resolveCorrection(c: Context, eventId: String, approved: Boolean) {
        val all = corrections(c)
        for (i in 0 until all.length()) {
            val item = all.optJSONObject(i) ?: continue
            if (item.optString("eventId") == eventId) {
                item.put("status", if (approved) "approved" else "rejected")
                item.put("resolvedAt", System.currentTimeMillis())
            }
        }
        saveCorrections(c, all)
    }

    // ---- Reset ----------------------------------------------------------

    /** Clears events and motion history. Settings and the office are kept. */
    fun clearData(c: Context) {
        prefs(c).edit()
            .remove("events")
            .remove("corrections")
            .remove("activity_log")
            .remove("pending_id")
            .remove("current_activity")
            .remove("current_activity_ts")
            .putString("presence", PRESENCE_OUTSIDE)
            .commit()
    }
}
