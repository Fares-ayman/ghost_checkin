package com.example.attendance_demo_app

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager

/** Small helpers that answer "is X allowed / turned on right now?". */
object Perms {
    private fun granted(c: Context, permission: String): Boolean =
        c.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun fineLocation(c: Context): Boolean =
        granted(c, Manifest.permission.ACCESS_FINE_LOCATION)

    fun backgroundLocation(c: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 29) {
            granted(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else {
            fineLocation(c)
        }

    fun activityRecognition(c: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 29) {
            granted(c, Manifest.permission.ACTIVITY_RECOGNITION)
        } else {
            true
        }

    fun notifications(c: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            !granted(c, Manifest.permission.POST_NOTIFICATIONS)
        ) {
            return false
        }
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.areNotificationsEnabled()
    }

    fun locationEnabled(c: Context): Boolean {
        val lm = c.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= 28) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    fun batteryUnrestricted(c: Context): Boolean {
        val pm = c.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(c.packageName)
    }
}
