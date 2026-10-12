package com.example.gtd_todo

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 系统级悬浮把手 + **就地展开的悬浮面板**（v1.6）。
 *
 * 与 v1.5 的关键区别：点按/横甩不再 `startActivity` 跳进应用，而是在**当前 App 之上**
 * 就地展开面板。面板是同一个前台服务里**第二个 FlutterEngine** 的 FlutterView，
 * 作为全屏透明的 `TYPE_APPLICATION_OVERLAY` 窗口挂在 WindowManager 上，
 * 走 `gtd/overlay` 通道与 Dart 的 `overlayMain` entrypoint 通信。
 *
 * 职责划分：
 * - 原生：引擎/视图/窗口生命周期、把手手势、与主 isolate 的 intent 桥接、状态广播；
 * - Dart：面板的全部视觉（含半透明遮罩与"点遮罩收起"）。
 *
 * 交互契约：
 * - 点按 / 朝屏幕中心横甩 → [expandPanel]（不再跳应用）；只有引擎或视图创建失败才回退到
 *   原来的 `startActivity(MainActivity, openPanel=true)`，保证永远有可用入口；
 * - 展开时把手隐藏，收起后按宿主前后台状态决定是否重新显示；
 * - 宿主在前台（[notifyHostForeground] true）→ 收起面板 + 隐藏把手（有应用内把手）；
 * - [setEnabled] false → 销毁引擎、移除面板与把手、停服务；
 * - 手柄只竖向移动、贴边停靠、位置持久化（v1.5 行为保持不变）。
 *
 * 所有 WindowManager / 引擎操作都吞异常：用户中途撤销悬浮窗权限或引擎起不来时
 * 只降级或停服务，绝不让进程崩掉。
 */
class OverlayHandleService : Service() {

