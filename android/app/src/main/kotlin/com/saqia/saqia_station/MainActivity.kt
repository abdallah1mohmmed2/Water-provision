package com.saqia.saqia_station

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "saqia/device_settings"
    private val bubbleChannel = "saqia/floating_bubble"
    private var pendingQuickAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingQuickAction = intent?.getStringExtra(EXTRA_QUICK_ACTION)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bubbleChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this))
                "isBubbleRunning" -> result.success(FloatingBubbleService.isRunning)
                "consumePendingQuickAction" -> {
                    val action = pendingQuickAction
                    pendingQuickAction = null
                    result.success(action)
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    }
                    result.success(true)
                }
                "startBubble" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        result.error("OVERLAY_PERMISSION", "يجب السماح بالظهور فوق التطبيقات أولاً", null)
                    } else {
                        val serviceIntent = Intent(this, FloatingBubbleService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent) else startService(serviceIntent)
                        result.success(true)
                    }
                }
                "stopBubble" -> {
                    stopService(Intent(this, FloatingBubbleService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            if (call.method == "openNotificationSettings") {
                val settingsIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    }
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                }
                startActivity(settingsIntent)
                result.success(true)
            } else result.notImplemented()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_QUICK_ACTION)?.let { pendingQuickAction = it }
    }

    companion object {
        const val EXTRA_QUICK_ACTION = "saqia.quick_action"
    }
}
