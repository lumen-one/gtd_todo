package com.lumenone.qixing

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
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
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
 * - **朝屏内拖动把手 = 跟手拉开**（ui-interaction.md §6.0）：把手跟着手指横移，
 *   面板窗口就地挂上、Dart 侧露多少跟多少；松手拖过 [PULL_OPEN_DP]（或快甩过
 *   [FLING_THRESHOLD_DP]）补满全开，否则滑回屏外。引擎 / Dart 还没就绪时降级为
 *   "只有把手跟手"，松手仍走 [expandPanel] 老路；
 * - **点按什么都不做**（v1.21 / §6.0）：原先"点按 → [expandPanel] 直接全开"已删
 *   （它同时是 ROM 不认手势排除区时的兜底入口，删除的代价登记在文档里）。展开
 *   只剩拖动一条路；引擎或视图创建失败时 [expandPanel] 仍会回退到
 *   `startActivity(MainActivity, openPanel=true)`，保证永远有可用入口；
 * - 展开时把手隐藏，收起后按宿主前后台状态决定是否重新显示；
 * - 宿主在前台（[notifyHostForeground] true）→ 收起面板 + 隐藏把手（有应用内把手）；
 * - [setEnabled] false → 销毁引擎、移除面板与把手、停服务；
 * - 手柄只竖向移动（**位置可上锁**：[setLocked] true 时拖不动 y）、贴边停靠、
 *   位置持久化（v1.5 行为保持不变）。
 *
 * 所有 WindowManager / 引擎操作都吞异常：用户中途撤销悬浮窗权限或引擎起不来时
 * 只降级或停服务，绝不让进程崩掉。
 */
class OverlayHandleService : Service() {

