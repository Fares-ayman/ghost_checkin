package com.example.attendance_demo_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Geofences, motion updates and alarms are all cleared when the phone
 * restarts (and when the app is updated), so they are registered again here.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val c = context.applicationContext
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> {
                val bootTime = System.currentTimeMillis() - SystemClock.elapsedRealtime()
                AttendanceStore.setBootTime(c, bootTime)
                AttendanceEngine.ensureMonitoring(c, true)
            }

            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                AttendanceEngine.ensureMonitoring(c, true)
            }
        }
    }
}
