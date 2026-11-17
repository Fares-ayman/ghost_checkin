package com.example.attendance_demo_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build

object Notifier {
    private const val CHANNEL_EVENTS = "attendance_events"
    private const val CHANNEL_REMINDER = "attendance_reminder"
    private const val ID_EVENT = 2001
    private const val ID_REMINDER = 2002
    private const val ID_NUDGE = 2003

    private fun manager(c: Context): NotificationManager =
        c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannels(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = manager(c)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_EVENTS,
                "Attendance events",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_REMINDER,
                "Check-in reminder",
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
    }

    private fun show(
        c: Context,
        id: Int,
        channel: String,
        title: String,
        text: String,
        tapIntent: android.content.Intent? = null,
    ) {
        if (!Perms.notifications(c)) return
        ensureChannels(c)

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(c, channel)
        } else {
            Notification.Builder(c)
        }
        builder
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)

        val launch = tapIntent ?: c.packageManager.getLaunchIntentForPackage(c.packageName)
        if (launch != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    c,
                    0,
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        manager(c).notify(id, builder.build())
    }

    /** Shown when an entry or exit is confirmed. Can be turned off in settings. */
    fun event(c: Context, title: String, text: String) {
        if (!AttendanceStore.eventNotifications(c)) return
        show(c, ID_EVENT, CHANNEL_EVENTS, title, text)
    }

    /** The daily reminder for anyone who has not checked in. */
    fun reminder(c: Context) {
        val text = if (Perms.locationEnabled(c)) {
            "You have not checked in today. If you are at the office, open the app and " +
                "check in manually."
        } else {
            "You have not checked in today. Turn on Location for automatic check-in, or " +
                "check in manually from the app."
        }
        show(c, ID_REMINDER, CHANNEL_REMINDER, "Check-in reminder", text)
    }

    /** Location is off and motion shows the person just arrived somewhere. */
    fun arrivalNudge(c: Context) {
        val settings = android.content.Intent(android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        show(
            c,
            ID_NUDGE,
            CHANNEL_REMINDER,
            "Looks like you just arrived",
            "Turn on Location and your check-in is recorded for you. No need to open the app.",
            settings,
        )
    }
}