    companion object {
        const val ACTION_START = "com.lumenone.qixing.action.OVERLAY_START"
        const val ACTION_STOP = "com.lumenone.qixing.action.OVERLAY_STOP"
        const val ACTION_HOST_FOREGROUND =
            "com.lumenone.qixing.action.OVERLAY_HOST_FOREGROUND"
        const val ACTION_HOST_BACKGROUND =
            "com.lumenone.qixing.action.OVERLAY_HOST_BACKGROUND"

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
         * 把手位置是否**上锁**（v1.11 / ui-interaction.md §6.0）。
         *
         * true = 竖向拖动不再改变 y，把手钉在当前高度；长按换左右边、横拖拉开都照旧
         * （点按本就不是入口）。锁定意图存在 `settings.json` 的 `handle_locked`（UI 层的用户
         * 设置），这里只是执行侧的一份镜像：原生自己管把手位置，服务可能被拉起时
         * Dart 还没起来，不能依赖通道补投。
         */
        private const val KEY_LOCKED = "locked"

        /**
         * 热区宽度（dp）：`settings.json` 的 `handle_hot_width` 在原生侧的一份镜像。
         *
         * 同 [KEY_LOCKED] 的理由：原生自己管把手窗口，服务被拉起时 Dart 可能还没
         * 起来，不能依赖通道补投。
         */
        private const val KEY_HOT_WIDTH = "hot_width"

        /**
         * **可见**白条的尺寸（dp）：**贴在边缘的一段半透明白条**（v1.10 / 决议 40，
         * v1.11 再缩一档）。
         *
         * 沿革：26×72 的橙色圆角块 → 10×88 的白色细条 → 现在 6×72。故意做窄做淡——
         * 日常它就该是"几乎看不见"的，只在用户主动去找时才注意到。**它能缩到这么小，
         * 靠的是下面那块热区**：抓握精度由热区宽（设置项，见
         * [HOT_ZONE_WIDTH_DEFAULT_DP]）/ [HOT_ZONE_HEIGHT_DP]
         * 承担，白条只负责"让人知道它在哪"。
         */
        private const val BAR_WIDTH_DP = 6
        private const val BAR_HEIGHT_DP = 72

        /**
         * **热区**（可起手的触摸窗口，dp）：窗口本身这么大，白条只是里面贴边居中的一条。
         *
         * 高度取 200 是硬上限：系统"每边最多兑现 200dp 的返回手势排除"，再多不认
         * （超出部分会被丢回给系统返回手势）。**竖向不开放调节**——调小只是自损
         * 竖拖起手的容错。
         *
         * 宽度是**设置项**（`settings.json` 的 `handle_hot_width`，三档
         * 8 / 12 / 20；与 Dart 侧 `handleHotWidthOptions` 一一对应）：热区是
         * overlay 窗口，它盖住的触摸归把手，底下 App 收不到，而这层做不到
         * "点按透过、拖动照旧"（Android 按**手势**挑窗口：一次 DOWN…UP 要么整个
         * 归把手、要么整个归底下的 App），能调的只有面积。原先写死 28dp，
         * v1.21 起默认 12dp 并交成设置项。
         */
        private const val HOT_ZONE_WIDTH_MIN_DP = 8
        private const val HOT_ZONE_WIDTH_DEFAULT_DP = 12
        private const val HOT_ZONE_WIDTH_MAX_DP = 20
        private const val HOT_ZONE_HEIGHT_DP = 200

        /** 白条的不透明度（0–255 的 alpha）：35% ≈ 89。 */
        private const val BAR_ALPHA = 89

        /** 白条的描边：极淡，只为压在浅色壁纸上时不至于整条消失。 */
        private const val BAR_STROKE = "#14000000"

        /**
         * 长按的靶 = **白条外扩这么多 dp**（不是整块热区）。
         *
         * 热区放大是为了"拖动起手不必精准"，但"随手一摁就触发"若也跟着占满整块
         * 热区，用户在别的 App 边缘一碰就会中招。白条只有 6dp 宽，直接当靶太薄，
         * 于是外扩 10dp 凑出一个 26×92dp 的靶——比热区小一个数量级，又够手指摁。
         * v1.21 起这个靶只服务于**长按**（换边），点按已无靶。
         */
        private const val BAR_TAP_PADDING_DP = 10

        /** 判定为"拖拽"的最小位移（px），低于它算点击。 */
        private const val TOUCH_SLOP_DP = 6

        /** 向屏幕中心划动多少像素算作"打开"。 */
        private const val FLING_THRESHOLD_DP = 24

        /**
         * 跟手拉开时，松手算"展开"的最小拖动距离（dp）——ui-interaction.md §6.0
         * 的 72dp。快甩另算（见 [FLING_VELOCITY]），不必拖这么远。
         */
        private const val PULL_OPEN_DP = 72

        /** 把手横移上限（占屏宽的比例）：**分岔点**，不是终点（§6.8）。 */
        private const val PULL_MAX_FRACTION = 0.45f

        /**
         * 拖过分岔点后判方向的阈值（dp）：竖向偏移要过这么大、且大于横向超出量的
         * [QUICK_TURN_RATIO] 倍，才算"拐弯"——进快记态（ui-interaction.md §6.8）。
         *
         * 两个条件缺一不可：只看竖向偏移会把"斜着往屏内拖"误判成拐弯；
         * 只看比例会在横向几乎不动时被手指抖动触发。
         */
        private const val QUICK_TURN_DP = 24
        private const val QUICK_TURN_RATIO = 0.8f

        /** 快记方块（dp）：边长，以及方块中心相对指尖的竖向抬升（免得被手指盖住）。 */
        private const val QUICK_BOX_DP = 52
        private const val QUICK_BOX_LIFT_DP = 28

        /**
         * 快记态窗口边长（dp）：比方块大一圈，**让指尖始终落在窗口内**。
         *
         * 窗口缩小到方块大小的话，指尖（方块下沿之外）就压在窗口外了；系统对
         * "拖动中窗口缩小"的处理各家不一，轻则不再投递 MOVE，重则直接 cancel。
         * 留出 34dp 的余量最省事——透明区域的触摸本来就归这次按住的拖动。
         */
        private const val QUICK_ZONE_DP = 120

        /** 快甩判"展开"的横向速度（逻辑像素/秒，与应用内壳把手同口径）。 */
        private const val FLING_VELOCITY = 500f

        /** 滑回后等 Dart 来摘面板窗口的上限（ms）；超时就自己收，防窗口常驻。 */
        private const val PULL_CLOSE_FALLBACK_MS = 400L

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

        /**
         * 系统重启 / 应用更新后的恢复点（[BootReceiver]）：用户开过才拉起来，没开过不碰。
         *
         * 与 [setEnabled] 的区别是**不写标记、不回报**——这是系统替用户重放一次他已做过
         * 的选择，没做成也只是一次开机，不值得在他眼前报错。悬浮窗权限在此期间被撤销时
         * 顺手清掉标记，免得以后每次开机都白试一次。
         */
        fun restore(context: Context) {
            val app = context.applicationContext
            if (!isEnabled(app)) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !canDrawOverlays(app)) {
                Log.w(TAG, "overlay restore skipped: permission lost")
                prefs(app).edit().putBoolean(KEY_ENABLED, false).apply()
                return
            }
            try {
                val intent = Intent(app, OverlayHandleService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    app.startForegroundService(intent)
                } else {
                    app.startService(intent)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "overlay restore failed: ${t.message}", t)
            }
        }

        /**
         * 把手位置上锁/解锁（[NativeBridge] 转 settings.json 的 `handle_locked`）。
         *
         * 服务活着就直接改内存里的标志（同进程，主线程 post）；没活着也没关系——
         * 值已落 prefs，下次 onCreate 会读到。
         */
        fun setLocked(context: Context, locked: Boolean) {
            val app = context.applicationContext
            prefs(app).edit().putBoolean(KEY_LOCKED, locked).apply()
            instance?.applyLocked(locked)
        }

