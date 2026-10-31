package com.lumenone.qixing

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * `gtd/native`（Dart → 原生）与 `gtd/native/events`（原生 → Dart）两条 MethodChannel 的实现，
 * 外加闹钟 PendingIntent 的构造/取消辅助方法。
 *
 * 生命周期约定：
 * - 每个 [MainActivity] 创建时 new 一个实例；channel 注册在 configureFlutterEngine 里；
 * - 接收器（闹钟/通知按钮）醒来时进程可能没有 Activity，此时 [activeInstance] 为 null，
 *   事件进 SharedPreferences 队列，等 Dart 调 `drainEvents`/`notifyReady` 再取；
 * - [NativeEventQueue] 保证队内事件与直接投递互斥，不会重复投递。
 */
class NativeBridge(
    private val activity: MainActivity,
    private val engine: FlutterEngine,
) {

    companion object {
        const val CHANNEL_METHODS = "gtd/native"
        const val CHANNEL_EVENTS = "gtd/native/events"

        private const val TAG = "gtd"

        /** 全局唯一闹钟（契约要求：新闹钟先取消旧的）。 */
        private const val ALARM_REQUEST_CODE = 0

        /** 灵感文件选择器（`pickMarkdownFile`）。 */
        private const val PICK_FILE_REQUEST_CODE = 1

        /** 当前活着的 bridge（供接收器直接投递事件）。 */
        @Volatile
        var activeInstance: NativeBridge? = null
            private set
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 冷启动时 Intent 里带过来的 focusTaskId，等 Dart ready 后再投递，避免丢事件。 */
    @Volatile
    private var pendingFocusTaskId: String? = null

    @Volatile
    private var pendingOpenPanel = false

    /** 悬浮面板 `openApp{target="settings"}` 的冷启动补投标记。 */
    @Volatile
    private var pendingOpenSettings = false

    /** 悬浮面板 `openApp{routineId=…}` 的冷启动补投值。 */
    @Volatile
    private var pendingFocusRoutineId: String? = null

    /** Dart 侧说事件通道已就绪；ready 之前一律只入队。可能被接收器线程读，故 @Volatile。 */
    @Volatile
    private var dartReady = false

    /** false = 没有 Dart 监听者（例如 engine 只跑 Dart 后台 isolate），事件必须留在队列。 */
    @Volatile
    private var eventChannelReady = true

    /** 等着回话的 `pickMarkdownFile` 调用：选择器是异步的，结果从 onActivityResult 回来。 */
    private var pendingPick: MethodChannel.Result? = null

    // ---------------------------------------------------------------- 方法通道

    fun attach() {
        // engine 重建时旧 bridge 可能还攒着没投出去的冷启动事件：先落盘，保证不丢。
        activeInstance?.takeIf { it !== this }?.flushPendingToQueue()
        activeInstance = this
        val events = MethodChannel(engine.dartExecutor, CHANNEL_EVENTS)
        events.setMethodCallHandler { call, result ->
            if (call.method == "notifyReady" || call.method == "ready") {
                dartReady = true
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        eventChannel = events

        val channel = MethodChannel(engine.dartExecutor, CHANNEL_METHODS)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        methodChannel = channel

        // 新一次 attach 意味着 Dart 侧通道尚未确认；等 notifyReady 再直投。
        dartReady = false
        eventChannelReady = true
        NativeEventQueue.setDirectDeliverer { event -> deliverNow(event) }
        Log.i(TAG, "NativeBridge attached")
    }

    fun detach() {
        flushPendingToQueue()
        // 选择器还开着时 Activity 就被销毁（低内存重建）：先回话，别让 Dart 那头的
        // future 永远挂着——回 null 等于"没选"，UI 保持原路径。
        pendingPick?.success(null)
        pendingPick = null
        val wasActive = activeInstance === this
        if (wasActive) activeInstance = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setMethodCallHandler(null)
        eventChannel = null
        dartReady = false
        // 只有"当前活跃的 bridge"才有资格拆掉全局直投通道，
        // 否则旧 Activity 的销毁会把新 engine 的通道一起抹掉。
        if (wasActive) NativeEventQueue.clearDirectDeliverer()
    }

    /** 把尚未投出的冷启动事件压进持久队列（engine 重建 / Activity 销毁时用）。 */
    private fun flushPendingToQueue() {
        val taskId = pendingFocusTaskId
        if (taskId != null) {
            pendingFocusTaskId = null
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
        }
        val routineId = pendingFocusRoutineId
        if (routineId != null) {
            pendingFocusRoutineId = null
            NativeEventQueue.enqueueOnly(
                activity,
                mapOf("type" to "focusRoutine", "routineId" to routineId),
            )
        }
        if (pendingOpenPanel) {
            pendingOpenPanel = false
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "overlayHandleOpened"))
        }
        if (pendingOpenSettings) {
            pendingOpenSettings = false
            NativeEventQueue.enqueueOnly(activity, mapOf("type" to "openSettings"))
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "scheduleAlarm" -> result.success(scheduleAlarm(call))
                "cancelAlarm" -> result.success(cancelAlarm())
                "showNotification" -> result.success(showNotification(call))
                "cancelNotification" -> result.success(cancelNotification(call))
                "drainEvents" -> result.success(NativeEventQueue.drain(activity))
                "canUseFullScreenIntent" -> result.success(Notifier.canUseFullScreenIntent(activity))
                "requestFullScreenIntentPermission" -> result.success(requestFullScreenIntentPermission())
                "hasOverlayPermission" -> result.success(hasOverlayPermission())
                "requestOverlayPermission" -> result.success(requestOverlayPermission())
                "setOverlayHandle" -> result.success(setOverlayHandle(call))
                "setHandleLocked" -> result.success(setHandleLocked(call))
                "setHandleHotWidth" -> result.success(setHandleHotWidth(call))
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "appVersion" -> result.success(appVersion())
                "pickMarkdownFile" -> {
                    // 异步：结果从 onActivityResult 回来，这里先不回话。
                    pickMarkdownFile(result)
                    return
                }
                "notifyReady" -> {
                    dartReady = true
                    result.success(true)
                    flushPendingIntents()
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // 契约：任何失败都只回 false，不让异常穿过 channel。
            Log.w(TAG, "method ${call.method} failed: ${t.message}", t)
            result.success(false)
        }
    }

    // ------------------------------------------------------------------- 闹钟

    /** @return true = 已武装（精确或尽力而为）；false = 硬失败（如系统异常）。 */
    private fun scheduleAlarm(call: MethodCall): Boolean {
        val reminder = readReminder(call, requireAt = true) ?: return false
        val atMillis = call.argument<Number>("atMillis")?.toLong() ?: return false
        // 契约：全局单闹钟，先撤销旧的（哪怕这次失败，旧闹钟也不该残留）。
        cancelAlarm()

        val manager = activity.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        val pendingIntent = alarmPendingIntent(reminder)
        return try {
            if (canScheduleExact(manager)) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
            } else {
                // 未授予精确闹钟权限时的降级：窗口化尽力而为，仍然算成功。
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "scheduleAlarm failed at=$atMillis", t)
            false
        }
    }

    private fun cancelAlarm(): Boolean = try {
        val manager = activity.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        // 只有 extras 相同的 PendingIntent 才会匹配（FLAG_UPDATE_CURRENT + 同 action/组件）。
        val placeholder = Reminder("", "", null, ReminderChannel.RING, false, emptyList())
        manager.cancel(alarmPendingIntent(placeholder))
        true
    } catch (t: Throwable) {
        Log.w(TAG, "cancelAlarm failed: ${t.message}")
        false
    }

    private fun canScheduleExact(manager: AlarmManager): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                manager.canScheduleExactAlarms()
            } catch (_: Throwable) {
                false
            }
        } else {
            true
        }

    // ------------------------------------------------------------------- 通知

    private fun showNotification(call: MethodCall): Boolean {
        val reminder = readReminder(call, requireAt = false) ?: return false
        return Notifier.post(activity, reminder)
    }

    private fun cancelNotification(call: MethodCall): Boolean {
        val taskId = call.argument<String>("taskId") ?: return false
        return Notifier.cancel(activity, taskId)
    }

    // ------------------------------------------------------------- 权限与查询

    private fun requestFullScreenIntentPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "open full-screen-intent settings failed: ${t.message}")
        }
        // 系统设置是异步的，这里返回"此刻"的状态，Dart 侧应在 resume 后再查询一次。
        return Notifier.canUseFullScreenIntent(activity)
    }

    private fun hasOverlayPermission(): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            true
        } else {
            try {
                Settings.canDrawOverlays(activity)
            } catch (_: Throwable) {
                false
            }
        }

    private fun requestOverlayPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        try {
            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                data = Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "open overlay settings failed: ${t.message}")
            // 部分 ROM 不支持带 package 的 ACTION_MANAGE_OVERLAY_PERMISSION，退化为总列表。
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Throwable) {
                // 彻底打不开就只回报状态
            }
        }
        return hasOverlayPermission()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        try {
            val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
            power?.isIgnoringBatteryOptimizations(activity.packageName) ?: false
        } catch (_: Throwable) {
            false
        }

    // ------------------------------------------------------------------- 关于

    /**
     * 安装包的版本：`versionName` + `versionCode`（设置页那张关于卡，ui-interaction §9 #14）。
     *
     * 不引 `package_info_plus`——那个插件的安卓 Gradle 脚本自己 apply 了 Kotlin Gradle
     * Plugin，而 AGP 9 起 Kotlin 内置、Flutter 往后会禁掉这条路。这里只回两截事实，
     * `1.2.0 (4)` 这种拼法留在 Dart 侧。
     */
    private fun appVersion(): Map<String, String> {
        val pm = activity.packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(activity.packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf(
            "version" to (info.versionName ?: ""),
            "build" to code.toString(),
        )
    }

    private fun setOverlayHandle(call: MethodCall): Boolean {
        val enabled = call.argument<Boolean>("enabled") ?: false
        return OverlayHandleService.setEnabled(activity, enabled)
    }

    /**
     * 把手位置上锁（settings.json 的 `handle_locked` 的执行侧）。
     *
     * 只锁"竖向拖动改变 y"，长按换边与横拖拉开都照旧。服务没在跑也没关系——
     * 值已落原生 prefs，下次服务 onCreate 会读到。
     */
    private fun setHandleLocked(call: MethodCall): Boolean {
        val locked = call.argument<Boolean>("locked") ?: false
        OverlayHandleService.setLocked(activity, locked)
        return true
    }

    /**
     * 把手热区宽度（settings.json 的 `handle_hot_width` 的执行侧）。
     *
     * 改的是把手窗口宽度与它声明的手势排除区；服务没在跑也没关系——
     * 值已落原生 prefs，下次服务 onCreate 会读到。
     */
    private fun setHandleHotWidth(call: MethodCall): Boolean {
        val dp = call.argument<Number>("widthDp")?.toInt() ?: return false
        OverlayHandleService.setHotZoneWidth(activity, dp)
        return true
    }

    // -------------------------------------------------------------- 事件投递

    /**
     * 直接投递（当前 Activity + Dart ready）。
     *
     * @return true = 已交给 Dart，调用方无须入队。
     */
    private fun deliverNow(event: Map<String, Any?>): Boolean {
        val channel = eventChannel
        if (!dartReady || !eventChannelReady || channel == null) return false
        // 接收器可能在任意线程上醒来；MethodChannel 只能在平台主线程上调。
        if (Looper.myLooper() !== Looper.getMainLooper()) {
            mainHandler.post { deliverNow(event) }
            return true
        }
        return try {
            channel.invokeMethod("event", event)
            true
        } catch (t: Throwable) {
            // MissingPluginException / channel 已失效：本次返回 false 让
            // NativeEventQueue.publish 把事件落进持久队列（恰好一次）。
            eventChannelReady = false
            Log.w(TAG, "direct event delivery failed, queueing: ${t.message}")
            false
        }
    }

    /** 冷启动 intent 的补投（在 Dart notifyReady 之后调用）。 */
    private fun flushPendingIntents() {
        val taskId = pendingFocusTaskId
        if (taskId != null) {
            pendingFocusTaskId = null
            NativeEventQueue.publish(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
        }
        val routineId = pendingFocusRoutineId
        if (routineId != null) {
            pendingFocusRoutineId = null
            NativeEventQueue.publish(
                activity,
                mapOf("type" to "focusRoutine", "routineId" to routineId),
            )
        }
        if (pendingOpenPanel) {
            pendingOpenPanel = false
            NativeEventQueue.publish(activity, mapOf("type" to "overlayHandleOpened"))
        }
        if (pendingOpenSettings) {
            pendingOpenSettings = false
            NativeEventQueue.publish(activity, mapOf("type" to "openSettings"))
        }
    }

    /**
     * 由 [MainActivity] 在 onCreate/onNewIntent 调用。
     *
     * Dart 还没 ready 时先把参数挂进 pending 字段，避免冷启动丢事件。
     */
    fun onActivityIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.getBooleanExtra(MainActivity.EXTRA_OPEN_PANEL, false)) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "overlayHandleOpened"))
            } else {
                pendingOpenPanel = true
            }
        }
        val taskId = intent.getStringExtra(MainActivity.EXTRA_FOCUS_TASK_ID)
        if (!taskId.isNullOrEmpty()) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "notificationTap", "taskId" to taskId))
            } else {
                pendingFocusTaskId = taskId
            }
        }
        // 悬浮面板 openApp{target="settings"}：落到设置页。
        if (intent.getBooleanExtra(MainActivity.EXTRA_OPEN_SETTINGS, false)) {
            if (dartReady) {
                NativeEventQueue.publish(activity, mapOf("type" to "openSettings"))
            } else {
                pendingOpenSettings = true
            }
        }
        // 悬浮面板 openApp{routineId=…}：落到该日程。
        val routineId = intent.getStringExtra(MainActivity.EXTRA_FOCUS_ROUTINE_ID)
        if (!routineId.isNullOrEmpty()) {
            if (dartReady) {
                NativeEventQueue.publish(
                    activity,
                    mapOf("type" to "focusRoutine", "routineId" to routineId),
                )
            } else {
                pendingFocusRoutineId = routineId
            }
        }
        // 同一个 Intent 在 Activity 重建/engine 重建时可能被再看一遍：读过就抹掉，
        // 保证一次点击只产生一个事件（pending 也已记下，不会因此丢失）。
        intent.removeExtra(MainActivity.EXTRA_FOCUS_TASK_ID)
        intent.removeExtra(MainActivity.EXTRA_OPEN_PANEL)
        intent.removeExtra(MainActivity.EXTRA_OPEN_SETTINGS)
        intent.removeExtra(MainActivity.EXTRA_FOCUS_ROUTINE_ID)
    }

    // ------------------------------------------------------------------ 解析

    private fun readReminder(call: MethodCall, requireAt: Boolean): Reminder? {
        val taskId = call.argument<String>("taskId") ?: return null
        val title = call.argument<String>("title") ?: return null
        if (requireAt && call.argument<Number>("atMillis") == null) return null
        val actions = mutableListOf<ReminderAction>()
        val rawActions = call.argument<List<Any?>>("actions")
        rawActions?.forEach { item ->
            val map = item as? Map<*, *> ?: return@forEach
            val id = map["id"] as? String ?: return@forEach
            val label = map["label"] as? String ?: id
            actions += ReminderAction(id, label)
        }
        return Reminder(
            taskId = taskId,
            title = title,
            body = call.argument<String>("body"),
            channel = ReminderChannel.fromName(call.argument<String>("channel")),
            fullScreen = call.argument<Boolean>("fullScreen") ?: false,
            actions = actions,
        )
    }

    private fun alarmPendingIntent(reminder: Reminder): PendingIntent = PendingIntent.getBroadcast(
        activity,
        ALARM_REQUEST_CODE,
        alarmIntent(activity, reminder),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    // -------------------------------------------------------- 文件选择（灵感页）

    /**
     * 挑一个 Markdown，回**真实文件路径**（灵感页入口，见 docs/panels/notes.md §6.2）。
     *
     * 不走 file_picker：它挑文件一律把原件复制进 App 缓存再回副本路径，写回就写进副本，
     * Obsidian 里那份永远不动（挑目录走的是另一条分支，所以任务目录一直好好的）。
     * 这里自己发 SAF，再把 documentId 换回共享存储上的真实路径——应用有"所有文件访问"，
     * 换出来的路径直接可读写。
     *
     * 不按 MIME 过滤：`.md` 在不同 ROM 上被标成 `text/markdown` /
     * `application/octet-stream` 都有，过滤条件一旦对不上，文件在选择器里就是灰的、
     * 根本点不着。类型交给 Dart 侧验。
     */
    private fun pickMarkdownFile(result: MethodChannel.Result) {
        // 同时只挂一个：连点两下时前一次按取消处理，避免回调挂在旧 Result 上。
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            activity.startActivityForResult(intent, PICK_FILE_REQUEST_CODE)
        } catch (t: Throwable) {
            Log.w(TAG, "pickMarkdownFile: 没有可用的文件选择器", t)
            pendingPick = null
            result.success(null)
        }
    }

    /**
     * 选择器结果（[MainActivity.onActivityResult] 转发）。
     *
     * @return true = 这次结果归这里（已回话），调用方不必再交给别处。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FILE_REQUEST_CODE) return false
        val waiting = pendingPick ?: return true
        pendingPick = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        waiting.success(uri?.let { resolveDocumentPath(it) })
        return true
    }

    /**
     * document URI → 共享存储上的真实路径；换不出来（云盘、"最近"里挑到的特殊 provider）
     * 回 null，UI 退回手输。
     */
    private fun resolveDocumentPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path?.takeIf { File(it).canRead() }
        val candidates = ArrayList<String>(2)
        try {
            when (uri.authority) {
                // 共享存储：documentId = "primary:Documents/vault/灵感.md"；
                // 非主卷是 "<卷标>:<相对路径>"（如 "1B0F-3A2E:notes/灵感.md"）。
                "com.android.externalstorage.documents" -> {
                    val split = DocumentsContract.getDocumentId(uri).split(':', limit = 2)
                    if (split.size == 2) {
                        val root =
                            if (split[0].equals("primary", ignoreCase = true)) {
                                Environment.getExternalStorageDirectory().absolutePath
                            } else {
                                "/storage/${split[0]}"
                            }
                        candidates += if (split[1].isEmpty()) root else "$root/${split[1]}"
                    }
                }
                // 下载目录：documentId 形如 "raw:/storage/emulated/0/Download/灵感.md"。
                "com.android.providers.downloads.documents" -> {
                    val docId = DocumentsContract.getDocumentId(uri)
                    if (docId.startsWith("raw:")) candidates += docId.removePrefix("raw:")
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "resolveDocumentPath: documentId 解析失败", t)
        }
        candidates += queryDataColumn(uri)
        return candidates.firstOrNull { it.isNotBlank() && File(it).canRead() }
    }

    /** 兜底：直接问 provider 要 `_data` 列（有"所有文件访问"才读得到）。 */
    private fun queryDataColumn(uri: Uri): List<String> = try {
        val out = ArrayList<String>(1)
        activity.contentResolver
            .query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.takeIf { it.isNotBlank() }?.let { out += it }
                }
            }
        out
    } catch (t: Throwable) {
        emptyList()
    }
}

