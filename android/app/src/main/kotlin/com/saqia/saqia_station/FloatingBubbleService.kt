package com.saqia.saqia_station

import android.app.Service
import android.content.Intent
import android.os.IBinder

class FloatingBubbleService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder? = null
}
