package com.example.attendance_demo_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import java.util.Calendar

/** Schedules the alarms the app uses. */
object AttendanceAlarms {
    const val ACTION_CONFIRM = "com.example.attendance_demo_app.CONFIRM"
    const val ACTION_REMINDER = "com.example.attendance_demo_app.REMINDER"
    const val ACTION_HEALTH = "com.example.attendance_demo_app.HEALTH"
    const val ACTION_DAY_END = "com.example.attendance_demo_app.DAY_END"
    const val ACTION_LOCATION_WATCH = "com.example.attendance_demo_app.LOCATION_WATCH"
    const val EXTRA_EVENT_ID = "event_id"

    private const val REQ_CONFIRM = 101
    private const val REQ_REMINDER = 102
    private const val REQ_HEALTH = 103
    private const val REQ_DAY_END = 104
    private const val REQ_LOCATION_WATCH = 105
    private const val WATCH_EVERY_MS = 2 * 60 * 1000L
    private const val WATCH_FOR_MS = 20 * 60 * 1000L

    private fun alarmManager(c: Context): AlarmManager =
        c.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun pendingIntent(
        c: Context,
        action: String,
        requestCode: Int,
        eventId: String?,
    ): PendingIntent {
        val intent = Intent(c, AlarmReceiver::class.java).setAction(action)
        if (eventId != null) intent.putExtra(EXTRA_EVENT_ID, eventId)
        return PendingIntent.getBroadcast(
            c,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun canScheduleExact(c: Context): Boolean =
        Build.VERSION.SDK_INT < 31 || alarmManager(c).canScheduleExactAlarms()

    private fun setAlarm(c: Context, atMillis: Long, pi: PendingIntent) {
        val am = alarmManager(c)
        try {
            if (canScheduleExact(c)) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pi)
            }
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pi)
        }
    }

    /** Ends the confirmation window of a pending event. */
    fun scheduleConfirm(c: Context, eventId: String, atMillis: Long) {
        val at = maxOf(atMillis, System.currentTimeMillis() + 1000L)
        setAlarm(c, at, pendingIntent(c, ACTION_CONFIRM, REQ_CONFIRM, eventId))
    }

    fun cancelConfirm(c: Context) {
        alarmManager(c).cancel(pendingIntent(c, ACTION_CONFIRM, REQ_CONFIRM, null))
    }

    /** Next occurrence of the reminder time (12:00 by default). */
    fun scheduleReminder(c: Context) {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, AttendanceStore.reminderHour(c))
        cal.set(Calendar.MINUTE, AttendanceStore.reminderMinute(c))
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        setAlarm(c, cal.timeInMillis, pendingIntent(c, ACTION_REMINDER, REQ_REMINDER, null))
    }

    /**
     * Five past midnight, every day: closes the day that just ended. If no
     * exit was detected, this is when it is filled in from motion. It does not
     * depend on Location being on or on the app being opened.
     */
    fun scheduleDayEnd(c: Context) {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 5)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= System.currentTimeMillis()) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        setAlarm(c, cal.timeInMillis, pendingIntent(c, ACTION_DAY_END, REQ_DAY_END, null))
    }

    /**
     * Android does not tell a closed app that Location was switched on. After
     * a nudge or the reminder, check every two minutes for twenty minutes, so
     * the office circle is registered soon after the person turns it on.
     */
    fun startLocationWatch(c: Context) {
        val until = System.currentTimeMillis() + WATCH_FOR_MS
        c.getSharedPreferences("attendance_store", Context.MODE_PRIVATE)
            .edit().putLong("location_watch_until", until).commit()
        scheduleLocationWatch(c)
    }

    fun scheduleLocationWatch(c: Context) {
        setAlarm(
            c,
            System.currentTimeMillis() + WATCH_EVERY_MS,
            pendingIntent(c, ACTION_LOCATION_WATCH, REQ_LOCATION_WATCH, null),
        )
    }

    fun locationWatchActive(c: Context): Boolean =
        System.currentTimeMillis() < c.getSharedPreferences("attendance_store", Context.MODE_PRIVATE)
            .getLong("location_watch_until", 0L)

    /** Every half hour: re-register the geofence if it was dropped. */
    fun scheduleHealthCheck(c: Context) {
        alarmManager(c).setInexactRepeating(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + AlarmManager.INTERVAL_HALF_HOUR,
            AlarmManager.INTERVAL_HALF_HOUR,
            pendingIntent(c, ACTION_HEALTH, REQ_HEALTH, null),
        )
    }
}

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val c = context.applicationContext
        when (intent.action) {
            AttendanceAlarms.ACTION_CONFIRM -> {
                AttendanceEngine.confirmPending(
                    c,
                    intent.getStringExtra(AttendanceAlarms.EXTRA_EVENT_ID),
                )
            }

            AttendanceAlarms.ACTION_REMINDER -> {
                AttendanceEngine.ensureMonitoring(c, false)
                // Work days only. In the company app, also skip leave and
                // working-from-home days.
                if (AttendanceStore.isWorkday(c) &&
                    !AttendanceStore.hasConfirmedEnterToday(c) &&
                    AttendanceStore.pendingEvent(c) == null
                ) {
                    Notifier.reminder(c)
                    if (!Perms.locationEnabled(c)) AttendanceAlarms.startLocationWatch(c)
                }
                AttendanceAlarms.scheduleReminder(c)
            }

            AttendanceAlarms.ACTION_HEALTH -> {
                AttendanceEngine.ensureMonitoring(c, false)
            }

            AttendanceAlarms.ACTION_LOCATION_WATCH -> {
                if (Perms.locationEnabled(c)) {
                    // Registering finds the phone inside or outside right away.
                    AttendanceEngine.ensureMonitoring(c, true)
                } else if (AttendanceAlarms.locationWatchActive(c)) {
                    AttendanceAlarms.scheduleLocationWatch(c)
                }
            }

            AttendanceAlarms.ACTION_DAY_END -> {
                // ensureMonitoring closes yesterday and schedules the next run.
                AttendanceEngine.ensureMonitoring(c, false)
            }
        }
    }
}