    companion object {
        const val ACTION_START = "com.example.gtd_todo.action.OVERLAY_START"
        const val ACTION_STOP = "com.example.gtd_todo.action.OVERLAY_STOP"
        const val ACTION_HOST_FOREGROUND =
            "com.example.gtd_todo.action.OVERLAY_HOST_FOREGROUND"
        const val ACTION_HOST_BACKGROUND =
            "com.example.gtd_todo.action.OVERLAY_HOST_BACKGROUND"

        /** 悬浮面板 ↔ 它自己的 isolate（Dart `overlayMain`）。 */
        const val CHANNEL_OVERLAY = "gtd/overlay"

        /** 第二个引擎的 Dart entrypoint 名（Dart 侧用 @pragma('vm:entry-point') 标注）。 */
        private const val OVERLAY_ENTRYPOINT = "overlayMain"

        /**
         * entrypoint 所在库的 URI。
         *
         * **必须给**：kernel snapshot 的"根库"是 `main.dart`，只给函数名时引擎会在根库里
         * 找 `overlayMain` 并失败（实测日志：`Could not resolve main entrypoint function`，
         * 面板一片透明）。给出库 URI 后按 "库 + 函数名" 解析即可命中
         * `lib/overlay_main.dart` 里的 `overlayMain`。
         */
        private const val OVERLAY_ENTRYPOINT_LIBRARY = "package:gtd_todo/overlay_main.dart"

        private const val TAG = "gtd"

        private const val PREFS = "gtd_overlay"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_DOCKED_RIGHT = "docked_right"
        private const val KEY_Y = "y"

        /**
         * 手柄尺寸（dp）：**贴在边缘的一段半透明白条**（v1.10 / 决议 40）。
         *
         * 原先是 26×72 的橙色圆角块；现在故意做窄做淡——日常它就该是"几乎看不见"的，
         * 只在用户主动去找时才注意到。竖向留到 88dp 是为了抓握与点按够得着：
         * 宽度还能再砍，高度再短就一次摁不准了。
         */
        private const val HANDLE_WIDTH_DP = 10
        private const val HANDLE_HEIGHT_DP = 88

        /** 白条的不透明度（0–255 的 alpha）：55% ≈ 140。 */
        private const val HANDLE_ALPHA = 140

        /** 判定为"拖拽"的最小位移（px），低于它算点击。 */
        private const val TOUCH_SLOP_DP = 6

        /** 向屏幕中心划动多少像素算作"打开"。 */
        private const val FLING_THRESHOLD_DP = 24

        /** notifyReady 后等待 Dart 来取初始状态的上限。 */
        private const val READY_ACK_TIMEOUT_MS = 3_000L

        /**
         * 探测"这次 entrypoint 解析成功了吗"的等待上限。
         *
         * 解析失败是引擎内部线程异步打日志的，没有回调可挂；唯一可靠的信号是
         * Dart 起来后调 `notifyReady`。所以要等一小会儿再决定是否换下一种解析形式。
         * 只有第一种形式失败时才会真的等满（成功时会在毫秒级返回）。
         */
        private const val ENTRYPOINT_PROBE_TIMEOUT_MS = 1_500L

        private fun describe(entrypoint: DartExecutor.DartEntrypoint): String =
            if (entrypoint.dartEntrypointLibrary == null) {
                "function=${entrypoint.dartEntrypointFunctionName}"
            } else {
                "library=${entrypoint.dartEntrypointLibrary} function=${entrypoint.dartEntrypointFunctionName}"
            }

        /** 当前活着的服务实例（同进程直接调用，避免 intent 竞态）。 */
        @Volatile
        private var instance: OverlayHandleService? = null

        private fun prefs(context: Context): SharedPreferences =
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * 供 [NativeBridge] 调用的开关。
         *
         * @return true = 已按要求推进到目标状态（或本来就无需改变）；
         *         false = 缺悬浮窗权限 / 启动失败。
         */
        fun setEnabled(context: Context, enabled: Boolean): Boolean {
            val app = context.applicationContext
            prefs(app).edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (!enabled) {
                try {
                    app.startService(
                        Intent(app, OverlayHandleService::class.java).setAction(ACTION_STOP)
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "overlay stop failed: ${t.message}")
                }
                // 停止永远算成功：用户的意图是"别显示了"。
                return true
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !canDrawOverlays(app)) {
                Log.w(TAG, "overlay start rejected: no SYSTEM_ALERT_WINDOW")
                return false
            }
            val intent = Intent(app, OverlayHandleService::class.java).setAction(ACTION_START)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    app.startForegroundService(intent)
                } else {
                    app.startService(intent)
                }
                true
            } catch (t: Throwable) {
                // Android 12+ 后台启动前台服务受限：明确回报失败而不是假装成功。
                Log.w(TAG, "overlay start failed: ${t.message}", t)
                false
            }
        }

        /**
         * 本应用进退前台时调用（[MainActivity] 的 onResume/onPause）：
         * 前台 → **收起面板** + 手柄隐藏；后台 → 面板保持收起，手柄显示。
         *
         * 服务没在跑（被系统回收等）时，只在用户确实开过把手的情况下重新拉起，
         * 不会因为"应用回到前台"就凭空开一个悬浮窗。
         */
        fun notifyHostForeground(context: Context, foreground: Boolean) {
            val app = context.applicationContext
            instance?.let {
                it.setHostForeground(foreground)
                return
            }
            if (!prefs(app).getBoolean(KEY_ENABLED, false)) return
            try {
                val intent = Intent(app, OverlayHandleService::class.java).setAction(
                    if (foreground) ACTION_HOST_FOREGROUND else ACTION_HOST_BACKGROUND
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    app.startForegroundService(intent)
                } else {
                    app.startService(intent)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "overlay host-state intent failed: ${t.message}")
            }
        }

        private fun canDrawOverlays(context: Context): Boolean = try {
            Settings.canDrawOverlays(context)
        } catch (_: Throwable) {
            false
        }

        /** 用户是否开着系统级把手（设置页初始化开关用）。 */
        fun isEnabled(context: Context): Boolean =
            prefs(context).getBoolean(KEY_ENABLED, false)
    }

    // ------------------------------------------------------------- 原生视图状态

    private var windowManager: WindowManager? = null

    /** 把手（v1.5 行为保持不变）。 */
    private var handleView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** 面板（v1.6 新增）：第二个引擎的 FlutterView + 全屏透明窗口。 */
    private var panelView: FlutterView? = null
    private var panelParams: WindowManager.LayoutParams? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** true = 贴右边；false = 贴左边。默认右边。 */
    private var dockedRight = true

    /** 本应用是否在前台（在前台时把手隐藏，避免盖住自己的界面）。 */
    private var hostForeground = false

    /** 面板是否展开（展开时把手隐藏，二次展开不重复挂窗口）。 */
    private var panelExpanded = false

    private var density = 1f

    private var prefs: SharedPreferences? = null

    // --------------------------------------------------------------- overlay 引擎

    private var overlayEngine: FlutterEngine? = null
    private var overlayChannel: MethodChannel? = null

    /** Dart `overlayMain` 说它准备好了：之后原生可以（也应该）直接投状态。 */
    private var overlayReady = false

    /** Dart 已经明确要过状态，就不再需要超时补发。 */
    private var stateAcknowledged = false
    private var readyTimeout: Runnable? = null

    /** 引擎创建失败：把手退回 v1.5 的"跳进应用"路径，保证永远有入口。 */
    private var engineFailed = false

    /**
     * 当前正在探测的那次 entrypoint 启动：Dart 调 `notifyReady` 时 countDown，
     * 让 [ensureOverlayEngine] 知道这次解析成功了，不必再试下一种形式。
     */
    @Volatile
    private var overlayLaunchLatch: java.util.concurrent.CountDownLatch? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        density = resources.displayMetrics.density
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE).also {
            dockedRight = it.getBoolean(KEY_DOCKED_RIGHT, true)
        }
        startForegroundSafely()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                prefs?.edit()?.putBoolean(KEY_ENABLED, false)?.apply()
                stopSelf()
                return START_NOT_STICKY
            }
        }
        // 未授予悬浮窗权限时立刻放弃，避免前台服务白占资源。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !canDrawOverlays()) {
            Log.w(TAG, "overlay service stopping: permission lost")
            prefs?.edit()?.putBoolean(KEY_ENABLED, false)?.apply()
            stopSelf()
            return START_NOT_STICKY
        }
        // 先把宿主前后台状态记下来，再确保把手存在。
        // 注意顺序：ACTION_HOST_FOREGROUND/BACKGROUND 也必须走到 addHandle()，
        // 否则服务是被"进退前台"拉起来的时候（onCreate 后第一个 intent 就是它）
        // 把手永远不会被创建，applyVisibility() 作用在一个 null 视图上。
        when (intent?.action) {
            ACTION_HOST_FOREGROUND -> setHostForeground(true)
            ACTION_HOST_BACKGROUND -> setHostForeground(false)
        }
        addHandle()
        return START_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 旋屏/分屏：面板是全屏窗口，跟随系统即可；把手需要重新贴边并夹紧 y。
        relayout()
        // 面板窗口参数与屏幕尺寸无关（MATCH_PARENT），但保险起见重新贴一次。
        if (panelExpanded) updatePanelLayout()
    }

    override fun onDestroy() {
        removePanel()
        destroyOverlayEngine()
        removeHandle()
        if (instance === this) instance = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------ 前台通知

    private fun startForegroundSafely() {
        try {
            val notification = Notifier.buildOverlayNotification(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    Notifier.OVERLAY_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(Notifier.OVERLAY_NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            // 通知被禁用等情况下仍要尽量把悬浮手柄显示出来。
            Log.w(TAG, "startForeground failed: ${t.message}", t)
        }
    }

    // -------------------------------------------------------------------- 把手

    private fun addHandle() {
        if (handleView != null) {
            applyVisibility()
            return
        }
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        windowManager = wm

        val view = FrameLayout(this).apply {
            background = handleBackground()
            // 不放任何子 View：白条本身就是提示，再画一道白色握把线等于没有
            // （v1.10 / 决议 40 删掉了原来那条）。
            elevation = 4f * density
        }

        val params = WindowManager.LayoutParams(
            handleWidthPx(),
            handleHeightPx(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = edgeX(wm)
            y = restoredY(wm)
        }

        handleView = view
        layoutParams = params
        try {
            wm.addView(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "addView failed: ${t.message}", t)
            handleView = null
            layoutParams = null
            stopSelf()
            return
        }
        attachTouchHandler(view)
        declareGestureExclusion(view)
        applyVisibility()
    }

    private fun removeHandle() {
        val view = handleView
        handleView = null
        layoutParams = null
        try {
            if (view != null) windowManager?.removeView(view)
        } catch (t: Throwable) {
            Log.w(TAG, "removeView failed: ${t.message}")
        }
        windowManager = null
    }

    /**
     * 把手可见性：**面板展开**或**宿主在前台**时隐藏，其余显示。
     *
     * 两者任一满足都不该出现把手：面板展开时把手会被面板遮住/碍事，
     * 宿主在前台时应用内有自己的把手。
     */
    private fun applyVisibility() {
        val view = handleView ?: return
        val hide = hostForeground || panelExpanded
        val target = if (hide) View.GONE else View.VISIBLE
        if (view.visibility != target) view.visibility = target
        // 隐藏一轮之后再显示，排除区可能被丢掉：重新声明一次（幂等）。
        if (!hide) declareGestureExclusion(view)
    }

    /** 应用进退前台。契约：进前台要**收起面板** + 隐藏把手。 */
    private fun setHostForeground(foreground: Boolean) {
        if (hostForeground == foreground) {
            applyVisibility()
            return
        }
        hostForeground = foreground
        if (foreground && panelExpanded) collapsePanel(notifyDart = true)
        applyVisibility()
        Log.i(TAG, "overlay handle hostForeground=$foreground")
    }

    /** 重新贴边 + 夹紧 y（旋屏、换边、拖拽结束都走它）。 */
    private fun relayout() {
        val wm = windowManager ?: return
        val view = handleView ?: return
        val params = layoutParams ?: return
        params.x = edgeX(wm)
        params.y = clampY(params.y)
        updateView(view, params)
        persistPosition(params.y)
    }

    /**
     * 白条的底色（v1.10 / 决议 40）：带一层极淡描边，压在浅色壁纸上也不至于消失。
     *
     * 刻意**不跟随主题预设**：它浮在别人的 App、别人的壁纸上，"在哪都看得见"这一层
     * 保证比配色一致重要（理由同 ui-interaction.md §17C）。
     */
    private fun handleBackground(): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        // 圆角 = 宽度的一半 → 一条胶囊状竖条，而不是一块方板。
        cornerRadius = (HANDLE_WIDTH_DP / 2f) * density
        setColor(Color.argb(HANDLE_ALPHA, 255, 255, 255))
        setStroke(1, Color.parseColor("#2B000000"))
    }

    /**
     * 把这块区域从系统返回手势的边缘带里抠出来（v1.10 / 决议 41，API 29+）。
     *
     * 屏幕两侧各约 20dp 属于系统的返回手势：把手整块压在上面，用户的横拖就会被
     * InputMonitor **同时**判成 back —— 面板因此时开时不开，同一台机器上还随
     * "三键导航 / 全面屏手势"的切换而变。声明排除区之后，从把手起手的触摸不再被系统
     * 拿去判定返回手势。
     *
     * 两个要注意的点（踩错就是静默失效，没有任何报错）：
     * - **必须 attach 之后设**，所以放在 `view.post{}` 里；
     * - **坐标是视图自身坐标系**（`Rect(0,0,w,h)`），ViewRootImpl 会按视图在窗口里的位置
     *   叠加偏移，不需要自己换算成窗口坐标。
     *
     * 只罩住把手这一小块，远在系统给每边的配额内。面板是**全屏**窗口，**不给**它声明——
     * 那里的横向返回已经等同于收起面板，加了反而丢掉"边缘 = 返回"这个自然退出口
     * （局限记在架构合同 §12）。
     */
    private fun declareGestureExclusion(view: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        view.post {
            if (!view.isAttachedToWindow) return@post
            val w = view.width
            val h = view.height
            if (w <= 0 || h <= 0) return@post
            try {
                view.systemGestureExclusionRects = listOf(Rect(0, 0, w, h))
                Log.i(TAG, "overlay handle gesture exclusion declared: ${w}x$h")
            } catch (t: Throwable) {
                Log.w(TAG, "overlay handle gesture exclusion failed: ${t.message}")
            }
        }
    }

    private fun canDrawOverlays(): Boolean = try {
        Settings.canDrawOverlays(this)
    } catch (_: Throwable) {
        false
    }

    // ------------------------------------------------------------------ 交互

    private fun attachTouchHandler(view: View) {
        val slop = TOUCH_SLOP_DP * density
        val fling = FLING_THRESHOLD_DP * density

        view.setOnTouchListener(object : View.OnTouchListener {
            private var startY = 0f
            private var downX = 0f
            private var downY = 0f
            private var dragging = false
            private var longPressed = false
            private val longPressRunnable = Runnable {
                longPressed = true
                toggleDock()
            }

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                val params = layoutParams ?: return false
                val wm = windowManager
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        startY = params.y.toFloat()
                        downX = event.rawX
                        downY = event.rawY
                        dragging = false
                        longPressed = false
                        mainHandler.postDelayed(longPressRunnable, 500L)
                        return true
                    }

                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - downX
                        val dy = event.rawY - downY
                        if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                            dragging = true
                            mainHandler.removeCallbacks(longPressRunnable)
                        }
                        if (dragging) {
                            // 只竖向移动：x 永远贴边，不会被横向拖动带偏。
                            params.y = clampY((startY + dy).toInt())
                            if (wm != null) params.x = edgeX(wm)
                            updateView(v, params)
                            // 横向甩向屏幕中心即"展开面板"，不必等抬手。
                            if (isOpenGesture(dx, dy, fling)) {
                                mainHandler.removeCallbacks(longPressRunnable)
                                dragging = false
                                persistPosition(params.y)
                                expandPanel()
                                return true
                            }
                        }
                        return true
                    }

                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        mainHandler.removeCallbacks(longPressRunnable)
                        val dx = event.rawX - downX
                        val dy = event.rawY - downY
                        val moved = abs(dx) > slop || abs(dy) > slop
                        // 松手后回到贴边位置并把 y 夹回屏内（落盘，重启保留）。
                        relayout()
                        if (!longPressed && !moved) {
                            // 单次点按：展开面板
                            expandPanel()
                        } else if (!longPressed && isOpenGesture(dx, dy, slop)) {
                            expandPanel()
                        }
                        dragging = false
                        return true
                    }
                }
                return false
            }
        })
    }

    /**
     * 是否算"朝屏幕中心划开"：横向位移超过阈值、朝中心方向，且横向明显大于纵向。
     *
     * 纵向拖动只是移动手柄，不应该顺手把面板弹出来。
     */
    private fun isOpenGesture(dx: Float, dy: Float, threshold: Float): Boolean {
        if (abs(dx) <= threshold) return false
        if (abs(dx) <= abs(dy) * 1.5f) return false
        return isTowardCenter(dx)
    }

    /** dx > 0 表示往右拖；若手柄在左侧，则"朝屏幕中心"就是往右。 */
    private fun isTowardCenter(dx: Float): Boolean = if (dockedRight) dx < 0 else dx > 0

    private fun toggleDock() {
        val view = handleView ?: return
        val params = layoutParams ?: return
        dockedRight = !dockedRight
        prefs?.edit()?.putBoolean(KEY_DOCKED_RIGHT, dockedRight)?.apply()
        val wm = windowManager
        if (wm != null) params.x = edgeX(wm)
        params.y = clampY(params.y)
        updateView(view, params)
        persistPosition(params.y)
        // 面板的排版跟着停靠侧走。
        if (panelExpanded) notifyOverlayState()
    }

    // -------------------------------------------------------------------- 面板

    /**
     * 就地展开面板（不再跳应用）。
     *
     * 引擎/视图创建失败时回退到 v1.5 的 `startActivity(MainActivity, openPanel=true)`，
     * 保证用户点把手一定有反馈，不会出现"点了没反应"。
     */
    private fun expandPanel() {
        if (panelExpanded) {
            notifyOverlayState()
            return
        }
        if (!ensureOverlayEngine()) {
            Log.w(TAG, "expandPanel: engine unavailable, falling back to startActivity")
            fallbackOpenApp()
            return
        }
        if (!addPanelView()) {
            Log.w(TAG, "expandPanel: view unavailable, falling back to startActivity")
            fallbackOpenApp()
            return
        }
        panelExpanded = true
        applyVisibility()
        notifyOverlayState()
        Log.i(TAG, "overlay panel expanded")
    }

    /** 收起面板：移除窗口，引擎保活（下次展开状态还在）。 */
    private fun collapsePanel(notifyDart: Boolean) {
        if (!panelExpanded && panelView == null) {
            if (notifyDart) notifyOverlayState()
            return
        }
        panelExpanded = false
        removePanel()
        applyVisibility()
        if (notifyDart) notifyOverlayState()
        Log.i(TAG, "overlay panel collapsed")
    }

    /** 引擎起不来时的降级入口（v1.5 行为）。 */
    private fun fallbackOpenApp() {
        setHostForeground(true)
        NativeEventQueue.publish(applicationContext, mapOf("type" to "overlayHandleOpened"))
        try {
            startActivity(
                Intent(applicationContext, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra(MainActivity.EXTRA_OPEN_PANEL, true)
                }
            )
        } catch (t: Throwable) {
            // Android 10+ 后台启动 Activity 可能被拦，事件已经投出去了。
            Log.w(TAG, "fallback startActivity failed: ${t.message}")
        }
    }

    /**
     * 懒创建第二个引擎（只在首次展开时）。
     *
     * @return true = 引擎与 `gtd/overlay` 通道都可用。
     */
    private fun ensureOverlayEngine(): Boolean {
        if (engineFailed) return false
        overlayEngine?.let { return true }
        return try {
            val appContext = applicationContext
            val engine = FlutterEngine(appContext)
            // 面板与主 Activity 是两个独立 isolate：这里没有 Activity，生命周期要手动推。
            // 引擎默认停在 detached，不推 RESUMED 的话首帧不渲染（面板会是空白）。
            engine.lifecycleChannel.appIsResumed()

            val channel = MethodChannel(engine.dartExecutor, CHANNEL_OVERLAY)
            channel.setMethodCallHandler { call, result -> handleOverlayCall(call, result) }
            overlayChannel = channel

            val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
            // entrypoint 解析有两条路，且哪条能成取决于 Dart 侧怎么把 overlay_main.dart
            // 带进 kernel：直接 import 时"根库"仍不会命中，需要显式库 URI；export 出来
            // 才能用纯函数名解析。两条都试，谁先跑起来算谁。
            val attempts = listOf(
                // 顺序很重要：显式库 URI 是 Dart 侧 import 场景下的唯一可行解，
                // 而 import 是最可能的做法。带库 URI 的调用不匹配时不会回退到纯函数名解析。
                DartExecutor.DartEntrypoint(bundlePath, OVERLAY_ENTRYPOINT_LIBRARY, OVERLAY_ENTRYPOINT),
                DartExecutor.DartEntrypoint(bundlePath, OVERLAY_ENTRYPOINT),
            )
            var launched = false
            for ((index, entrypoint) in attempts.withIndex()) {
                Log.i(TAG, "trying overlay entrypoint: ${describe(entrypoint)}")
                engine.dartExecutor.executeDartEntrypoint(entrypoint)
                // 解析失败不会有回调/异常，只能靠"Dart 是否真的跑起来了"判断：
                // isExecutingDart 在 isolate 起来后为 true；Dart 侧第一件事又是 notifyReady。
                if (awaitOverlayDart(engine, ENTRYPOINT_PROBE_TIMEOUT_MS)) {
                    Log.i(TAG, "overlay entrypoint launched: ${describe(entrypoint)}")
                    launched = true
                    break
                }
                Log.w(
                    TAG,
                    "overlay entrypoint did not start (${describe(entrypoint)}), trying next form",
                )
            }
            if (!launched) {
                Log.w(TAG, "overlay entrypoint could not be launched by any form")
            }
            overlayEngine = engine
            overlayReady = false
            stateAcknowledged = false
            Log.i(TAG, "overlay engine started, entrypoint=$OVERLAY_ENTRYPOINT")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "overlay engine creation failed: ${t.message}", t)
            engineFailed = true
            overlayEngine = null
            overlayChannel = null
            false
        }
    }

    /**
     * 等这一次 entrypoint 真的把 Dart 跑起来。
     *
     * 两个信号取"或"：引擎的 `isExecutingDart()`（isolate 起来了）与 Dart 主动调的
     * `notifyReady`（面板已经装配好）。前者先到就够判定解析成功。
     */
    private fun awaitOverlayDart(engine: FlutterEngine, timeoutMs: Long): Boolean {
        val latch = java.util.concurrent.CountDownLatch(1)
        overlayLaunchLatch = latch
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (engine.dartExecutor.isExecutingDart || latch.count == 0L) {
                overlayLaunchLatch = null
                return true
            }
            try {
                // Dart 就绪时会被 handleOverlayCall 立刻 countDown，不必等满一个 tick。
                latch.await(100L, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        overlayLaunchLatch = null
        return engine.dartExecutor.isExecutingDart
    }

    private fun destroyOverlayEngine() {
        overlayChannel?.setMethodCallHandler(null)
        overlayChannel = null
        try {
            overlayEngine?.destroy()
        } catch (t: Throwable) {
            Log.w(TAG, "overlay engine destroy failed: ${t.message}")
        }
        overlayEngine = null
        overlayReady = false
        stateAcknowledged = false
        readyTimeout?.let { mainHandler.removeCallbacks(it) }
        readyTimeout = null
    }

    /**
     * 把面板 FlutterView 挂成全屏透明 overlay 窗口。
     *
     * @return true = 已成功挂上。
     */
    private fun addPanelView(): Boolean {
        if (panelView != null) return true
        val engine = overlayEngine ?: return false
        val wm = windowManager ?: (getSystemService(Context.WINDOW_SERVICE) as? WindowManager) ?: return false
        windowManager = wm

        // 显式标注类型：否则会被推断成 View?，后面调不到 detachFromFlutterEngine()。
        val view: FlutterView = try {
            // FlutterSurfaceView(context, true)：PixelFormat.TRANSPARENT + setZOrderOnTop，
            // 让面板底下的其它 App 透出来。透明失效时改用 FlutterTextureView（见 buildPanelView）。
            buildPanelView()
        } catch (t: Throwable) {
            Log.w(TAG, "panel view creation failed: ${t.message}", t)
            return false
        }

        return try {
            view.attachToFlutterEngine(engine)
            // 视图与窗口都必须透明：面板下面是别的 App，要能看见（遮罩由 Dart 画）。
            view.setBackgroundColor(0x00000000)
            val params = panelParams ?: buildPanelParams()
            wm.addView(view, params)
            panelView = view
            panelParams = params
            // 面板里要能输入文字/弹时间选择器：窗口可聚焦，并主动请求焦点。
            view.requestFocus()
            Log.i(TAG, "overlay panel view attached")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "panel addView failed: ${t.message}", t)
            try {
                view.detachFromFlutterEngine()
            } catch (_: Throwable) {
                // 忽略：没挂上就没得摘。
            }
            false
        }
    }

    /**
     * 面板视图的构造点。
     *
     * 目前用 FlutterSurfaceView(transparent=true)。若某些 ROM 上渲染成黑底，
     * 只需把这里换成 `FlutterView(this, FlutterTextureView(this))`——TextureView 走普通
     * 视图合成路径，透明一定生效（代价是多一次 GPU 拷贝）。
     */
    private fun buildPanelView(): FlutterView =
        FlutterView(this, FlutterSurfaceView(this, true))

    private fun removePanel() {
        val view = panelView
        panelView = null
        panelParams = null
        if (view == null) return
        try {
            windowManager?.removeView(view)
        } catch (t: Throwable) {
            Log.w(TAG, "panel removeView failed: ${t.message}")
        }
        try {
            view.detachFromFlutterEngine()
        } catch (t: Throwable) {
            Log.w(TAG, "panel detachFromFlutterEngine failed: ${t.message}")
        }
    }

    private fun buildPanelParams(): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            // 刻意不加 FLAG_NOT_FOCUSABLE：面板里要能输入文字、弹时间选择器。
            // 也刻意不加 FLAG_NOT_TOUCHABLE：Dart 侧自己画遮罩并处理"点遮罩收起"。
            // 也刻意**不加 FLAG_LAYOUT_NO_LIMITS**：它会把窗口撑到屏幕外并让 insets 归零，
            // 而 Dart 侧是靠 MediaQuery.padding.top/bottom 做安全区留白的（面板会被顶到
            // 状态栏/导航栏底下）。保留 FLAG_LAYOUT_IN_SCREEN 就能拿到正常 inset。
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }

    private fun updatePanelLayout() {
        val view = panelView ?: return
        val params = panelParams ?: return
        try {
            windowManager?.updateViewLayout(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "panel updateViewLayout failed: ${t.message}")
        }
    }

    // ------------------------------------------------------- gtd/overlay 方法通道

    private fun handleOverlayCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            // Dart 只要回了任何一次调用，就说明它在监听：取消"状态没收到"的补发，
            // 同时放行 entrypoint 探测（第一次调用就是 notifyReady）。
            overlayLaunchLatch?.countDown()
            markStateAcknowledged()
            when (call.method) {
                "notifyReady" -> {
                    overlayReady = true
                    result.success(true)
                    sendStateWhenDartIsListening()
                }
                "collapse" -> {
                    collapsePanel(notifyDart = true)
                    result.success(true)
                }
                "expand" -> {
                    expandPanel()
                    result.success(true)
                }
                "setDockSide" -> {
                    // 缺参时保持现状，不要默认成"贴左"——那会把用户的把手挪到另一边。
                    val right = call.argument<Boolean>("dockedRight")
                    if (right != null) setDockSide(right) else notifyOverlayState()
                    result.success(true)
                }
                "openApp" -> {
                    val target = call.argument<String>("target") ?: ""
                    val routineId = call.argument<String>("routineId")
                    result.success(openApp(target, routineId))
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "overlay method ${call.method} failed: ${t.message}", t)
            result.success(false)
        }
    }

    /**
     * 面板里点"进入应用"才走这里（v1.6 唯一会 startActivity 的正常路径）。
     *
     * `target == "settings"` → `EXTRA_OPEN_SETTINGS=true`；
     * `routineId != null` → `EXTRA_FOCUS_ROUTINE_ID=<id>`（可同时带上，顺序无关）。
     * 拉起后收起面板。
     */
    private fun openApp(target: String, routineId: String?): Boolean = try {
        collapsePanel(notifyDart = true)
        startActivity(
            Intent(applicationContext, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (target == "settings") putExtra(MainActivity.EXTRA_OPEN_SETTINGS, true)
                if (!routineId.isNullOrEmpty()) {
                    putExtra(MainActivity.EXTRA_FOCUS_ROUTINE_ID, routineId)
                }
            }
        )
        Log.i(TAG, "overlay openApp target=$target routineId=$routineId")
        true
    } catch (t: Throwable) {
        Log.w(TAG, "overlay openApp failed: ${t.message}", t)
        false
    }

    /** 面板贴哪一侧（Dart 侧按此排版）；同时把把手挪到同侧。 */
    private fun setDockSide(right: Boolean) {
        dockedRight = right
        prefs?.edit()?.putBoolean(KEY_DOCKED_RIGHT, right)?.apply()
        val view = handleView
        val params = layoutParams
        val wm = windowManager
        if (view != null && params != null && wm != null) {
            params.x = edgeX(wm)
            params.y = clampY(params.y)
            updateView(view, params)
            persistPosition(params.y)
        }
        notifyOverlayState()
    }

    /** 当前状态快照（与契约字段名一致）。 */
    private fun currentState(): Map<String, Any?> = mapOf(
        "expanded" to panelExpanded,
        "dockedRight" to dockedRight,
    )

    /**
     * `notifyReady` 之后立即发一次状态。
     *
     * 直投 MethodChannel 是异步的：没有 Dart 侧 handler 时 `invokeMethod` 会静默失败
     * （MissingPluginException 不会回抛给调用方），所以这里附加一个 3s 超时兜底——
     * 若 Dart 从未调 `drainEvents`/`expand`（即没在监听），就再发一次，避免状态丢失。
     */
    private fun sendStateWhenDartIsListening() {
        notifyOverlayState()
        stateAcknowledged = false
        readyTimeout?.let { mainHandler.removeCallbacks(it) }
        val retry = Runnable {
            if (!stateAcknowledged) {
                Log.i(TAG, "overlay state not acked, resending once")
                notifyOverlayState()
            }
        }
        readyTimeout = retry
        mainHandler.postDelayed(retry, READY_ACK_TIMEOUT_MS)
    }

    private fun markStateAcknowledged() {
        if (stateAcknowledged) return
        stateAcknowledged = true
        readyTimeout?.let { mainHandler.removeCallbacks(it) }
        readyTimeout = null
    }

    /** 主动向 Dart 广播状态（展开/收起/换边/初始）。 */
    private fun notifyOverlayState() {
        if (!overlayReady) return
        try {
            overlayChannel?.invokeMethod("state", currentState())
        } catch (t: Throwable) {
            Log.w(TAG, "overlay state delivery failed: ${t.message}")
        }
    }

    // ------------------------------------------------------------------ 几何

    private fun screenWidth(wm: WindowManager): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            wm.currentWindowMetrics.bounds.width()
        } else {
            @Suppress("DEPRECATION")
            resources.displayMetrics.widthPixels
        }

    private fun screenHeight(wm: WindowManager): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            wm.currentWindowMetrics.bounds.height()
        } else {
            @Suppress("DEPRECATION")
            resources.displayMetrics.heightPixels
        }

    /** 手柄宽度的像素值。 */
    private fun handleWidthPx(): Int = (HANDLE_WIDTH_DP * density).toInt()

    private fun handleHeightPx(): Int = (HANDLE_HEIGHT_DP * density).toInt()

    /** 贴边位置：右停靠 = 屏幕宽 − 手柄宽；左停靠 = 0。 */
    private fun edgeX(wm: WindowManager): Int =
        if (dockedRight) max(0, screenWidth(wm) - handleWidthPx()) else 0

    /** 上次落盘的 y（首次 = 屏幕竖向居中）。 */
    private fun restoredY(wm: WindowManager): Int {
        val saved = prefs?.getInt(KEY_Y, -1) ?: -1
        val y = if (saved >= 0) saved else max(0, (screenHeight(wm) - handleHeightPx()) / 2)
        return clampY(y)
    }

    private fun clampY(y: Int): Int {
        val wm = windowManager ?: return max(0, y)
        // 底部留一点余量，避免手柄卡在导航栏下面抠不出来。
        val bottom = max(0, screenHeight(wm) - handleHeightPx() - (24 * density).toInt())
        return min(max(0, y), bottom)
    }

    private fun persistPosition(y: Int) {
        prefs?.edit()?.putInt(KEY_Y, y)?.apply()
    }

    private fun updateView(view: View, params: WindowManager.LayoutParams) {
        try {
            windowManager?.updateViewLayout(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "updateViewLayout failed: ${t.message}")
        }
    }
}
