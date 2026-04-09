package com.example.android_remote_control

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity: FlutterActivity() {
    private val CHANNEL = "screen_capture"
    private val INPUT_CHANNEL = "input_control"
    private val EVENT_CHANNEL = "screen_capture_stream"
    private val REQUEST_MEDIA_PROJECTION = 1000
    private var pendingResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null
    private val instrumentation = Instrumentation()
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // 保存最近一次的 MediaProjection 授权结果，避免每次都弹授权窗口
    private var lastProjectionResultCode: Int? = null
    private var lastProjectionData: Intent? = null

    // 保存待启动的采集参数（当用户还没授权时先缓存）
    private data class CaptureParams(
        val width: Int,
        val height: Int,
        val bitRate: Int,
        val frameRate: Int,
    )
    private var pendingCaptureParams: CaptureParams? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    requestScreenCapturePermission(result)
                }
                "startCapture" -> {
                    val width = call.argument<Int>("width") ?: 1080
                    val height = call.argument<Int>("height") ?: 1920
                    val bitRate = call.argument<Int>("bitRate") ?: 8000000
                    val frameRate = call.argument<Int>("frameRate") ?: 30
                    startCapture(width, height, bitRate, frameRate, result)
                }
                "stopCapture" -> {
                    stopCapture(result)
                }
                "getScreenInfo" -> {
                    getScreenInfo(result)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Input Control Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INPUT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "injectTouchEvent" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val action = call.argument<String>("action") ?: "down"
                    val pointerId = call.argument<Int>("pointerId") ?: 0
                    injectTouchEvent(x.toFloat(), y.toFloat(), action, pointerId, result)
                }
                "injectKeyEvent" -> {
                    val keyCode = call.argument<Int>("keyCode") ?: 0
                    val action = call.argument<String>("action") ?: "down"
                    val metaState = call.argument<Int>("metaState") ?: 0
                    injectKeyEvent(keyCode, action, metaState, result)
                }
                "setControllerScreenSize" -> {
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    setControllerScreenSize(width, height, result)
                }
                "setVideoFrameSize" -> {
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    setVideoFrameSize(width, height, result)
                }
                "checkAccessibilityService" -> {
                    checkAccessibilityService(result)
                }
                "injectSwipeEvent" -> {
                    val startX = call.argument<Double>("startX") ?: 0.0
                    val startY = call.argument<Double>("startY") ?: 0.0
                    val endX = call.argument<Double>("endX") ?: 0.0
                    val endY = call.argument<Double>("endY") ?: 0.0
                    val duration = call.argument<Int>("duration") ?: 300
                    injectSwipeEvent(
                        startX.toFloat(),
                        startY.toFloat(),
                        endX.toFloat(),
                        endY.toFloat(),
                        duration,
                        result
                    )
                }
                "openAccessibilitySettings" -> {
                    openAccessibilitySettings(result)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Event Channel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    // Service 可能还没创建：先缓存，等 Service 启动后再接管
                    if (RemoteControlService.instance != null) {
                        RemoteControlService.instance?.setEventSink(events)
                    } else {
                        RemoteControlService.pendingEventSink = events
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    RemoteControlService.instance?.setEventSink(null)
                    RemoteControlService.pendingEventSink = null
                }
            }
        )
    }

    private fun requestScreenCapturePermission(result: MethodChannel.Result) {
        try {
            android.util.Log.d("MainActivity", "requestScreenCapturePermission called")
            pendingResult = result
            val mediaProjectionManager = try {
                getSystemService(MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Failed to get MediaProjectionManager", e)
                result.error("SERVICE_ERROR", "无法获取屏幕捕获服务", null)
                return
            }
            
            if (mediaProjectionManager == null) {
                android.util.Log.e("MainActivity", "MediaProjectionManager is null")
                result.error("SERVICE_ERROR", "屏幕捕获服务不可用", null)
                return
            }
            
            val captureIntent = try {
                mediaProjectionManager.createScreenCaptureIntent()
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Failed to create screen capture intent", e)
                result.error("INTENT_ERROR", "无法创建屏幕捕获请求", null)
                return
            }
            
            startActivityForResult(captureIntent, REQUEST_MEDIA_PROJECTION)
            android.util.Log.d("MainActivity", "Screen capture permission request sent")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Unexpected error in requestScreenCapturePermission", e)
            result.error("UNKNOWN_ERROR", "请求权限时发生错误: ${e.message}", null)
        }
    }

    /// 检查并引导用户将应用加入“忽略电池优化”白名单
    /// 避免系统在待机/省电模式下杀死前台服务
    private fun ensureBatteryOptimizationIgnored() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
                val pkg = packageName
                if (!pm.isIgnoringBatteryOptimizations(pkg)) {
                    android.util.Log.d("MainActivity", "Requesting ignore battery optimizations for $pkg")
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$pkg")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    // 该 Intent 会弹出系统对话框，由用户确认
                    startActivity(intent)
                } else {
                    android.util.Log.d("MainActivity", "App already ignoring battery optimizations")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error checking/requesting ignore battery optimizations", e)
        }
    }

    private fun startCapture(width: Int, height: Int, bitRate: Int, frameRate: Int, result: MethodChannel.Result) {
        // 先缓存参数，确保 onActivityResult 后能拿到并启动 Service
        pendingCaptureParams = CaptureParams(width, height, bitRate, frameRate)

        // 如果之前已经拿到过授权结果，直接启动 Service（不再弹窗）
        val rc = lastProjectionResultCode
        val data = lastProjectionData
        if (rc != null && data != null) {
            startCaptureService(rc, data, pendingCaptureParams!!)
            result.success(true)
            return
        }

        // 否则发起授权
        pendingResult = result
        val mediaProjectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val captureIntent = mediaProjectionManager.createScreenCaptureIntent()
        startActivityForResult(captureIntent, REQUEST_MEDIA_PROJECTION)
    }

    private fun stopCapture(result: MethodChannel.Result) {
        val serviceIntent = Intent(this, RemoteControlService::class.java).apply {
            action = "STOP_CAPTURE"
        }
        startService(serviceIntent)
        result.success(true)
    }

    private fun getScreenInfo(result: MethodChannel.Result) {
        val displayMetrics = resources.displayMetrics
        val info = mapOf(
            "width" to displayMetrics.widthPixels,
            "height" to displayMetrics.heightPixels,
            "density" to displayMetrics.density,
            "densityDpi" to displayMetrics.densityDpi
        )
        result.success(info)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // 记录授权结果，后续可直接复用
                lastProjectionResultCode = resultCode
                lastProjectionData = data

                // 如果此前已经有 startCapture 参数，立刻启动 Service
                val params = pendingCaptureParams
                if (params != null) {
                    startCaptureService(resultCode, data, params)
                }

                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }

    private fun startCaptureService(resultCode: Int, data: Intent, params: CaptureParams) {
        try {
            // 在真正启动前台服务之前，尝试引导用户将应用加入电池白名单
            ensureBatteryOptimizationIgnored()

            // 验证并限制参数范围，确保设备支持
            val width = params.width.coerceIn(320, 3840) // 限制在 320-3840 之间
            val height = params.height.coerceIn(480, 2160) // 限制在 480-2160 之间
            val frameRate = params.frameRate.coerceIn(5, 30) // 限制在 5-30 fps 之间
            
            // 如果参数被调整，记录警告
            if (width != params.width || height != params.height || frameRate != params.frameRate) {
                android.util.Log.w("MainActivity", "Parameters adjusted: width ${params.width}->$width, height ${params.height}->$height, frameRate ${params.frameRate}->$frameRate")
            }
            
            android.util.Log.d("MainActivity", "startCaptureService: resultCode=$resultCode, width=$width, height=$height, frameRate=$frameRate")
            
            // 检查参数有效性
            if (resultCode != Activity.RESULT_OK) {
                android.util.Log.e("MainActivity", "Invalid resultCode: $resultCode (expected ${Activity.RESULT_OK})")
                return
            }
            
            if (data == null) {
                android.util.Log.e("MainActivity", "Intent data is null")
                return
            }
            
            val serviceIntent = Intent(this, RemoteControlService::class.java).apply {
                putExtra("resultCode", resultCode)
                putExtra("data", data)
                putExtra("width", width)
                putExtra("height", height)
                putExtra("bitRate", params.bitRate)
                putExtra("frameRate", frameRate)
                action = "START_CAPTURE"
            }
            
            // Android 8.0+ 必须使用 startForegroundService
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                try {
                    startForegroundService(serviceIntent)
                    android.util.Log.d("MainActivity", "Foreground service started successfully")
                } catch (e: IllegalStateException) {
                    android.util.Log.e("MainActivity", "IllegalStateException: Cannot start foreground service", e)
                    // 如果前台服务启动失败，尝试普通启动（虽然可能被系统杀死）
                    try {
                        startService(serviceIntent)
                        android.util.Log.w("MainActivity", "Fallback to startService")
                    } catch (e2: Exception) {
                        android.util.Log.e("MainActivity", "Failed to start service", e2)
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                startService(serviceIntent)
                android.util.Log.d("MainActivity", "Service started (Android < 8.0)")
            }
        } catch (e: SecurityException) {
            android.util.Log.e("MainActivity", "SecurityException: Permission denied", e)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Unexpected error starting service", e)
            android.util.Log.e("MainActivity", "Error details: ${e.message}", e)
            e.printStackTrace()
        }
    }

    /// 注入触摸事件（使用 AccessibilityService）
    private fun injectTouchEvent(x: Float, y: Float, action: String, pointerId: Int, result: MethodChannel.Result) {
        scope.launch {
            try {
                // x, y 是百分比坐标(0-1)，直接传递给AccessibilityService
                // 注意：不要在这里转换为像素坐标，因为AccessibilityService.performClick内部会进行转换
                android.util.Log.d("MainActivity", "Injecting touch event: ($x, $y) normalized coordinates, action=$action")
                
                val a11yService = RemoteControlAccessibilityService.instance
                
                if (a11yService == null) {
                    android.util.Log.w("MainActivity", "AccessibilityService not available, falling back to Instrumentation")
                    // 回退到 Instrumentation（需要系统权限）
                    // Instrumentation需要像素坐标，所以这里需要转换
                    val displayMetrics = resources.displayMetrics
                    val pixelX = x * displayMetrics.widthPixels
                    val pixelY = y * displayMetrics.heightPixels
                    injectTouchEventWithInstrumentation(pixelX, pixelY, action, pointerId, result)
                    return@launch
                }
                
                android.util.Log.d("MainActivity", "Injecting touch event via AccessibilityService: ($x, $y) normalized")
                
                when (action) {
                    "down" -> {
                        // 按下：执行点击手势（传递百分比坐标，AccessibilityService内部会转换）
                        a11yService.performClick(x, y) { success ->
                            android.util.Log.d("MainActivity", "Click gesture result: $success")
                            result.success(success)
                        }
                    }
                    "up" -> {
                        // 抬起：通常与 down 配对，但 AccessibilityService 的点击已经包含 up
                        // 如果只是单独的 up，可以忽略
                        android.util.Log.d("MainActivity", "Touch up event ignored (handled by click gesture)")
                        result.success(true)
                    }
                    "longPress" -> {
                        // 长按（传递百分比坐标）
                        a11yService.performLongPress(x, y, 500) { success ->
                            android.util.Log.d("MainActivity", "Long press gesture result: $success")
                            result.success(success)
                        }
                    }
                    "move" -> {
                        // 移动：简化处理，忽略
                        android.util.Log.d("MainActivity", "Touch move event ignored")
                        result.success(true)
                    }
                    else -> {
                        android.util.Log.w("MainActivity", "Unknown touch action: $action, treating as click")
                        a11yService.performClick(x, y) { success ->
                            result.success(success)
                        }
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Error injecting touch event", e)
                result.success(false)
            }
        }
    }
    
    /// 使用 Instrumentation 注入触摸事件（回退方案，需要系统权限）
    private fun injectTouchEventWithInstrumentation(x: Float, y: Float, action: String, pointerId: Int, result: MethodChannel.Result) {
        try {
            val motionAction = when (action) {
                "down" -> MotionEvent.ACTION_DOWN
                "up" -> MotionEvent.ACTION_UP
                "move" -> MotionEvent.ACTION_MOVE
                else -> MotionEvent.ACTION_DOWN
            }

            val eventTime = SystemClock.uptimeMillis()
            val motionEvent = MotionEvent.obtain(
                eventTime,
                eventTime,
                motionAction,
                x,
                y,
                0
            )

            // 在主线程执行
            runOnUiThread {
                try {
                    instrumentation.sendPointerSync(motionEvent)
                    motionEvent.recycle()
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "Instrumentation injection failed: ${e.message}", e)
                    result.success(false)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error creating motion event: ${e.message}", e)
            result.success(false)
        }
    }
    
    /// 设置控制端屏幕尺寸（用于坐标映射）
    /// 由于现在使用"百分比坐标"（0~1），实际映射只需要被控端屏幕分辨率。
    /// 这里保留方法以兼容 Flutter 端调用，只更新被控端分辨率。
    private fun setControllerScreenSize(width: Int, height: Int, result: MethodChannel.Result) {
        try {
            android.util.Log.d("MainActivity", "Setting controller screen size (normalized mode): ${width}x${height}")
            
            // 仅设置被控端屏幕尺寸，坐标映射使用百分比 * 被控端分辨率
            val displayMetrics = resources.displayMetrics
            RemoteControlAccessibilityService.setControlledScreenSize(
                displayMetrics.widthPixels,
                displayMetrics.heightPixels
            )
            
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error setting controller screen size", e)
            result.success(false)
        }
    }
    
    /// 设置视频帧尺寸（用于坐标映射）
    /// 重要：控制端看到的视频帧尺寸可能与实际屏幕尺寸不同（因为缩放/裁剪）
    private fun setVideoFrameSize(width: Int, height: Int, result: MethodChannel.Result) {
        try {
            android.util.Log.d("MainActivity", "Setting video frame size: ${width}x${height}")
            
            // 设置视频帧尺寸，用于坐标映射计算
            RemoteControlAccessibilityService.setVideoFrameSize(width, height)
            
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error setting video frame size", e)
            result.success(false)
        }
    }
    
    /// 检查 AccessibilityService 是否启用
    private fun checkAccessibilityService(result: MethodChannel.Result) {
        try {
            val a11yService = RemoteControlAccessibilityService.instance
            val isEnabled = a11yService != null
            
            android.util.Log.d("MainActivity", "AccessibilityService enabled: $isEnabled")
            
            val info = mapOf(
                "enabled" to isEnabled,
                "serviceAvailable" to (a11yService != null)
            )
            result.success(info)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error checking AccessibilityService", e)
            result.success(mapOf("enabled" to false, "error" to e.message))
        }
    }

    /// 打开无障碍服务设置页面
    private fun openAccessibilitySettings(result: MethodChannel.Result) {
        try {
            android.util.Log.d("MainActivity", "Opening accessibility settings")
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error opening accessibility settings", e)
            result.success(false)
        }
    }

    /// 注入按键事件
    private fun injectKeyEvent(keyCode: Int, action: String, metaState: Int, result: MethodChannel.Result) {
        android.util.Log.d("MainActivity", "injectKeyEvent: keyCode=$keyCode, action=$action")
        
        // 系统导航键使用 AccessibilityService 处理
        if (action == "down") {
            when (keyCode) {
                4 -> { // BACK 键
                    android.util.Log.d("MainActivity", "使用 AccessibilityService 执行 BACK")
                    val success = RemoteControlAccessibilityService.instance?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) ?: false
                    result.success(success)
                    return
                }
                3 -> { // HOME 键
                    android.util.Log.d("MainActivity", "使用 AccessibilityService 执行 HOME")
                    val success = RemoteControlAccessibilityService.instance?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) ?: false
                    result.success(success)
                    return
                }
                187 -> { // RECENT 键（最近任务）
                    android.util.Log.d("MainActivity", "使用 AccessibilityService 执行 RECENTS")
                    val success = RemoteControlAccessibilityService.instance?.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS) ?: false
                    result.success(success)
                    return
                }
            }
        }
        
        // 其他按键（如音量键）使用传统方式
        scope.launch {
            try {
                val keyAction = when (action) {
                    "down" -> KeyEvent.ACTION_DOWN
                    "up" -> KeyEvent.ACTION_UP
                    else -> KeyEvent.ACTION_DOWN
                }

                val eventTime = SystemClock.uptimeMillis()
                val keyEvent = KeyEvent(
                    eventTime,
                    eventTime,
                    keyAction,
                    keyCode,
                    0,
                    metaState
                )

                // 在主线程执行
                runOnUiThread {
                    try {
                        instrumentation.sendKeySync(keyEvent)
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "注入按键事件失败: ${e.message}")
                        result.success(false)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "创建按键事件失败: ${e.message}")
                result.success(false)
            }
        }
    }

    /// 注入滑动事件
    private fun injectSwipeEvent(
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        duration: Int,
        result: MethodChannel.Result
    ) {
        scope.launch {
            try {
                val a11yService = RemoteControlAccessibilityService.instance

                if (a11yService == null) {
                    android.util.Log.w("MainActivity", "AccessibilityService not available, cannot perform swipe")
                    result.success(false)
                    return@launch
                }

                android.util.Log.d("MainActivity", "Injecting swipe event via AccessibilityService: ($startX, $startY) -> ($endX, $endY), duration=$duration")

                a11yService.performSwipe(startX, startY, endX, endY, duration.toLong()) { success ->
                    android.util.Log.d("MainActivity", "Swipe gesture result: $success")
                    result.success(success)
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Error injecting swipe event", e)
                result.success(false)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }
}


