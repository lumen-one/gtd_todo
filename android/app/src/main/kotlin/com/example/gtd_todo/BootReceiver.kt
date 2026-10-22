package com.example.gtd_todo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 系统重启 / 应用更新后把手服务的恢复点。
 *
 * 开机时系统会清掉所有前台服务与悬浮窗口；用户此前明确开过把手（原生 prefs 的
 * `enabled` 标记），就替他把服务拉回来，没开过则一概不碰——不因为一次重启凭空
 * 弹出一个悬浮窗。
 *
 * **不重挂闹钟**：下一站要 Dart 侧算时序，而主引擎只在打开应用时才有；这条代价
 * 登记在 architecture.md §11，不在这里假装解决。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> Unit
            else -> return
        }
        if (!OverlayHandleService.isEnabled(context)) return
        Log.i("gtd", "boot receiver: restoring overlay handle")
        OverlayHandleService.restore(context)
    }
}