        /**
         * 热区宽度（[NativeBridge] 转 settings.json 的 `handle_hot_width`）。
         *
         * 服务活着就直接改窗口宽度（手势排除区跟着重声明一次）；没活着也没关系——
         * 值已落 prefs，下次 onCreate 会读到。
         */
        fun setHotZoneWidth(context: Context, dp: Int) {
            val app = context.applicationContext
            val width = dp.coerceIn(HOT_ZONE_WIDTH_MIN_DP, HOT_ZONE_WIDTH_MAX_DP)
            prefs(app).edit().putInt(KEY_HOT_WIDTH, width).apply()
            instance?.applyHotZoneWidth(width)
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

    /** 把手（v1.5 行为保持不变）的**根视图 = 透明热区**，触摸挂它上面。 */
    private var handleView: View? = null

    /** 热区里那条可见白条（换边时要挪它到另一侧的边）。 */
    private var barView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** 面板（v1.6 新增）：第二个引擎的 FlutterView + 全屏透明窗口。 */
    private var panelView: FlutterView? = null
    private var panelParams: WindowManager.LayoutParams? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** true = 贴右边；false = 贴左边。默认右边。 */
    private var dockedRight = true

    /** 本应用是否在前台（在前台时把手隐藏，避免盖住自己的界面）。 */
    private var hostForeground = false

    /** 把手竖向位置是否上锁（[KEY_LOCKED]）：锁上时拖拽不再改 y。 */
    private var handleLocked = false

    /**
     * 热区宽度（dp，[KEY_HOT_WIDTH]）：设置项（`handle_hot_width`），
     * 两处把手共用同一个值。窗口宽度与手势排除区都由它算。
     */
    private var hotZoneWidthDp = HOT_ZONE_WIDTH_DEFAULT_DP

    /** 面板是否展开（展开时把手隐藏，二次展开不重复挂窗口）。 */
    private var panelExpanded = false

    // ------------------------------------------------------- 跟手拉开（§6.0）

    /** "拉开"手势进行中：朝屏内横拖把手，侧边栏跟手滑出。 */
    private var pulling = false

    /** 面板窗口已挂上、Dart 在跟手渲染；false = 只有把手跟手（引擎没就绪的首轮）。 */
    private var pullTracking = false

    /** 当前朝屏内的拖动距离（px，≥0）。 */
    private var pullDx = 0f

    // ------------------------------------------------------- 快记（§6.8）

    /** 已过 [PULL_MAX_FRACTION] 分岔点（本次手势内）。 */
    private var pastSplit = false

    /** 过了分岔点、判为"想要面板"：上限放宽到面板宽（本次手势内不回收）。 */
    private var pastSplitPanel = false

    /** 快记态：把手窗口已变成跟手方块。 */
    private var quickNote = false

    /** 输入条占着面板窗口期间把手保持隐藏；收起（collapse）后恢复。 */
    private var quickNoteShowing = false

    /** 方块视图：热区里那块 52dp 的圆角白方块（默认 GONE，只在快记态显示）。 */
    private var quickBoxView: View? = null

    /**
     * Dart 上报的面板宽（逻辑像素，`panelWidth` 上行）。
     *
     * 原生不知道 `settings.panel_width`，但"继续拖到面板宽"这条上限要用它；
     * 0 = 还没报过 → 按默认公式 min(0.8 × 屏宽, 360dp) 估。
     */
    private var panelWidthDp = 0f

    /** 松手判快甩用的速度跟踪（一次手势一个：DOWN obtain、UP 回收）。 */
    private var velocityTracker: VelocityTracker? = null

    /** 滑回后 Dart 没来摘窗口的兜底（引擎挂了等）。 */
    private val pullCloseFallback = Runnable {
        if (!panelExpanded && panelView != null) collapsePanel(notifyDart = false)
    }

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
            handleLocked = it.getBoolean(KEY_LOCKED, false)
            hotZoneWidthDp = it.getInt(KEY_HOT_WIDTH, HOT_ZONE_WIDTH_DEFAULT_DP)
                .coerceIn(HOT_ZONE_WIDTH_MIN_DP, HOT_ZONE_WIDTH_MAX_DP)
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
        // 快记态下手势被打断（窗口正跟着指尖走），直接退回把手，按上次落盘的高度落位。
        windowManager?.let { wm ->
            if (quickNote) exitQuickNote(restoredY(wm).toFloat(), notifyDart = true)
        }
        relayout()
        // 面板窗口参数与屏幕尺寸无关（MATCH_PARENT），但保险起见重新贴一次。
        if (panelExpanded) {
            updatePanelLayout()
            // 把手的 y 刚被重新夹紧：重广播状态，Dart 侧的面板锚点跟着更新。
            notifyOverlayState()
        }
    }

