package com.ibextrails.ibex_trails

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val volume = alarmVolume ?: AlarmVolume(applicationContext).also {
            // The app may have been closed while an alarm had the volume up.
            it.restore()
            alarmVolume = it
        }
        // lib/services/alarm_audio.dart
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ibextrails/alarm_audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "boostAlarmVolume" -> {
                        volume.boost(
                            call.argument<String>("channel")!!,
                            call.argument<Number>("ms")!!.toLong(),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        // One per process: a recreated activity must not cut a boost short.
        var alarmVolume: AlarmVolume? = null
    }
}
