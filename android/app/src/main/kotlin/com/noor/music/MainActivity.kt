package com.noor.music

import android.app.SearchManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.IntentFilter
import android.app.PendingIntent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import java.io.File
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.content.Intent
import android.os.Bundle
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Size
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Exposes the phone's music library to Flutter ("My Music"):
 *  - list: every music file Android's media library knows (30 s or longer)
 *  - art:  a small JPEG of a song's album art, or null
 * Both run off the main thread. Reading needs READ_MEDIA_AUDIO (Android 13+)
 * or READ_EXTERNAL_STORAGE (older), asked for from Flutter.
 *
 * Extends AudioServiceActivity so background playback keeps sharing the
 * same Flutter engine; the manifest must launch this class, not the
 * plugin's activity, or the channel above never exists.
 */
class MainActivity : AudioServiceActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /// What Noor was asked to play when it was opened: a voice request
    /// ("play X on Noor" sends MEDIA_PLAY_FROM_SEARCH) or a home-screen
    /// shortcut (noor://play?q=..., noor://resume). Flutter takes it once.
    private var pendingPlay: String? = null
    private var launch: MethodChannel? = null

    private fun playRequestOf(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action == MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) {
            return intent.getStringExtra(SearchManager.QUERY) ?: ""
        }
        val data = intent.data ?: return null
        if (data.scheme != "noor") return null
        return when (data.host) {
            "resume" -> ""
            "play" -> data.getQueryParameter("q") ?: ""
            else -> null
        }
    }

    /// How Noor was opened, for the playback log (which app asked, and how).
    private var openedBy: String = ""

    private fun describe(intent: Intent?): String {
        if (intent == null) return "no intent"
        val keys = intent.extras?.keySet()?.joinToString(",") ?: ""
        return "action=${intent.action} data=${intent.data} from=${referrer?.host} extras=[$keys]"
    }

    // Coming back to the front while already running: Gemini's "open Noor",
    // the app icon or the recents screen only bring the app forward, with no
    // new intent. onResume tells Flutter, which plays if "Play when Noor
    // opens" is on (an explicit request in onNewIntent wins instead).
    private var stoppedAt = 0L
    private var returning = false
    private var askedOnReturn = false

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingPlay = playRequestOf(intent)
        openedBy = describe(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openedBy = describe(intent)
        val q = playRequestOf(intent) ?: return
        askedOnReturn = true
        // Already running: hand it straight to Flutter.
        launch?.invokeMethod("play", q) ?: run { pendingPlay = q }
    }

    override fun onStop() {
        super.onStop()
        stoppedAt = SystemClock.elapsedRealtime()
    }

    override fun onRestart() {
        super.onRestart()
        returning = true
    }

    override fun onResume() {
        super.onResume()
        if (returning && !askedOnReturn) {
            val away = (SystemClock.elapsedRealtime() - stoppedAt) / 1000
            launch?.invokeMethod("opened", mapOf("away" to away, "how" to openedBy))
        }
        returning = false
        askedOnReturn = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/launch").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> { result.success(pendingPlay); pendingPlay = null }
                    "how" -> result.success(openedBy)
                    else -> result.notImplemented()
                }
            }
        }
        val app = applicationContext
        // Network, for the "Auto" song quality: Wi-Fi (not metered) and
        // Android's Data Saver.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/network")
            .setMethodCallHandler { call, result ->
                if (call.method != "info") { result.notImplemented(); return@setMethodCallHandler }
                try {
                    val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                    val unmetered = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true
                    val wifi = caps != null && unmetered &&
                        (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                    val saver = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                        cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
                    result.success(mapOf("wifi" to wifi, "saver" to saver, "online" to (caps != null)))
                } catch (e: Exception) {
                    result.success(mapOf("wifi" to false, "saver" to false))
                }
            }

        // The phone's media volume, for the volume bar on the record player:
        // read it, set it, and follow changes made with the volume buttons.
        val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        fun volume(): Double {
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            return if (max <= 0) 0.0 else audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/volume")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> result.success(volume())
                    "set" -> {
                        val v = (call.argument<Number>("value"))?.toDouble() ?: 0.0
                        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val step = Math.round(v.coerceIn(0.0, 1.0) * max).toInt()
                        try { audio.setStreamVolume(AudioManager.STREAM_MUSIC, step, 0) } catch (_: Exception) {}
                        result.success(volume())
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/volume/changes")
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var receiver: BroadcastReceiver? = null
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val r = object : BroadcastReceiver() {
                        override fun onReceive(c: Context?, i: Intent?) {
                            val stream = i?.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
                            if (stream == AudioManager.STREAM_MUSIC) events.success(volume())
                        }
                    }
                    val filter = IntentFilter("android.media.VOLUME_CHANGED_ACTION")
                    if (Build.VERSION.SDK_INT >= 33) {
                        app.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
                    } else {
                        app.registerReceiver(r, filter)
                    }
                    receiver = r
                    events.success(volume())
                }
                override fun onCancel(arguments: Any?) {
                    receiver?.let { try { app.unregisterReceiver(it) } catch (_: Exception) {} }
                    receiver = null
                }
            })

        // Earbuds / headphones connecting and disconnecting, for the
        // animation. The devices already connected when listening starts are
        // reported once by Android; those are skipped (only changes count).
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/audio_devices")
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var callback: AudioDeviceCallback? = null
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    // Devices already connected now are not announced. (Android
                    // also reports them right after registering; some phones
                    // do not, so they are remembered here rather than skipping
                    // the first report.)
                    val known = HashSet<Int>()
                    try {
                        for (d in audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) known.add(d.id)
                    } catch (_: Exception) {}
                    fun kindOf(d: AudioDeviceInfo): String? = when (d.type) {
                        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                        26 /* TYPE_BLE_HEADSET */,
                        23 /* TYPE_HEARING_AID */ -> "buds"
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        22 /* TYPE_USB_HEADSET */ -> "wired"
                        else -> null
                    }
                    fun send(devices: Array<out AudioDeviceInfo>, event: String) {
                        val seen = HashSet<String>()
                        for (d in devices) {
                            if (!d.isSink) continue
                            val kind = kindOf(d) ?: continue
                            val name = d.productName?.toString()?.trim().orEmpty()
                            if (!seen.add(name + kind)) continue
                            events.success(mapOf("event" to event, "name" to name, "kind" to kind, "type" to d.type))
                        }
                    }
                    val c = object : AudioDeviceCallback() {
                        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
                            val fresh = added.filter { known.add(it.id) }.toTypedArray()
                            if (fresh.isNotEmpty()) send(fresh, "connected")
                        }
                        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
                            for (d in removed) known.remove(d.id)
                            send(removed, "disconnected")
                        }
                    }
                    audio.registerAudioDeviceCallback(c, main)
                    callback = c
                }
                override fun onCancel(arguments: Any?) {
                    callback?.let { try { audio.unregisterAudioDeviceCallback(it) } catch (_: Exception) {} }
                    callback = null
                }
            })

        // Updates: Noor installs a newer build of itself (downloaded and
        // checked in Dart). Android 12+ may let it update itself without a
        // tap; otherwise Android shows its own confirmation.
        val updater = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/updater")
        val statusAction = "${packageName}.UPDATE_STATUS"
        val statusReceiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                val status = i?.getIntExtra(PackageInstaller.EXTRA_STATUS, -999) ?: -999
                val msg = i?.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                when (status) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = i?.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm != null) {
                            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try { app.startActivity(confirm) } catch (_: Exception) {}
                        }
                        updater.invokeMethod("status", mapOf("status" to "pending_user"))
                    }
                    PackageInstaller.STATUS_SUCCESS ->
                        updater.invokeMethod("status", mapOf("status" to "success"))
                    else -> updater.invokeMethod("status",
                        mapOf("status" to "failed", "code" to status, "message" to msg))
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(statusReceiver, IntentFilter(statusAction), Context.RECEIVER_NOT_EXPORTED)
        } else {
            app.registerReceiver(statusReceiver, IntentFilter(statusAction))
        }
        updater.setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        app.packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    io.execute {
                        try {
                            val file = File(path ?: "")
                            val installer = app.packageManager.packageInstaller
                            val params = PackageInstaller.SessionParams(
                                PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                            params.setAppPackageName(packageName)
                            if (Build.VERSION.SDK_INT >= 31) {
                                params.setRequireUserAction(
                                    PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                            }
                            val id = installer.createSession(params)
                            installer.openSession(id).use { session ->
                                file.inputStream().use { input ->
                                    session.openWrite("noor.apk", 0, file.length()).use { out ->
                                        input.copyTo(out)
                                        session.fsync(out)
                                    }
                                }
                                val flags = if (Build.VERSION.SDK_INT >= 31)
                                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                                else PendingIntent.FLAG_UPDATE_CURRENT
                                val pi = PendingIntent.getBroadcast(app, id,
                                    Intent(statusAction).setPackage(packageName), flags)
                                session.commit(pi.intentSender)
                            }
                            main.post { result.success(null) }
                        } catch (e: Exception) {
                            main.post { result.error("install_failed", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noor/local_music")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> io.execute {
                        val songs = try { listSongs() } catch (e: Exception) { null }
                        main.post {
                            if (songs == null) result.error("query_failed", "Could not read the music library", null)
                            else result.success(songs)
                        }
                    }
                    "art" -> {
                        val id = (call.argument<Number>("id"))?.toLong()
                        if (id == null) { result.success(null); return@setMethodCallHandler }
                        io.execute {
                            val bytes = try { albumArt(id) } catch (e: Exception) { null }
                            main.post { result.success(bytes) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun listSongs(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.DURATION,
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 30000"
        contentResolver.query(
            collection, projection, selection, null,
            "${MediaStore.Audio.Media.DATE_ADDED} DESC"
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val durCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            while (c.moveToNext() && out.size < 2000) {
                val id = c.getLong(idCol)
                out.add(mapOf(
                    "id" to id,
                    "title" to (c.getString(titleCol) ?: "Unknown"),
                    "artist" to (c.getString(artistCol)?.takeUnless { it == "<unknown>" } ?: ""),
                    "durationMs" to c.getLong(durCol),
                    "uri" to ContentUris.withAppendedId(collection, id).toString(),
                ))
            }
        }
        return out
    }

    private fun albumArt(id: Long): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val bmp = contentResolver.loadThumbnail(uri, Size(320, 320), null)
        val stream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 85, stream)
        return stream.toByteArray()
    }
}
