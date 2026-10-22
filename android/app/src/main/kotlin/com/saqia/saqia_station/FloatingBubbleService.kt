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
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import kotlin.math.abs

class FloatingBubbleService : Service() {
    private lateinit var manager: WindowManager
    private var overlay: LinearLayout? = null
    private var menu: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var expanded = false

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
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

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
            .setContentText("اضغط على الفقاعة لعرض اختصارات العمليات.")
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()

    private fun rounded(color: Int, radius: Float = 16f): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radius.toInt()).toFloat()
        }

    private fun addBubble() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
            setPadding(0, 0, 0, 0)
        }

        val bubble = TextView(this).apply {
            text = "س"
            textSize = 19f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            contentDescription = "عرض اختصارات ساقية"
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(39, 105, 84))
                setStroke(dp(2), Color.WHITE)
            }
            elevation = dp(5).toFloat()
        }

        val actions = listOf(
            "سقاية جديدة" to "irrigation",
            "صرف وقبض" to "cash",
            "حجز دور" to "queue",
            "إضافة مستفيد" to "beneficiary",
            "إضافة مصروف" to "expense"
        )
        val actionMenu = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            background = rounded(Color.WHITE, 14f)
            elevation = dp(8).toFloat()
            setPadding(dp(7), dp(6), dp(7), dp(6))
        }
        actions.forEach { (label, action) ->
            val item = TextView(this).apply {
                text = label
                textSize = 14f
                gravity = Gravity.CENTER_VERTICAL
                setTextColor(Color.rgb(30, 41, 59))
                background = rounded(Color.rgb(241, 245, 249), 10f)
                setPadding(dp(12), 0, dp(12), 0)
                minHeight = dp(42)
                contentDescription = label
                isClickable = true
                isFocusable = true
                setOnClickListener { openAction(action) }
            }
            actionMenu.addView(item, LinearLayout.LayoutParams(dp(166), dp(42)).apply {
                bottomMargin = dp(4)
            })
        }
        root.addView(bubble, LinearLayout.LayoutParams(dp(48), dp(48)))
        root.addView(actionMenu, LinearLayout.LayoutParams(dp(180), LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(6)
        })

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val windowParams = WindowManager.LayoutParams(
            dp(48), dp(48), type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
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
        bubble.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX
                    downY = e.rawY
                    originX = windowParams.x
                    originY = windowParams.y
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - downX).toInt()
                    val dy = (e.rawY - downY).toInt()
                    if (abs(dx) > dp(5) || abs(dy) > dp(5)) dragged = true
                    windowParams.x = (originX + dx).coerceAtLeast(0)
                    windowParams.y = (originY + dy).coerceAtLeast(0)
                    try { manager.updateViewLayout(root, windowParams) } catch (_: Exception) {}
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) toggleMenu(root, actionMenu, windowParams)
                    true
                }
                else -> false
            }
        }
        try {
            manager.addView(root, windowParams)
            overlay = root
            menu = actionMenu
            params = windowParams
        } catch (_: Exception) {
            stopSelf()
        }
    }

    private fun toggleMenu(root: LinearLayout, actionMenu: LinearLayout, windowParams: WindowManager.LayoutParams) {
        expanded = !expanded
        actionMenu.visibility = if (expanded) View.VISIBLE else View.GONE
        windowParams.width = if (expanded) dp(180) else dp(48)
        windowParams.height = if (expanded) WindowManager.LayoutParams.WRAP_CONTENT else dp(48)
        try { manager.updateViewLayout(root, windowParams) } catch (_: Exception) {}
    }

    private fun openAction(action: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_QUICK_ACTION, action)
        }
        try { startActivity(intent) } catch (_: Exception) {}
    }

    override fun onDestroy() {
        overlay?.let { try { manager.removeView(it) } catch (_: Exception) {} }
        overlay = null
        menu = null
        params = null
        expanded = false
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object { @Volatile var isRunning: Boolean = false }
}
