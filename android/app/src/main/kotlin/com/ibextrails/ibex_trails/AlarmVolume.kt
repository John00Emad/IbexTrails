package com.ibextrails.ibex_trails

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Turns the alarm volume up to the maximum while an alarm notification
 * plays (its channel plays the sound on the alarm stream), then puts it
 * back where the user had it.
 */
class AlarmVolume(context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val notifications =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // Saved to disk, so the volume still goes back if the app is closed
    // while it is up.
    private val saved = context.getSharedPreferences("alarm_volume", Context.MODE_PRIVATE)
    private val handler = Handler(Looper.getMainLooper())
    private val restoreLater = Runnable { restore() }

    /** Raises the alarm volume for [ms] milliseconds, if [channelId] plays a sound. */
    fun boost(channelId: String, ms: Long) {
        if (!playsSound(channelId)) return
        if (!saved.contains(KEY)) {
            saved.edit().putInt(KEY, audio.getStreamVolume(STREAM)).apply()
        }
        try {
            audio.setStreamVolume(STREAM, audio.getStreamMaxVolume(STREAM), 0)
        } catch (e: SecurityException) {
            // Do Not Disturb can forbid it. The alarm still plays, at the
            // user's own volume.
            Log.w(TAG, "Can't raise the alarm volume", e)
        }
        handler.removeCallbacks(restoreLater)
        handler.postDelayed(restoreLater, ms)
    }

    /** Puts the alarm volume back, unless the user changed it meanwhile. */
    fun restore() {
        val volume = saved.getInt(KEY, -1)
        if (volume < 0) return
        if (audio.getStreamVolume(STREAM) == audio.getStreamMaxVolume(STREAM)) {
            try {
                audio.setStreamVolume(STREAM, volume, 0)
            } catch (e: SecurityException) {
                Log.w(TAG, "Can't restore the alarm volume", e)
            }
        }
        saved.edit().remove(KEY).apply()
    }

    private fun playsSound(channelId: String): Boolean {
        // Before Android 8, notification sounds don't use the alarm stream.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!notifications.areNotificationsEnabled()) return false
        // No channel yet: it is created, with its sound, when first used.
        val channel = notifications.getNotificationChannel(channelId) ?: return true
        // The user may have made it silent in the phone's settings.
        return channel.importance >= NotificationManager.IMPORTANCE_DEFAULT &&
            channel.sound != null && channel.sound != Uri.EMPTY
    }

    private companion object {
        const val STREAM = AudioManager.STREAM_ALARM
        const val KEY = "volume"
        const val TAG = "AlarmVolume"
    }
}
