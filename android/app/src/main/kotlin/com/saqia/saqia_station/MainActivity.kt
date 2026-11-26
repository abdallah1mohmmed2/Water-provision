package com.saqia.saqia_station

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.ContactsContract
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var irrigationTimeTts: android.speech.tts.TextToSpeech? = null
    private var pendingTimeVoiceResult: MethodChannel.Result? = null
    private var timeVoiceSequence = 0

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
                if (call.method != "announceTime") {
                    result.notImplemented()
                } else {
                    val text = call.argument<String>("text")?.trim()
                    if (text.isNullOrEmpty()) {
                        result.error("EMPTY_TIME_TEXT", "لا يوجد وقت للنطق", null)
                    } else {
                        announceIrrigationTime(text, result)
                    }
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