    /**
     * 从最近任务划掉卡片。`stopWithTask=false` 已经挡住系统的默认停止，这里只做两件
     * 收尾：**把手必须露出来**（Activity 没了，若 `hostForeground` 停在 true，把手会被
     * [applyVisibility] 一直藏着），以及视图丢了就补一个（[addHandle] 幂等）。
     *
     * 不碰面板与引擎：用户划掉的是应用，不是把手。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        setHostForeground(false)
        addHandle()
        super.onTaskRemoved(rootIntent)
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

        // 白条：热区里唯一可见的东西（不放任何子 View，见 handleBackground 的说明）。
        val bar = View(this).apply {
            background = handleBackground()
            elevation = 4f * density
        }
        // 根视图是整块透明的热区：能起手的面积远大于白条，用户不必精确摁到那条线上。
        // 代价写在这里：热区盖住的触摸归把手，底下的 App 收不到。
        //
        // 快记方块（§6.8）是同一窗口里的第二个子 View（默认 GONE）：进快记态时白条
        // 让位、窗口缩成 52dp 跟手指走——不新开窗口，也就没有通道延迟。
        val box = buildQuickBox()
        val view = FrameLayout(this).apply {
            setBackgroundColor(Color.TRANSPARENT)
            addView(bar, barLayoutParams())
            addView(box, quickBoxLayoutParams())
        }

        val params = WindowManager.LayoutParams(
            hotZoneWidthPx(),
            hotZoneHeightPx(),
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
        barView = bar
        quickBoxView = box
        layoutParams = params
        try {
            wm.addView(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "addView failed: ${t.message}", t)
            handleView = null
            barView = null
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
        barView = null
        quickBoxView = null
        layoutParams = null
        quickNote = false
        quickNoteShowing = false
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
        val hide = hostForeground || panelExpanded || quickNote || quickNoteShowing
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
        // 进前台要收起面板；快记（方块态或输入条）同样不能留着——用户已经进应用了。
        if (foreground && (panelExpanded || quickNote || quickNoteShowing)) {
            collapsePanel(notifyDart = true)
        }
        applyVisibility()
        if (!foreground) {
            // 退到后台就预热第二个引擎：用户接下来多半要拉把手，而跟手拉开要求
            // 面板窗口在拖动中就已经挂上、Dart 已在渲染（§6.0）。引擎此后常驻，
            // 与"首次展开后本就常驻"相比只差在早晚。
            mainHandler.post { ensureOverlayEngine() }
        }
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
     * 白条的底色（v1.10 / 决议 40，v1.11 再淡一档）：带一层极淡描边，压在浅色壁纸上
     * 也不至于消失。
     *
     * 刻意**不跟随主题预设**：它浮在别人的 App、别人的壁纸上，"在哪都看得见"这一层
     * 保证比配色一致重要（理由同 ui-interaction.md §17C）。
     */
    private fun handleBackground(): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        // 圆角 = 宽度的一半 → 一条胶囊状竖条，而不是一块方板。
        cornerRadius = (BAR_WIDTH_DP / 2f) * density
        setColor(Color.argb(BAR_ALPHA, 255, 255, 255))
        setStroke(1, Color.parseColor(BAR_STROKE))
    }

    /** 白条在热区里的位置：竖直居中 + 贴在**屏幕边缘**那一侧（换边时跟着挪）。 */
    private fun barGravity(): Int =
        Gravity.CENTER_VERTICAL or (if (dockedRight) Gravity.END else Gravity.START)

    private fun barLayoutParams(): FrameLayout.LayoutParams =
        FrameLayout.LayoutParams(barWidthPx(), barHeightPx(), barGravity())

    /** 换边 / 停靠侧变化后把白条挪到新的那一侧。 */
    private fun applyBarGravity() {
        val bar = barView ?: return
        val lp = bar.layoutParams as? FrameLayout.LayoutParams ?: return
        lp.gravity = barGravity()
        bar.layoutParams = lp // 重新赋值才会触发 requestLayout
    }

    /**
     * 点按/长按是否落在**白条的靶**上（白条外扩 [BAR_TAP_PADDING_DP]）。
     *
     * @param x 视图自身坐标系的横坐标（`MotionEvent.x`），不是屏幕坐标。
     */
    private fun isOnBar(v: View, x: Float, y: Float): Boolean {
        val w = v.width
        val h = v.height
        if (w <= 0 || h <= 0) return false
        val pad = BAR_TAP_PADDING_DP * density
        val left = (if (dockedRight) w - barWidthPx() else 0).toFloat()
        val top = (h - barHeightPx()) / 2f
        return x >= left - pad && x <= left + barWidthPx() + pad &&
            y >= top - pad && y <= top + barHeightPx() + pad
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
     * 声明的是**整块热区**（宽 = 设置项 `handle_hot_width`，默认 12dp；高 200dp），
     * 不是那条白条——用户正是从热区里起手的。200dp 是系统"每边最多兑现 200dp 排除"
     * 的配额上限，正好用满：再多系统不认，超出的部分会被丢回给返回手势。宽度收窄
     * 时系统会少扣一条边，这也是把宽度交成设置项的附带好处。
     *
     * 面板是**全屏**窗口，**不给**它声明——
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

        view.setOnTouchListener(object : View.OnTouchListener {
            private var startY = 0f
            private var downX = 0f
            private var downY = 0f
            private var dragging = false
            private var longPressed = false

            /**
             * 这次 DOWN 是否落在**白条的靶**上（[BAR_TAP_PADDING_DP] 外扩范围内）。
             *
             * 只有它是 true 才认**长按**（换边）——热区是给"拖动起手"用的，不是给
             * 点按用的；点按自 v1.21 起什么都不做（§6.0）。
             */
            private var downOnBar = false

            /**
             * 过 [PULL_MAX_FRACTION] 分岔点那一刻的竖向偏移：拐弯判定的**基线**（§6.8）。
             *
             * 用"相对基线的增量"而不是绝对 dy：取消快记、退回面板跟手之后，手指
             * 仍在原来的高度上，用绝对 dy 会立刻再次判定、来回跳；用增量则必须
             * 从取消点再拐 24dp 才会重进。
             */
            private var splitDy = 0f

            private val longPressRunnable = Runnable {
                longPressed = true
                toggleDock()
            }

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                val params = layoutParams ?: return false
                val wm = windowManager
                velocityTracker?.addMovement(event)
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        startY = params.y.toFloat()
                        downX = event.rawX
                        downY = event.rawY
                        dragging = false
                        longPressed = false
                        pastSplit = false
                        pastSplitPanel = false
                        splitDy = 0f
                        // event.x/y 是**视图自身坐标系**：白条在热区里的位置按它算。
                        downOnBar = isOnBar(v, event.x, event.y)
                        velocityTracker?.recycle()
                        velocityTracker = VelocityTracker.obtain()
                        // 长按（换边）的靶是白条：热区里随手摁一下不该换边。
                        if (downOnBar) mainHandler.postDelayed(longPressRunnable, 500L)
                        return true
                    }

                    MotionEvent.ACTION_MOVE -> {
                        val dx = event.rawX - downX
                        val dy = event.rawY - downY
                        if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                            dragging = true
                            mainHandler.removeCallbacks(longPressRunnable)
                        }
                        // 朝屏内的横拖 = "拉开"（跟手滑出）；竖拖仍然是移把手。
                        if (dragging && !pulling && isOpenGesture(dx, dy, slop)) {
                            startPull()
                        }
                        if (pulling) {
                            val inward = if (dockedRight) -dx else dx
                            if (quickNote) {
                                // 方块跟指尖（二维）：进入时已经在窗口上设好尺寸。
                                moveQuickBox(wm, event.rawX, event.rawY)
                                if (inward >= pullSplitPx(wm).toFloat()) return true
                                // 回拖到分岔点以内 = 取消：方块缩回白条、面板恢复跟手。
                                exitQuickNote(startY, notifyDart = true)
                                splitDy = dy
                            }
                            // 过 0.45 分岔点后才判方向（§6.8）：拐离水平 = 快记；
                            // 继续近似水平 = 想要面板，上限放宽到面板宽。
                            if (!pastSplit && inward >= pullSplitPx(wm).toFloat()) {
                                pastSplit = true
                                splitDy = dy
                            }
                            if (pastSplit) {
                                val split = pullSplitPx(wm).toFloat()
                                val limit = if (pastSplitPanel) {
                                    max(split, panelWidthPx(wm).toFloat())
                                } else {
                                    split
                                }
                                // 横向"还在推进的量"：没顶死时算过分岔点之后的增量
                                // （横着走得多就不算拐弯）；顶死后只剩空推量 ≈ 0。
                                val horizontal = if (inward < limit) {
                                    max(0f, inward - split)
                                } else {
                                    max(0f, inward - limit)
                                }
                                val turn = abs(dy - splitDy)
                                if (turn >= QUICK_TURN_DP * density &&
                                    turn > QUICK_TURN_RATIO * horizontal &&
                                    enterQuickNote(wm, event.rawX, event.rawY)
                                ) {
                                    return true
                                }
                                if (!pastSplitPanel) pastSplitPanel = true
                            }
                            // 把手跟着手指横移（y 冻结：拉开是横手势，面板的
                            // 垂直锚点不跟着晃）。
                            val cap = if (pastSplitPanel) {
                                max(pullSplitPx(wm).toFloat(), panelWidthPx(wm).toFloat())
                            } else {
                                pullSplitPx(wm).toFloat()
                            }
                            pullDx = inward.coerceIn(0f, cap)
                            if (wm != null) {
                                params.x = edgeX(wm) +
                                    (if (dockedRight) -pullDx else pullDx).toInt()
                            }
                            updateView(v, params)
                            if (pullTracking) sendPullProgress()
                            return true
                        }
                        if (dragging && !handleLocked) {
                            // 只竖向移动：x 永远贴边，不会被横向拖动带偏。
                            // 上锁时整段跳过——把手钉在当前高度（长按换边仍可用）。
                            params.y = clampY((startY + dy).toInt())
                            if (wm != null) params.x = edgeX(wm)
                            updateView(v, params)
                        }
                        return true
                    }

                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        mainHandler.removeCallbacks(longPressRunnable)
                        val dx = event.rawX - downX
                        if (quickNote) {
                            // 松手 = 确认记一条：把落点交给 Dart（方块由它接管、飞向
                            // 屏幕中央），原生窗口复原并藏起来，输入条收起前不再露把手。
                            quickNoteShowing = true
                            sendQuickNoteOpen(event.rawX, event.rawY)
                            exitQuickNote(startY, notifyDart = false)
                            pulling = false
                            pullTracking = false
                            dragging = false
                            velocityTracker?.recycle()
                            velocityTracker = null
                            applyVisibility()
                            return true
                        }
                        if (pulling) {
                            // 松手定去留：拖过 72dp / 快甩过 24dp = 展开，否则滑回。
                            endPull(shouldOpenPull(dx) && !longPressed)
                            velocityTracker?.recycle()
                            velocityTracker = null
                            return true
                        }
                        // 松手后回到贴边位置并把 y 夹回屏内（落盘，重启保留）。
                        //
                        // **点按什么都不做**（v1.21 / §6.0）：原先这里有"没移动且落在
                        // 白条靶上 → expandPanel"，是决议 41 的兜底入口（ROM 不认手势
                        // 排除区时仍打得开）。删它的理由：贴边那一竖条是拇指的常驻
                        // 落点，点一下就弹面板既误触，又让底下那一竖条变成"点了也不
                        // 知道点给谁"的死区。代价已登记在 ui-interaction.md §6.0。
                        relayout()
                        velocityTracker?.recycle()
                        velocityTracker = null
                        dragging = false
                        return true
                    }
                }
                return false
            }

            /** 松手时算不算展开：拖过 [PULL_OPEN_DP]，或快甩过 [FLING_THRESHOLD_DP]。 */
            private fun shouldOpenPull(dx: Float): Boolean {
                val inward = if (dockedRight) -dx else dx
                if (inward >= PULL_OPEN_DP * density) return true
                if (inward < FLING_THRESHOLD_DP * density) return false
                val vx = velocityTracker?.xVelocity ?: 0f
                val inwardV = if (dockedRight) -vx else vx
                return inwardV >= FLING_VELOCITY * density
            }
        })
    }

    // ------------------------------------------------------- 跟手拉开（§6.0）

    /**
     * 进入"拉开"态：把手跟着手指横移，面板窗口就地挂上、Dart 侧跟手渲染。
     *
     * 引擎 / Dart 还没就绪（服务刚拉起、用户从没展开过）时只做把手跟手——
     * 松手仍走 [expandPanel] 老路（现场补引擎），不会把用户卡住。
     */
    private fun startPull() {
        pulling = true
        if (!overlayReady) return
        if (!ensureOverlayEngine()) return
        if (!addPanelView()) return
        pullTracking = true
        sendPullProgress()
    }

    /**
     * 松手：补满全开（[open]）或滑回屏外。
     *
     * 滑回时面板窗口还挂着——Dart 播完"滑回屏外"的动画才会调 `collapse` 来摘，
     * 这里挂一个兜底 Runnable，防 Dart 没回复时窗口常驻盖住下面的 App。
     */
    private fun endPull(open: Boolean) {
        val wasTracking = pullTracking
        pulling = false
        pullTracking = false
        // 把手回贴边缘（展开时反正要隐藏）；y 夹紧并落盘。
        relayout()
        if (open) {
            // 面板窗口已在（wasTracking）或现场补（引擎没就绪的首轮）。
            expandPanel()
            if (wasTracking) sendPullEnd(open = true)
        } else if (wasTracking) {
            sendPullEnd(open = false)
            mainHandler.removeCallbacks(pullCloseFallback)
            mainHandler.postDelayed(pullCloseFallback, PULL_CLOSE_FALLBACK_MS)
        }
    }

    /** 拖动进度 → Dart：dx = 手指距贴边位置的逻辑像素（朝屏内为正）。 */
    private fun sendPullProgress() {
        if (!pullTracking) return
        try {
            overlayChannel?.invokeMethod(
                "panelDrag", mapOf("dx" to (pullDx / density).toDouble()))
        } catch (t: Throwable) {
            Log.w(TAG, "panelDrag delivery failed: ${t.message}")
        }
    }

    /** 松手判定 → Dart：open = 补满全开（否则 Dart 滑回屏外后调 collapse）。 */
    private fun sendPullEnd(open: Boolean) {
        try {
            overlayChannel?.invokeMethod("panelDragEnd", mapOf("open" to open))
        } catch (t: Throwable) {
            Log.w(TAG, "panelDragEnd delivery failed: ${t.message}")
        }
    }

    // ------------------------------------------------------------ 快记（§6.8）

    /** 快记方块在窗口里居中：窗口中心 = 方块中心（窗口比方块大一圈，见 [QUICK_ZONE_DP]）。 */
    private fun quickBoxLayoutParams(): FrameLayout.LayoutParams {
        val size = (QUICK_BOX_DP * density).toInt()
        return FrameLayout.LayoutParams(size, size, Gravity.CENTER)
    }

    /**
     * 方块视图：热区窗口里的第二个子 View（默认 GONE）。
     *
     * 白底 + 细描边 + 中心一个加号，是为了在任何壁纸/任何 App 上都看得清，且
     * **不带任何任务文字**——旁边人看到的只是一块空白小方块（§6.8）。
     */
    private fun buildQuickBox(): View {
        val plus = TextView(this).apply {
            text = "+"
            setTextColor(Color.parseColor("#8A000000"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            gravity = Gravity.CENTER
            includeFontPadding = false
        }
        return FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 16f * density
                setColor(Color.argb(246, 255, 255, 255))
                setStroke(max(1, (1 * density).toInt()), Color.parseColor("#33000000"))
            }
            elevation = 10f * density
            addView(
                plus,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
            visibility = View.GONE
        }
    }

    /**
     * 在"热区"与"方块"两种窗口形态之间切换（只改参数，不提交布局）。
     *
     * 尺寸必须跟着改：方块要是 52dp 的方窗口，否则圆角白底会被 12×200 的热区
     * 裁成一条。第一次提交由 [moveQuickBox] 或 [exitQuickNote] 做，避免闪一下旧位置。
     */
    private fun applyQuickBox(on: Boolean) {
        val params = layoutParams ?: return
        val wm = windowManager
        if (on) {
            val zone = (QUICK_ZONE_DP * density).toInt()
            params.width = zone
            params.height = zone
            barView?.visibility = View.GONE
            quickBoxView?.visibility = View.VISIBLE
        } else {
            params.width = hotZoneWidthPx()
            params.height = hotZoneHeightPx()
            if (wm != null) params.x = edgeX(wm)
            barView?.visibility = View.VISIBLE
            quickBoxView?.visibility = View.GONE
        }
    }

    /** 方块跟指尖（二维）：窗口中心抬到指尖上方 [QUICK_BOX_LIFT_DP]，免得被手指盖住。 */
    private fun moveQuickBox(wm: WindowManager?, rawX: Float, rawY: Float) {
        val view = handleView ?: return
        val params = layoutParams ?: return
        val zone = (QUICK_ZONE_DP * density).toInt()
        val half = zone / 2f
        val lift = QUICK_BOX_LIFT_DP * density
        val screenW = wm?.let { screenWidth(it) }
            ?: resources.displayMetrics.widthPixels
        val screenH = wm?.let { screenHeight(it) }
            ?: resources.displayMetrics.heightPixels
        params.width = zone
        params.height = zone
        params.x = (rawX - half).toInt().coerceIn(0, max(0, screenW - zone))
        params.y = (rawY - lift - half).toInt().coerceIn(0, max(0, screenH - zone))
        updateView(view, params)
    }

    /**
     * 进快记态：把手窗口变方块，面板退场（Dart 侧淡出，不摘窗口）。
     *
     * @return false = 第二个引擎没就绪，**不进**快记（手势保持原样，继续当面板拖）——
     *         方块出来了却写不了字比没有这个功能更糟。
     */
    private fun enterQuickNote(wm: WindowManager?, rawX: Float, rawY: Float): Boolean {
        if (!overlayReady) return false
        if (!ensureOverlayEngine()) return false
        if (!addPanelView()) return false
        quickNote = true
        handleView?.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        applyQuickBox(true)
        moveQuickBox(wm, rawX, rawY)
        sendQuickNoteEvent("quickNoteStart")
        return true
    }

    /**
     * 退出快记态：窗口复原成贴边热区，y 回到本次拖动前的高度。
     *
     * @param notifyDart true = 回拖取消（面板恢复跟手）；false = 松手进输入条
     *                   （由 [quickNoteShowing] 接手隐藏把手）。
     */
    private fun exitQuickNote(restoreY: Float, notifyDart: Boolean) {
        val was = quickNote
        quickNote = false
        applyQuickBox(false)
        val view = handleView
        val params = layoutParams
        val wm = windowManager
        if (view != null && params != null && wm != null) {
            params.x = edgeX(wm)
            params.y = clampY(restoreY.toInt())
            updateView(view, params)
            persistPosition(params.y)
        }
        // 取消必须在复原之后发：Dart 收到后会按跟手进度重新画面板，那时
        // 面板窗口已经就位，不会停在 opacity 0 上。
        if (was && notifyDart) sendQuickNoteEvent("quickNoteCancel")
        applyVisibility()
    }

    /** 原生 → Dart：快记态的开始 / 取消（`quickNoteOpen` 另走 [sendQuickNoteOpen]）。 */
    private fun sendQuickNoteEvent(method: String) {
        try {
            overlayChannel?.invokeMethod(method, null)
        } catch (t: Throwable) {
            Log.w(TAG, "$method delivery failed: ${t.message}")
        }
    }

    /** 松手：把落点（逻辑像素）交给 Dart，方块由它接管飞向屏幕中央。 */
    private fun sendQuickNoteOpen(rawX: Float, rawY: Float) {
        try {
            overlayChannel?.invokeMethod(
                "quickNoteOpen",
                mapOf(
                    "x" to (rawX / density).toDouble(),
                    "y" to (rawY / density).toDouble(),
                ),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "quickNoteOpen delivery failed: ${t.message}")
        }
    }

    /**
     * **分岔点**：把手横移到屏宽的 0.45 倍（贴右 = 往左、贴左 = 往右）。
     *
     * 原先它就是横移上限；v1.23 起变成"判方向"的点——过线之后继续近似水平走会把
     * 上限放宽到面板宽（[panelWidthPx]），拐离水平则进快记（ui-interaction.md §6.8）。
     * 保留 0.45 是因为它是"正常拉开"与"第二档"之间唯一稳定的分界，再往上挪会把
     * 面板全开前的每一帧都变成可判定的区间。
     */
    private fun pullSplitPx(wm: WindowManager?): Int {
        val width = wm?.let { screenWidth(it) }
            ?: resources.displayMetrics.widthPixels
        return (width * PULL_MAX_FRACTION).toInt()
    }

    /**
     * 面板宽（px）：Dart 用 `panelWidth` 上行报过来的 `panel_width`。
     *
     * 没报过（服务刚拉起、Dart 还没起来）时按默认公式 min(0.8 × 屏宽, 360dp) 估，
     * 与 `side_panel.dart` 的 `panelWidthFor` 一致；估偏了只影响"多推一点才顶死"，
     * 不会把面板挡在半开。
     */
    private fun panelWidthPx(wm: WindowManager?): Int {
        val screen = wm?.let { screenWidth(it) }
            ?: resources.displayMetrics.widthPixels
        val dp = if (panelWidthDp > 0f) {
            panelWidthDp
        } else {
            min(screen / density * 0.8f, 360f)
        }
        return (dp * density).toInt().coerceIn(0, max(0, screen - 24))
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
        applyBarGravity()
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
        // 跟手拉开"滑回"走这条路摘窗口：兜底 Runnable 可以退了。
        mainHandler.removeCallbacks(pullCloseFallback)
        if (!panelExpanded && panelView == null) {
            // 窗口本来就不在：也要把快记的"暂隐把手"收回来，否则把手再也不显示。
            quickNoteShowing = false
            quickNote = false
            applyVisibility()
            if (notifyDart) notifyOverlayState()
            return
        }
        panelExpanded = false
        // 输入条收起：把手重新出现（快记态若还挂着也不能留方块）。
        quickNoteShowing = false
        quickNote = false
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
                // 面板宽（逻辑像素）：快记"继续拖到面板宽"那条上限要用它，
                // 原生读不到 settings.json 的 panel_width（§6.8）。
                "panelWidth" -> {
                    val dp = call.argument<Double>("dp")
                    if (dp != null && dp > 0) panelWidthDp = dp.toFloat()
                    result.success(true)
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

    /** 面板贴哪一侧（Dart 侧按此排版）；同时把把手挪到同侧、白条贴到新侧的边缘。 */
    private fun setDockSide(right: Boolean) {
        dockedRight = right
        prefs?.edit()?.putBoolean(KEY_DOCKED_RIGHT, right)?.apply()
        applyBarGravity()
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
        // 原生把手的中心 Y（逻辑像素）：Dart 侧面板垂直居中于它
        // （ui-interaction.md §6.0）。缺失 = Dart 贴顶展开（兼容老版本）。
        "handle_center_y" to handleCenterY(),
    )

    /**
     * 原生把手的中心 Y（**逻辑像素**）。
     *
     * 面板窗口是全屏透明的，与把手同一坐标系；Dart 的 MediaQuery 用逻辑像素，
     * 所以发出去之前除掉 density。把手隐藏（展开中 / 宿主前台）时
     * layoutParams.y 仍是它最后停留的位置——拖动结束与 relayout 都会夹紧并
     * 落盘，所以展开瞬间取到的就是用户摆放的位置。
     */
    private fun handleCenterY(): Double? {
        val params = layoutParams ?: return null
        // 热区中心 = 白条中心（白条在热区里竖直居中）。
        return ((params.y + hotZoneHeightPx() / 2f) / density).toDouble()
    }

    /** 上锁状态变化（[setLocked]）：只改内存标志，位置不动——锁的是"不能再挪"。 */
    private fun applyLocked(locked: Boolean) {
        handleLocked = locked
        Log.i(TAG, "overlay handle locked=$locked")
    }

    /**
     * 热区宽度变化（[setHotZoneWidth]）：改窗口宽度 → 重新贴边 → 重声明排除区
     * （排除区就是热区整块，宽度变了必须重发，否则系统与实际的边对不上）。
     */
    private fun applyHotZoneWidth(widthDp: Int) {
        hotZoneWidthDp = widthDp.coerceIn(HOT_ZONE_WIDTH_MIN_DP, HOT_ZONE_WIDTH_MAX_DP)
        val wm = windowManager ?: return
        val view = handleView ?: return
        val params = layoutParams ?: return
        params.width = hotZoneWidthPx()
        params.x = edgeX(wm)
        updateView(view, params)
        declareGestureExclusion(view)
        Log.i(TAG, "overlay handle hot zone width=${hotZoneWidthDp}dp")
    }

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

    /** 热区宽度的像素值（窗口尺寸 = 可起手的范围）。 */
    private fun hotZoneWidthPx(): Int = (hotZoneWidthDp * density).toInt()

    private fun hotZoneHeightPx(): Int = (HOT_ZONE_HEIGHT_DP * density).toInt()

    /** 可见白条的像素尺寸。 */
    private fun barWidthPx(): Int = (BAR_WIDTH_DP * density).toInt()

    private fun barHeightPx(): Int = (BAR_HEIGHT_DP * density).toInt()

    /** 贴边位置：右停靠 = 屏幕宽 − 热区宽；左停靠 = 0。 */
    private fun edgeX(wm: WindowManager): Int =
        if (dockedRight) max(0, screenWidth(wm) - hotZoneWidthPx()) else 0

    /** 上次落盘的 y（首次 = 屏幕竖向居中）。 */
    private fun restoredY(wm: WindowManager): Int {
        val saved = prefs?.getInt(KEY_Y, -1) ?: -1
        val y = if (saved >= 0) saved else max(0, (screenHeight(wm) - hotZoneHeightPx()) / 2)
        return clampY(y)
    }

    private fun clampY(y: Int): Int {
        val wm = windowManager ?: return max(0, y)
        // 底部留一点余量，避免手柄卡在导航栏下面抠不出来。
        val bottom = max(0, screenHeight(wm) - hotZoneHeightPx() - (24 * density).toInt())
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
