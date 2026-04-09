package com.example.android_remote_control

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 服务重启广播接收器
 * 用于在服务被系统杀死后自动重启
 */
class ServiceRestartReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "ServiceRestartReceiver"
        
        /**
         * 重启服务的Action
         */
        const val ACTION_RESTART_SERVICE = "com.example.android_remote_control.RESTART_SERVICE"
    }
    
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.d(TAG, "onReceive: action=$action")
        
        when (action) {
            ACTION_RESTART_SERVICE,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                // 检查服务是否已经在运行
                if (RemoteControlService.instance == null) {
                    Log.d(TAG, "Service is not running, attempting to restart...")
                    restartService(context)
                } else {
                    Log.d(TAG, "Service is already running, no need to restart")
                }
            }
        }
    }
    
    /**
     * 重启RemoteControlService
     */
    private fun restartService(context: Context) {
        try {
            val serviceIntent = Intent(context, RemoteControlService::class.java).apply {
                action = "RESTART_FROM_BROADCAST"
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
                Log.d(TAG, "Foreground service restart requested (Android O+)")
            } else {
                context.startService(serviceIntent)
                Log.d(TAG, "Service restart requested")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart service", e)
        }
    }
}
