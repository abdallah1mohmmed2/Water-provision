package com.saqia.saqia_station

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import kotlin.math.abs

class FloatingBubbleService : Service() {
    private lateinit var manager: WindowManager
    private var bubble: View? = null

    override fun onCreate() {
        super.onCreate()
        manager = getSystemService(WINDOW_SERVICE) as WindowManager
        makeNotificationChannel()
        startForeground(7321, notification())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            stopSelf()
            return
        }
        addBubble()
    }

    // Keep the user-enabled bubble alive when the app task is dismissed.
    // Android may still stop it under force-stop or system restrictions.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    private fun makeNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("saqia_floating_bubble", "فقاعة ساقية", NotificationManager.IMPORTANCE_LOW)
            channel.description = "إشعار أثناء تشغيل الفقاعة العائمة"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun notification(): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        return NotificationCompat.Builder(this, "saqia_floating_bubble")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("فقاعة ساقية مفعّلة")
            .setContentText("اضغط لفتح ساقية. لإيقافها، استخدم المفتاح في إعدادات التطبيق.")
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()

    private fun addBubble() {
        val view = TextView(this).apply {
            text = "س"
            textSize = 19f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            contentDescription = "فتح تطبيق ساقية"
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(39, 105, 84))
                setStroke(dp(2), Color.WHITE)
            }
            elevation = dp(5).toFloat()
        }
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val p = WindowManager.LayoutParams(
            dp(48), dp(48), type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(12)
            y = dp(180)
        }
        var downX = 0f
        var downY = 0f
        var originX = 0
        var originY = 0
        var dragged = false
        view.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY
                    originX = p.x; originY = p.y
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - downX).toInt()
                    val dy = (e.rawY - downY).toInt()
                    if (abs(dx) > dp(5) || abs(dy) > dp(5)) dragged = true
                    p.x = originX + dx; p.y = originY + dy
                    try { manager.updateViewLayout(v, p) } catch (_: Exception) {}
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) {
                        startActivity(Intent(this, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        })
                    }
                    true
                }
                else -> false
            }
        }
        try {
            manager.addView(view, p)
            bubble = view
            isRunning = true
        } catch (_: Exception) {
            isRunning = false
            stopSelf()
        }
    }

    override fun onDestroy() {
        bubble?.let { try { manager.removeView(it) } catch (_: Exception) {} }
        bubble = null
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object { @Volatile var isRunning: Boolean = false }
}