// ---------------------------------------------------------------- 闹钟 Intent

/**
 * 构造闹钟广播 Intent。
 *
 * 注意：PendingIntent 的"身份"由 requestCode + action + data + component 决定，
 * extras 不参与匹配。因此这里固定 action 串，让"取消旧闹钟"能命中同一个 PendingIntent，
 * 而 extras 走 FLAG_UPDATE_CURRENT 覆盖。
 */
internal fun alarmIntent(context: Context, reminder: Reminder): Intent =
    Intent(context, ReminderReceiver::class.java).apply {
        setAction(ReminderReceiver.ACTION_REMINDER_ALARM)
        putExtra(ReminderExtras.TASK_ID, reminder.taskId)
        putExtra(ReminderExtras.TITLE, reminder.title)
        putExtra(ReminderExtras.BODY, reminder.body)
        putExtra(ReminderExtras.CHANNEL, reminder.channel.name)
        putExtra(ReminderExtras.FULL_SCREEN, reminder.fullScreen)
        putStringArrayListExtra(ReminderExtras.ACTION_IDS, ArrayList(reminder.actions.map { it.id }))
        putStringArrayListExtra(ReminderExtras.ACTION_LABELS, ArrayList(reminder.actions.map { it.label }))
    }

/** 从闹钟 Intent extras 还原 [Reminder]；缺字段时给出安全默认值。 */
internal fun reminderFromIntent(intent: Intent): Reminder {
    val taskId = intent.getStringExtra(ReminderExtras.TASK_ID).orEmpty()
    val ids = intent.getStringArrayListExtra(ReminderExtras.ACTION_IDS).orEmpty()
    val labels = intent.getStringArrayListExtra(ReminderExtras.ACTION_LABELS).orEmpty()
    val actions = ids.mapIndexed { index, id ->
        ReminderAction(id, labels.getOrNull(index) ?: id)
    }
    return Reminder(
        taskId = taskId,
        title = intent.getStringExtra(ReminderExtras.TITLE).orEmpty(),
        body = intent.getStringExtra(ReminderExtras.BODY),
        channel = ReminderChannel.fromName(intent.getStringExtra(ReminderExtras.CHANNEL)),
        fullScreen = intent.getBooleanExtra(ReminderExtras.FULL_SCREEN, false),
        actions = actions,
    )
}

