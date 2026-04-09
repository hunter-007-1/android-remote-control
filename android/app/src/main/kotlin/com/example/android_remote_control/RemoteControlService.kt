package com.example.android_remote_control

import android.app.*
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.plugin.common.EventChannel

/**
 * 远程控制服务
 * 用于在后台运行远程控制功能，包括屏幕捕获
 */
class RemoteControlService : Service() {
    private var mediaProjection: MediaProjection? = null
    private var screenCaptureManager: ScreenCaptureManager? = null
    private val windowManager by lazy { getSystemService(Context.WINDOW_SERVICE) as WindowManager }
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var notificationUpdateHandler: Handler? = null
    private var notificationUpdateRunnable: Runnable? = null
    private var framesSentCount = 0
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "remote_control_service"
        var instance: RemoteControlService? = null
            private set
        /**
         * Flutter EventChannel 的 sink 可能在 Service 创建之前就建立监听。
         * 先暂存下来，等 Service onCreate 时再接管，避免屏幕帧永远发不出去。
         */
        var pendingEventSink: EventChannel.EventSink? = null
    }

    override fun onCreate() {
        super.onCreate()
        try {
            android.util.Log.d("RemoteControlService", "onCreate called")
            instance = this
            // 接管 pending sink（如果 Flutter 先 onListen 了）
            if (eventSink == null && pendingEventSink != null) {
                eventSink = pendingEventSink
                android.util.Log.d("RemoteControlService", "Restored pending event sink")
            }
            
            // 创建通知渠道（必须在 startForeground 之前）
            createNotificationChannel()
            
            // 必须在 onCreate 中立即调用 startForeground，否则会抛出异常
            // 这是 Foreground Service 的强制要求
            val notification = createNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ 必须指定 foregroundServiceType
                startForeground(NOTIFICATION_ID, notification, 
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                android.util.Log.d("RemoteControlService", "Foreground service started with type MEDIA_PROJECTION")
            } else {
                startForeground(NOTIFICATION_ID, notification)
                android.util.Log.d("RemoteControlService", "Foreground service started")
            }

            // 申请 PARTIAL_WAKE_LOCK，保证熄屏后 CPU 仍然运行，避免被系统休眠网络/录屏线程
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm != null) {
                    wakeLock = pm.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "AndroidRemoteControl::ScreenCaptureWakeLock"
                    ).apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                    android.util.Log.d("RemoteControlService", "WakeLock acquired for screen capture")
                } else {
                    android.util.Log.w("RemoteControlService", "PowerManager is null, cannot acquire WakeLock")
                }
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Error acquiring WakeLock", e)
            }
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Error in onCreate", e)
            // 即使出错也要尝试启动前台服务，避免服务被立即杀死
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, createNotification(), 
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                } else {
                    startForeground(NOTIFICATION_ID, createNotification())
                }
            } catch (e2: Exception) {
                android.util.Log.e("RemoteControlService", "Failed to start foreground service", e2)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.d("RemoteControlService", "onStartCommand: action=${intent?.action}, startId=$startId")
        when (intent?.action) {
            "RESTART_FROM_BROADCAST" -> {
                android.util.Log.d("RemoteControlService", "Service restarted from broadcast, ensuring foreground state")
                // 确保前台通知已启动
                if (notificationUpdateHandler == null) {
                    startNotificationUpdate()
                }
            }
            "START_CAPTURE" -> {
                val resultCode = intent.getIntExtra("resultCode", -999) // 使用 -999 作为默认值，避免与 RESULT_OK(-1) 混淆
                android.util.Log.d("RemoteControlService", "START_CAPTURE: resultCode=$resultCode (RESULT_OK=${android.app.Activity.RESULT_OK})")
                val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra("data", Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra("data")
                }
                android.util.Log.d("RemoteControlService", "START_CAPTURE: data=${if (data != null) "not null" else "null"}")
                // Activity.RESULT_OK 的值是 -1，所以这里应该检查 resultCode == Activity.RESULT_OK
                if (resultCode == android.app.Activity.RESULT_OK && data != null) {
                    // 获取并验证参数，确保在设备支持的范围内
                    val rawWidth = intent.getIntExtra("width", 1080)
                    val rawHeight = intent.getIntExtra("height", 1920)
                    val rawFrameRate = intent.getIntExtra("frameRate", 30)
                    
                    // 限制参数范围，确保设备支持
                    val width = rawWidth.coerceIn(320, 3840)
                    val height = rawHeight.coerceIn(480, 2160)
                    val frameRate = rawFrameRate.coerceIn(5, 30)
                    
                    // 获取屏幕密度
                    val density = intent.getIntExtra("density", resources.displayMetrics.densityDpi)
                    
                    // 如果参数被调整，记录警告
                    if (width != rawWidth || height != rawHeight || frameRate != rawFrameRate) {
                        android.util.Log.w("RemoteControlService", "Parameters adjusted: width $rawWidth->$width, height $rawHeight->$height, frameRate $rawFrameRate->$frameRate")
                    }
                    
                    android.util.Log.d("RemoteControlService", "Starting capture: ${width}x${height}, density=$density, fps=$frameRate")
                    startScreenCapture(resultCode, data, width, height, density, frameRate)
                } else {
                    android.util.Log.e("RemoteControlService", "START_CAPTURE failed: resultCode=$resultCode (expected ${android.app.Activity.RESULT_OK}), data=${if (data != null) "not null" else "null"}")
                }
            }
            "STOP_CAPTURE" -> {
                android.util.Log.d("RemoteControlService", "STOP_CAPTURE")
                stopScreenCapture()
            }
        }
        return START_STICKY
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        pendingEventSink = sink
    }

    private fun startScreenCapture(
        resultCode: Int, 
        data: Intent, 
        width: Int, 
        height: Int, 
        density: Int, 
        frameRate: Int
    ) {
        try {
            android.util.Log.d("RemoteControlService", "startScreenCapture called: resultCode=$resultCode, width=$width, height=$height, density=$density, frameRate=$frameRate")
            
            // 检查 Service 是否准备好
            if (instance == null) {
                android.util.Log.e("RemoteControlService", "Service instance is null, cannot start capture")
                return
            }
            
            // 检查参数有效性
            if (resultCode != android.app.Activity.RESULT_OK) {
                android.util.Log.e("RemoteControlService", "Invalid resultCode: $resultCode (expected ${android.app.Activity.RESULT_OK})")
                return
            }
            
            if (data == null) {
                android.util.Log.e("RemoteControlService", "Intent data is null")
                return
            }
            
            // 获取 MediaProjectionManager
            val mediaProjectionManager = try {
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Failed to get MediaProjectionManager", e)
                return
            }
            
            if (mediaProjectionManager == null) {
                android.util.Log.e("RemoteControlService", "MediaProjectionManager is null")
                return
            }
            
            // 创建 MediaProjection（这里可能会因为权限被拒绝而失败）
            mediaProjection = try {
                mediaProjectionManager.getMediaProjection(resultCode, data)
            } catch (e: SecurityException) {
                android.util.Log.e("RemoteControlService", "SecurityException: Permission denied for MediaProjection", e)
                null
            } catch (e: IllegalStateException) {
                android.util.Log.e("RemoteControlService", "IllegalStateException: Service not ready", e)
                null
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Exception creating MediaProjection", e)
                null
            }

            if (mediaProjection == null) {
                android.util.Log.e("RemoteControlService", "Failed to create MediaProjection: resultCode=$resultCode, data=${if (data != null) "not null" else "null"}")
                return
            }

            android.util.Log.d("RemoteControlService", "MediaProjection created successfully")
            
            // 创建 ScreenCaptureManager
            screenCaptureManager = try {
                ScreenCaptureManager(mediaProjection!!, windowManager)
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Failed to create ScreenCaptureManager", e)
                mediaProjection?.stop()
                mediaProjection = null
                return
            }
            
            android.util.Log.d("RemoteControlService", "Starting ScreenCaptureManager")
            screenCaptureManager?.startCapture(
                width = width,
                height = height,
                density = density,
                frameRate = frameRate
            ) { imageBytes ->
                try {
                    framesSentCount++ // 统计发送的帧数
                    android.util.Log.v("RemoteControlService", "Frame received: ${imageBytes.size} bytes, eventSink=${if (eventSink != null) "not null" else "null"}")
                    
                    // 注意：这个回调已经在 IO 线程中执行（来自 ScreenCaptureManager 的 processImage）
                    // EventChannel.EventSink.success() 必须在主线程调用
                    // 使用 mainHandler.post 切换到主线程，但这是异步的，不会阻塞当前线程
                    mainHandler.post {
                        try {
                            eventSink?.success(imageBytes)
                            android.util.Log.v("RemoteControlService", "Frame sent to EventSink successfully")
                        } catch (e: IllegalStateException) {
                            android.util.Log.w("RemoteControlService", "EventSink is closed or invalid", e)
                        } catch (e: Exception) {
                            android.util.Log.e("RemoteControlService", "Error sending frame to eventSink", e)
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("RemoteControlService", "Error in frame callback", e)
                }
            }
            android.util.Log.d("RemoteControlService", "ScreenCaptureManager.startCapture called successfully")
            
            // 启动通知更新机制，确保服务保持活跃（即使屏幕静止也不会被杀掉）
            startNotificationUpdate()
        } catch (e: SecurityException) {
            android.util.Log.e("RemoteControlService", "SecurityException in startScreenCapture: Permission denied", e)
            stopScreenCapture()
        } catch (e: IllegalStateException) {
            android.util.Log.e("RemoteControlService", "IllegalStateException in startScreenCapture: Service not ready", e)
            stopScreenCapture()
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Unexpected error in startScreenCapture", e)
            android.util.Log.e("RemoteControlService", "Error details: ${e.message}", e)
            e.printStackTrace()
            stopScreenCapture()
        }
    }

    private fun stopScreenCapture() {
        android.util.Log.d("RemoteControlService", "stopScreenCapture called")
        
        // 停止通知更新
        stopNotificationUpdate()
        
        try {
            // 按顺序清理录屏资源
            // 1. 先停止 ScreenCaptureManager（会释放 VirtualDisplay 和 ImageReader）
            screenCaptureManager?.stopCapture()
            screenCaptureManager?.release() // 确保完全释放
            screenCaptureManager = null
            android.util.Log.d("RemoteControlService", "ScreenCaptureManager released")
            
            // 2. 停止 MediaProjection
            try {
                mediaProjection?.stop()
                android.util.Log.d("RemoteControlService", "MediaProjection stopped")
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Error stopping MediaProjection", e)
            }
            mediaProjection = null
            
            // 3. 清理 EventSink
            eventSink = null
            
            // 4. 重置帧计数
            framesSentCount = 0
            
            android.util.Log.d("RemoteControlService", "Screen capture stopped and resources cleaned")
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Error in stopScreenCapture", e)
            // 即使出错也要确保对象被置为 null
            screenCaptureManager = null
            mediaProjection = null
            eventSink = null
        }

        // 释放唤醒锁
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                android.util.Log.d("RemoteControlService", "WakeLock released in stopScreenCapture")
            }
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Error releasing WakeLock", e)
        } finally {
            wakeLock = null
        }
    }
    
    /// 启动通知更新机制，定期更新通知以保持服务活跃
    private fun startNotificationUpdate() {
        stopNotificationUpdate() // 先停止旧的更新
        
        notificationUpdateHandler = Handler(Looper.getMainLooper())
        notificationUpdateRunnable = object : Runnable {
            override fun run() {
                try {
                    // 每30秒更新一次通知，显示帧数统计
                    // 这可以防止系统因为"长时间没有活动"而杀掉服务
                    val notification = createNotification()
                    val notificationManager = getSystemService(NotificationManager::class.java)
                    notificationManager.notify(NOTIFICATION_ID, notification)
                    
                    // 安排下一次更新
                    notificationUpdateHandler?.postDelayed(this, 30000) // 30秒
                } catch (e: Exception) {
                    android.util.Log.e("RemoteControlService", "Error updating notification", e)
                }
            }
        }
        notificationUpdateHandler?.postDelayed(notificationUpdateRunnable!!, 30000)
        android.util.Log.d("RemoteControlService", "Notification update started (every 30s)")
    }
    
    /// 停止通知更新
    private fun stopNotificationUpdate() {
        notificationUpdateRunnable?.let { runnable ->
            notificationUpdateHandler?.removeCallbacks(runnable)
        }
        notificationUpdateRunnable = null
        notificationUpdateHandler = null
        android.util.Log.d("RemoteControlService", "Notification update stopped")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 使用 IMPORTANCE_HIGH 确保通知高优先级，防止服务被系统杀死
            val channel = NotificationChannel(
                CHANNEL_ID,
                "远程控制服务",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "用于屏幕捕获和远程控制"
                setShowBadge(false) // 不显示角标
                enableLights(false) // 不显示指示灯
                enableVibration(false) // 不震动
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 创建停止服务的 Intent
        val stopIntent = Intent(this, RemoteControlService::class.java).apply {
            action = "STOP_CAPTURE"
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 使用 NotificationCompat 以确保兼容性
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        // 显示帧数统计（如果有）
        val contentText = if (framesSentCount > 0) {
            "屏幕捕获运行中 - 已发送 $framesSentCount 帧"
        } else {
            "屏幕捕获运行中"
        }
        
        return builder
            .setContentTitle("正在进行远程控制")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pendingIntent)
            .setOngoing(true) // 设置为持续通知，防止被清除
            .setPriority(Notification.PRIORITY_HIGH) // 高优先级，防止服务被系统杀死
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC) // 公开可见
            .setShowWhen(true) // 显示时间戳，让通知看起来是"活动的"
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        android.util.Log.d("RemoteControlService", "onDestroy called")
        
        try {
            // 停止通知更新
            stopNotificationUpdate()
            
            // 彻底清理所有资源
            stopScreenCapture()
            
            // 清理 EventSink 和 pending sink
            eventSink = null
            pendingEventSink = null
            
            // 清理实例引用
            instance = null
            
            // 确保 WakeLock 被释放
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                    android.util.Log.d("RemoteControlService", "WakeLock released in onDestroy")
                }
            } catch (e: Exception) {
                android.util.Log.e("RemoteControlService", "Error releasing WakeLock in onDestroy", e)
            } finally {
                wakeLock = null
            }

            android.util.Log.d("RemoteControlService", "Service destroyed and all resources cleaned")
            
            // 发送广播请求重启服务（如果是被系统杀死）
            sendRestartBroadcast()
            
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Error in onDestroy", e)
            // 即使出错也要确保清理
            stopNotificationUpdate()
            instance = null
            screenCaptureManager = null
            mediaProjection = null
            eventSink = null
            pendingEventSink = null
        }
        
        super.onDestroy()
    }
    
    /**
     * 发送重启广播
     * 用于服务被系统杀死后自动重启
     */
    private fun sendRestartBroadcast() {
        try {
            val restartIntent = Intent().apply {
                action = ServiceRestartReceiver.ACTION_RESTART_SERVICE
                setPackage(packageName)
            }
            sendBroadcast(restartIntent)
            android.util.Log.d("RemoteControlService", "Restart broadcast sent")
        } catch (e: Exception) {
            android.util.Log.e("RemoteControlService", "Error sending restart broadcast", e)
        }
    }
}


