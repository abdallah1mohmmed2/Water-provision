package com.saqia.saqia_station

import android.app.Activity
import android.media.MediaPlayer
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.ContactsContract
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var irrigationTimeTts: android.speech.tts.TextToSpeech? = null
    private var pendingTimeVoiceResult: MethodChannel.Result? = null
    private var timeVoiceSequence = 0
    private var irrigationAudioPlayer: MediaPlayer? = null
    private val irrigationAudioQueue = mutableListOf<File>()
    private val irrigationAudioHandler = Handler(Looper.getMainLooper())
    private var irrigationAudioTrimRunnable: Runnable? = null

    // Measured audible-end positions (ms) in the original MP3s, after their long trailing silence.
    // Keep originals unchanged; trim silence at runtime to avoid awkward gaps between words.
    private val audibleEndMs = mapOf(
        "am" to 781, "and" to 386, "from" to 530, "to" to 416, "pm" to 843,
        "h_1" to 1273, "h_2" to 1221, "h_3" to 1268, "h_4" to 1206,
        "h_5" to 1299, "h_6" to 1322, "h_7" to 1225, "h_8" to 1225,
        "h_9" to 1250, "h_10" to 1258, "h_11" to 1711, "h_12" to 1683,
        "n_1" to 1258, "n_2" to 994, "n_3" to 1058, "n_4" to 935,
        "n_5" to 942, "n_6" to 949, "n_7" to 950, "n_8" to 1075,
        "n_9" to 917, "n_10" to 986, "n_11" to 1300, "n_12" to 1511,
        "n_13" to 1454, "n_14" to 1434, "n_15" to 571, "n_16" to 1378,
        "n_17" to 1381, "n_18" to 1523, "n_19" to 1381, "n_20" to 1162,
        "n_21" to 1731, "n_22" to 1635, "n_23" to 1670, "n_24" to 1572,
        "n_25" to 1608, "n_26" to 1607, "n_27" to 1591, "n_28" to 1679,
        "n_29" to 1578, "n_30" to 711, "n_31" to 1799, "n_32" to 1694,
        "n_33" to 1735, "n_34" to 1656, "n_35" to 1663, "n_36" to 1642,
        "n_37" to 1688, "n_38" to 1736, "n_39" to 1643, "n_40" to 1159,
        "n_41" to 1755, "n_42" to 1685, "n_43" to 1709, "n_44" to 1612,
        "n_45" to 1659, "n_46" to 1627, "n_47" to 1628, "n_48" to 1705,
        "n_49" to 1621, "n_50" to 1151, "n_51" to 1727, "n_52" to 1663,
        "n_53" to 1656, "n_54" to 1575, "n_55" to 1615, "n_56" to 1619,
        "n_57" to 1634, "n_58" to 1674, "n_59" to 1572
    )

    private fun cachedIrrigationAudio(): File {
        val cache = File(cacheDir, "irrigation_time_audio")
        val expected = 76
        if (cache.exists() && (cache.listFiles()?.count { it.extension == "mp3" } ?: 0) == expected) return cache
        cache.deleteRecursively()
        cache.mkdirs()
        ZipInputStream(assets.open("flutter_assets/assets/audio/irrigation_time/irrigation_audio.zip")).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                if (!entry.isDirectory && entry.name.endsWith(".mp3") && !entry.name.contains("..")) {
                    FileOutputStream(File(cache, File(entry.name).name)).use { output -> zip.copyTo(output) }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        if ((cache.listFiles()?.count { it.extension == "mp3" } ?: 0) != expected) {
            cache.deleteRecursively()
            throw IllegalStateException("Irrigation audio bundle incomplete")
        }
        return cache
    }

    private fun stopIrrigationAudio() {
        irrigationAudioTrimRunnable?.let { irrigationAudioHandler.removeCallbacks(it) }
        irrigationAudioTrimRunnable = null
        irrigationAudioQueue.clear()
        irrigationAudioPlayer?.let { player ->
            try { player.stop() } catch (_: Exception) { }
            player.release()
        }
        irrigationAudioPlayer = null
    }

    private fun playIrrigationClips(clips: List<String>, result: MethodChannel.Result) {
        val safeClip = Regex("^(from|to|and|am|pm|h_(1[0-2]|[1-9])|n_([1-9]|[1-5][0-9]))$")
        if (clips.isEmpty() || clips.any { !safeClip.matches(it) }) {
            result.success(false)
            return
        }
        try {
            val cache = cachedIrrigationAudio()
            stopIrrigationAudio()
            irrigationAudioQueue.addAll(clips.map { File(cache, "$it.mp3") })
            playNextIrrigationClip(result)
        } catch (_: Exception) {
            stopIrrigationAudio()
            result.success(false)
        }
    }

    private fun playNextIrrigationClip(initialResult: MethodChannel.Result? = null) {
        if (irrigationAudioQueue.isEmpty()) return
        val file = irrigationAudioQueue.removeAt(0)
        val player = MediaPlayer()
        irrigationAudioPlayer = player
        val clipId = file.nameWithoutExtension
        val startTrimMs = 70
        var initialResultSent = false
        fun replyInitial(value: Boolean) {
            if (!initialResultSent) {
                initialResultSent = true
                initialResult?.success(value)
            }
        }
        try {
            player.setDataSource(file.absolutePath)
            player.setOnPreparedListener { prepared ->
                try {
                    // Preserve full connectors, slow the overall spoken cadence slightly,
                    // and add a natural pause after "and" before the minute clip.
                    val speed = when (clipId) {
                        "from", "to", "and" -> 0.92f
                        else -> if (clipId.startsWith("h_") || clipId.startsWith("n_")) 1.0f else 1.0f
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        prepared.playbackParams = prepared.playbackParams.setSpeed(speed)
                    }
                    prepared.setOnSeekCompleteListener { seeked ->
                        try {
                            seeked.start()
                            replyInitial(true)
                            val audibleEnd = audibleEndMs[clipId] ?: (seeked.duration - 120)
                            val endSafetyMarginMs = if (clipId == "from" || clipId == "to" || clipId == "and") 20 else 35
                            val playbackMs = (((audibleEnd - startTrimMs - endSafetyMarginMs).coerceAtLeast(180)) / speed).toLong()
                            val trim = Runnable {
                                if (irrigationAudioPlayer === player) {
                                    try { player.stop() } catch (_: Exception) { }
                                    player.release()
                                    irrigationAudioPlayer = null
                                    val connectorPauseMs = if (clipId == "and") 140L else 0L
                                    if (connectorPauseMs > 0) {
                                        irrigationAudioHandler.postDelayed({ playNextIrrigationClip() }, connectorPauseMs)
                                    } else {
                                        playNextIrrigationClip()
                                    }
                                }
                            }
                            irrigationAudioTrimRunnable = trim
                            irrigationAudioHandler.postDelayed(trim, playbackMs)
                        } catch (_: Exception) {
                            replyInitial(false)
                            stopIrrigationAudio()
                        }
                    }
                    prepared.seekTo(startTrimMs)
                } catch (_: Exception) {
                    replyInitial(false)
                    stopIrrigationAudio()
                }
            }
            player.setOnCompletionListener {
                irrigationAudioTrimRunnable?.let { runnable -> irrigationAudioHandler.removeCallbacks(runnable) }
                irrigationAudioTrimRunnable = null
                it.release()
                if (irrigationAudioPlayer === it) irrigationAudioPlayer = null
                playNextIrrigationClip()
            }
            player.setOnErrorListener { failedPlayer, _, _ ->
                irrigationAudioTrimRunnable?.let { runnable -> irrigationAudioHandler.removeCallbacks(runnable) }
                irrigationAudioTrimRunnable = null
                failedPlayer.release()
                if (irrigationAudioPlayer === failedPlayer) irrigationAudioPlayer = null
                if (initialResult != null && !initialResultSent) {
                    stopIrrigationAudio()
                    replyInitial(false)
                } else playNextIrrigationClip()
                true
            }
            player.prepareAsync()
        } catch (_: Exception) {
            player.release()
            if (initialResult != null && !initialResultSent) {
                stopIrrigationAudio()
                replyInitial(false)
            } else playNextIrrigationClip()
        }
    }

    private fun announceIrrigationTime(text: String, result: MethodChannel.Result) {
        val current = irrigationTimeTts
        if (current != null) {
            speakIrrigationText(current, text, result)
            return
        }
        var created: android.speech.tts.TextToSpeech? = null
        created = android.speech.tts.TextToSpeech(this) { status ->
            val engine = created
            if (engine == null || status != android.speech.tts.TextToSpeech.SUCCESS) {
                result.success(false)
                return@TextToSpeech
            }
            irrigationTimeTts = engine
            val language = engine.setLanguage(java.util.Locale("ar"))
            if (language == android.speech.tts.TextToSpeech.LANG_MISSING_DATA ||
                language == android.speech.tts.TextToSpeech.LANG_NOT_SUPPORTED) {
                result.success(false)
                return@TextToSpeech
            }
            speakIrrigationText(engine, text, result)
        }
        irrigationTimeTts = created
    }

    private fun speakIrrigationText(
        engine: android.speech.tts.TextToSpeech,
        text: String,
        result: MethodChannel.Result,
    ) {
        val utteranceId = "saqia-time-${++timeVoiceSequence}"
        val status = engine.speak(text, android.speech.tts.TextToSpeech.QUEUE_ADD, null, utteranceId)
        result.success(status != android.speech.tts.TextToSpeech.ERROR)
    }

    override fun onDestroy() {
        pendingTimeVoiceResult?.success(false)
        pendingTimeVoiceResult = null
        stopIrrigationAudio()
        irrigationTimeTts?.stop()
        irrigationTimeTts?.shutdown()
        irrigationTimeTts = null
        super.onDestroy()
    }


    private val channel = "saqia/device_settings"
    private val bubbleChannel = "saqia/floating_bubble"
    private val contactsChannel = "saqia/contacts"
    private var pendingContactResult: MethodChannel.Result? = null
    private val contactPickerLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { selection ->
            val callback = pendingContactResult ?: return@registerForActivityResult
            pendingContactResult = null
            if (selection.resultCode != Activity.RESULT_OK) {
                callback.success(null)
                return@registerForActivityResult
            }
            val contactUri = selection.data?.data
            if (contactUri == null) {
                callback.error("NO_CONTACT", "لم يتم اختيار رقم هاتف", null)
                return@registerForActivityResult
            }
            try {
                // ACTION_PICK grants temporary access to the chosen phone row,
                // without broad READ_CONTACTS permission.
                val projection = arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER)
                val number = contentResolver.query(contactUri, projection, null, null, null)?.use { cursor ->
                    if (!cursor.moveToFirst()) null
                    else {
                        val index = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                        if (index < 0) null else cursor.getString(index)
                    }
                }
                if (number.isNullOrBlank()) {
                    callback.error("NO_PHONE", "جهة الاتصال المختارة لا تحتوي على رقم هاتف", null)
                } else {
                    callback.success(number)
                }
            } catch (exception: SecurityException) {
                callback.error("CONTACT_ACCESS_DENIED", "تعذر قراءة رقم جهة الاتصال المختارة", null)
            } catch (exception: Exception) {
                callback.error("CONTACT_PICK_FAILED", "تعذر جلب رقم الهاتف من جهات الاتصال", null)
            }
        }
    private var pendingQuickAction: String? = null
    private var bubbleMethodChannel: MethodChannel? = null
    private var activityResumed = false

    private fun notifyBubbleVisibility(foreground: Boolean) {
        sendBroadcast(Intent(FloatingBubbleService.ACTION_APP_VISIBILITY).apply {
            setPackage(packageName)
            putExtra(FloatingBubbleService.EXTRA_APP_FOREGROUND, foreground)
        })
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
        notifyBubbleVisibility(true)
    }

    override fun onPause() {
        activityResumed = false
        notifyBubbleVisibility(false)
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saqia/message_composer")
            .setMethodCallHandler { call, result ->
                if (call.method != "composeSms") {
                    result.notImplemented()
                } else {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    if (phone == null || !phone.matches(Regex("[0-9]{8,15}")) || message == null) {
                        result.error("INVALID_MESSAGE", "تعذر تجهيز رقم الهاتف ونص الرسالة", null)
                    } else {
                        try {
                            // ACTION_SENDTO opens a composer; the user still presses Send.
                            startActivity(Intent(Intent.ACTION_SENDTO, Uri.fromParts("smsto", phone, null)).apply {
                                putExtra("sms_body", message)
                            })
                            result.success(true)
                        } catch (exception: ActivityNotFoundException) {
                            result.success(false)
                        } catch (exception: SecurityException) {
                            result.success(false)
                        }
                    }
                }
            }
        pendingQuickAction = intent?.getStringExtra(EXTRA_QUICK_ACTION)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, contactsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "pickPhoneNumber") {
                    result.notImplemented()
                } else if (pendingContactResult != null) {
                    result.error("PICK_IN_PROGRESS", "يتم اختيار رقم هاتف بالفعل", null)
                } else {
                    pendingContactResult = result
                    try {
                        val pickIntent = Intent(Intent.ACTION_PICK).apply {
                            type = ContactsContract.CommonDataKinds.Phone.CONTENT_TYPE
                        }
                        contactPickerLauncher.launch(pickIntent)
                    } catch (exception: ActivityNotFoundException) {
                        pendingContactResult = null
                        result.error("NO_CONTACTS_APP", "لا يوجد تطبيق جهات اتصال يدعم اختيار الأرقام", null)
                    } catch (exception: Exception) {
                        pendingContactResult = null
                        result.error("CONTACT_PICK_FAILED", "تعذر فتح جهات الاتصال", null)
                    }
                }
            }
        bubbleMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bubbleChannel)
        bubbleMethodChannel?.setMethodCallHandler { call, result ->
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
                        val serviceIntent = Intent(this, FloatingBubbleService::class.java).apply {
                            putExtra(FloatingBubbleService.EXTRA_APP_FOREGROUND, activityResumed)
                        }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saqia/irrigation_time_voice")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playTimeClips" -> playIrrigationClips(call.argument<List<String>>("clips") ?: emptyList(), result)
                    "announceTime" -> {
                        val text = call.argument<String>("text")?.trim()
                        if (text.isNullOrEmpty()) result.error("EMPTY_TIME_TEXT", "لا يوجد وقت للنطق", null)
                        else announceIrrigationTime(text, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(EXTRA_QUICK_ACTION)?.let { action ->
            pendingQuickAction = action
            bubbleMethodChannel?.invokeMethod("quickAction", action, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingQuickAction == action) pendingQuickAction = null
                }
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit
                override fun notImplemented() = Unit
            })
        }
    }

    companion object {
        const val EXTRA_QUICK_ACTION = "saqia.quick_action"
    }
}
