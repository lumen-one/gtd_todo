package com.example.gtd_todo

import android.content.Intent
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 唯一的 Activity：Flutter 宿主 + 原生适配器的入口。
 *
 * - [configureFlutterEngine] 里挂上 `gtd/native` / `gtd/native/events` 两条通道；
 * - onCreate / onNewIntent 解析 intent 里的 focusTaskId / openPanel / openSettings /
 *   focusRoutineId，转成 Dart 事件；
 * - 通过 [NativeBridge.activeInstance] 让闹钟与通知按钮接收器能找到活着的通道。
 * - onResume/onPause 通知 [OverlayHandleService] 本应用进退前台（前台时收起
 *   系统级面板并隐藏把手，交给应用内把手）。
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val EXTRA_FOCUS_TASK_ID = "focusTaskId"
        const val EXTRA_OPEN_PANEL = "openPanel"

        /** 由悬浮面板的 `openApp{target="settings"}` 带进来：直接落到设置页。 */
        const val EXTRA_OPEN_SETTINGS = "openSettings"

        /** 由悬浮面板的 `openApp{routineId=…}` 带进来：落到该日程。 */
        const val EXTRA_FOCUS_ROUTINE_ID = "focusRoutineId"

        private const val TAG = "gtd"
    }

    private var bridge: NativeBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 冷启动：先建 bridge（可能给 pending 队列补投），再消费 intent。
        ensureBridge()?.onActivityIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val b = NativeBridge(this, flutterEngine)
        b.attach()
        bridge = b
        // attach 之后 Dart 才会真正连上；把冷启动 intent 存起来，等 notifyReady 补投。
        b.onActivityIntent(intent)
        Log.i(TAG, "configureFlutterEngine: channels registered")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ensureBridge()?.onActivityIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // 应用在前台 = 有应用内把手：把系统级把手收起来，别盖在自己的界面上。
        OverlayHandleService.notifyHostForeground(this, true)
    }

    override fun onPause() {
        // 离开前台（切到别的 App / 回桌面）= 系统级把手重新贴边显示。
        OverlayHandleService.notifyHostForeground(this, false)
        super.onPause()
    }

    override fun onDestroy() {
        bridge?.detach()
        bridge = null
        super.onDestroy()
    }

    /** onCreate 早于 configureFlutterEngine，这里只保证有一个可用的 bridge 实例。 */
    private fun ensureBridge(): NativeBridge? {
        bridge?.let { return it }
        return NativeBridge.activeInstance
    }
}