// -------------------------------------------------------------- 事件持久队列

/**
 * 原生 → Dart 事件队列：SharedPreferences 里的 JSON 数组，进程重启后依然可捞回。
 *
 * 契约：事件要么直投、要么入队，绝不两者都做；[publish] 是唯一入口，
 * 它内部按"有直投通道 → 直投；否则入队"的顺序保证恰好一次。
 */
object NativeEventQueue {

    private const val PREFS = "gtd_native_events"
    private const val KEY_EVENTS = "events"

    private val lock = Any()

    /** 由 [NativeBridge] 注入：返回 true 表示已直投，无须入队。 */
    @Volatile
    private var directDeliverer: ((Map<String, Any?>) -> Boolean)? = null

    fun setDirectDeliverer(deliverer: (Map<String, Any?>) -> Boolean) {
        directDeliverer = deliverer
    }

    fun clearDirectDeliverer() {
        directDeliverer = null
    }

    /** 投递一个事件：能直投就直投，否则落到持久队列。 */
    fun publish(context: Context, event: Map<String, Any?>) {
        val deliver = directDeliverer
        if (deliver != null && deliver(event)) return
        enqueue(context, event)
    }

    private fun enqueue(context: Context, event: Map<String, Any?>) {
        synchronized(lock) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val array = readArray(prefs.getString(KEY_EVENTS, null))
            array.put(JSONObject(event as Map<*, *>))
            prefs.edit().putString(KEY_EVENTS, array.toString()).commit()
        }
    }

    /** 取走全部待处理事件并清空队列；返回类型即 MethodChannel 的 List<Map>。 */
    fun drain(context: Context): List<Map<String, Any?>> {
        synchronized(lock) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val array = readArray(prefs.getString(KEY_EVENTS, null))
            if (array.length() == 0) return emptyList()
            val out = ArrayList<Map<String, Any?>>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                out += jsonToMap(obj)
            }
            prefs.edit().remove(KEY_EVENTS).commit()
            return out
        }
    }

    /** 仅供排队（接收器在无 Activity 场景下也可直接调）。 */
    fun enqueueOnly(context: Context, event: Map<String, Any?>) = enqueue(context, event)

    private fun readArray(raw: String?): JSONArray = try {
        if (raw.isNullOrEmpty()) JSONArray() else JSONArray(raw)
    } catch (_: Throwable) {
        JSONArray()
    }

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = obj.opt(key)
            map[key] = if (value == JSONObject.NULL) null else value
        }
        return map
    }
}
