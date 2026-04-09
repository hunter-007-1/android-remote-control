package com.example.android_remote_control

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.media.AudioManager
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlinx.coroutines.*
import org.json.JSONObject

/**
 * 远程控制无障碍服务
 * 用于在非 Root 设备上执行触摸和手势操作
 */
class RemoteControlAccessibilityService : AccessibilityService() {
    
    companion object {
        private const val TAG = "RemoteControlA11y"
        var instance: RemoteControlAccessibilityService? = null
            private set
        
        // 屏幕尺寸缓存（实际设备屏幕尺寸）
        private var screenWidth: Int = 0
        private var screenHeight: Int = 0
        
        // 视频帧尺寸缓存（控制端看到的画面尺寸，可能与屏幕尺寸不同）
        private var videoFrameWidth: Int = 0
        private var videoFrameHeight: Int = 0
        
        /**
         * 设置被控端屏幕尺寸（实际设备屏幕尺寸）
         */
        fun setControlledScreenSize(width: Int, height: Int) {
            screenWidth = width
            screenHeight = height
            Log.d(TAG, "Controlled screen size set: ${width}x${height}")
        }
        
        /**
         * 设置视频帧尺寸（控制端看到的画面尺寸）
         * 重要：视频帧可能被缩放或裁剪，与屏幕尺寸不同
         */
        fun setVideoFrameSize(width: Int, height: Int) {
            videoFrameWidth = width
            videoFrameHeight = height
            Log.d(TAG, "Video frame size set: ${width}x${height}")
        }
        
        /**
         * 将控制端坐标映射到被控端坐标
         * @param controllerX 控制端 X 坐标（0~1 百分比）
         * @param controllerY 控制端 Y 坐标（0~1 百分比）
         * @return Pair<被控端X, 被控端Y>
         * 
         * 映射逻辑：
         * 1. 控制端坐标是基于视频帧的（eg. 720x1280）
         * 2. 需要映射到实际屏幕坐标（eg. 1080x2400）
         * 3. 计算公式：screenX = controllerX * videoFrameWidth * (screenWidth / videoFrameWidth)
         *            = controllerX * screenWidth
         *    实际上直接乘以 screenWidth 即可，因为百分比坐标已经归一化
         */
        fun mapCoordinates(controllerX: Float, controllerY: Float): Pair<Float, Float> {
            if (screenWidth == 0 || screenHeight == 0) {
                Log.w(TAG, "Screen size not set, using original coordinates")
                return Pair(controllerX, controllerY)
            }
            
            // 将百分比坐标（0~1）映射到实际屏幕像素坐标
            val mappedX = (controllerX * screenWidth.toFloat()).coerceIn(0f, screenWidth.toFloat() - 1f)
            val mappedY = (controllerY * screenHeight.toFloat()).coerceIn(0f, screenHeight.toFloat() - 1f)
            
            Log.d(TAG, "Coordinate mapping: normalized($controllerX, $controllerY) -> pixel($mappedX, $mappedY) [screen: ${screenWidth}x${screenHeight}, videoFrame: ${videoFrameWidth}x${videoFrameHeight}]")
            
            return Pair(mappedX, mappedY)
        }
    }
    
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var audioManager: AudioManager? = null

    override fun onCreate() {
        super.onCreate()
        try {
            audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager
            Log.d(TAG, "AudioManager initialized in AccessibilityService: ${audioManager != null}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AudioManager", e)
        }
    }
    
    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        
        // 获取屏幕尺寸
        val displayMetrics = resources.displayMetrics
        screenWidth = displayMetrics.widthPixels
        screenHeight = displayMetrics.heightPixels
        
        Log.d(TAG, "AccessibilityService connected successfully")
        Log.d(TAG, "Screen size: ${screenWidth}x${screenHeight}")
        
        // 检查服务能力（Android 9+）
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            val capabilities = getServiceInfo().capabilities
            Log.d(TAG, "Service capabilities:")
            Log.d(TAG, "  - canRetrieveWindowContent: ${capabilities and android.accessibilityservice.AccessibilityServiceInfo.CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT != 0}")
            Log.d(TAG, "  - canPerformGestures: ${capabilities and android.accessibilityservice.AccessibilityServiceInfo.CAPABILITY_CAN_PERFORM_GESTURES != 0}")
            Log.d(TAG, "  - canRequestFilterKeyEvents: ${capabilities and android.accessibilityservice.AccessibilityServiceInfo.CAPABILITY_CAN_REQUEST_FILTER_KEY_EVENTS != 0}")
        } else {
            Log.d(TAG, "Service capabilities check requires Android 9+")
        }
        
        // 设置被控端屏幕尺寸
        setControlledScreenSize(screenWidth, screenHeight)
    }
    
    override fun onDestroy() {
        super.onDestroy()
        instance = null
        serviceScope.cancel()
        Log.d(TAG, "AccessibilityService destroyed")
    }
    
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 不需要处理无障碍事件，只用于手势执行
    }
    
    override fun onInterrupt() {
        Log.w(TAG, "AccessibilityService interrupted")
    }
    
    /**
     * 执行点击手势
     * @param x X 坐标（控制端坐标）
     * @param y Y 坐标（控制端坐标）
     * @param callback 执行结果回调
     */
    fun performClick(x: Float, y: Float, callback: (Boolean) -> Unit) {
        // 映射坐标
        val (mappedX, mappedY) = mapCoordinates(x, y)
        
        Log.d(TAG, "Performing click at ($x, $y) -> ($mappedX, $mappedY)")
        
        // 创建点击路径
        val path = Path().apply {
            moveTo(mappedX, mappedY)
        }
        
        // 创建手势描述（点击持续时间 50ms）
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()
        
        // 执行手势
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Click gesture completed")
                callback(true)
            }
            
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "Click gesture cancelled")
                callback(false)
            }
        }, null)
    }

        /**
         * 处理来自上层的 JSON 指令
         * 协议示例：
         * CLICK: { "type": "CLICK", "x": 0.5, "y": 0.5 }
         * SWIPE: { "type": "SWIPE", "startX": 0.1, "startY": 0.1, "endX": 0.8, "endY": 0.8, "duration": 300 }
         * KEY:   { "type": "KEY", "action": "BACK" }
         * （兼容老协议）TOUCH: { "type": "TOUCH", "x": 0.5, "y": 0.3 }
         */
    fun handleRemoteJsonCommand(json: String, callback: ((Boolean) -> Unit)? = null) {
        try {
            val obj = JSONObject(json)
            val type = obj.optString("type", "")
            Log.d(TAG, "handleRemoteJsonCommand: type=$type, raw=$json")

            when (type.uppercase()) {
                "CLICK", "TOUCH" -> {
                    // CLICK / 兼容旧的 TOUCH：都视为点击
                    val x = obj.optDouble("x", Double.NaN)
                    val y = obj.optDouble("y", Double.NaN)
                    if (x.isNaN() || y.isNaN()) {
                        Log.w(TAG, "Invalid CLICK/TOUCH command, x or y is NaN: x=$x, y=$y")
                        callback?.invoke(false)
                        return
                    }
                    // 坐标为 0~1 的百分比，内部会映射为被控端真实像素
                    performClick(x.toFloat(), y.toFloat()) { success ->
                        callback?.invoke(success)
                    }
                }
                "SWIPE" -> {
                    val startX = obj.optDouble("startX", Double.NaN)
                    val startY = obj.optDouble("startY", Double.NaN)
                    val endX = obj.optDouble("endX", Double.NaN)
                    val endY = obj.optDouble("endY", Double.NaN)
                    val duration = obj.optLong("duration", 300L)

                    if (startX.isNaN() || startY.isNaN() || endX.isNaN() || endY.isNaN()) {
                        Log.w(TAG, "Invalid SWIPE command, some coordinates are NaN: " +
                            "start=($startX, $startY), end=($endX, $endY)")
                        callback?.invoke(false)
                        return
                    }

                    val safeDuration = duration.coerceIn(100L, 1000L)

                    performSwipe(
                        startX.toFloat(),
                        startY.toFloat(),
                        endX.toFloat(),
                        endY.toFloat(),
                        safeDuration
                    ) { success ->
                        callback?.invoke(success)
                    }
                }
                "KEY" -> {
                    val action = obj.optString("action", "")
                    val success = handleKeyAction(action)
                    callback?.invoke(success)
                }
                else -> {
                    Log.w(TAG, "Unknown command type in JSON: '$type'")
                    callback?.invoke(false)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing remote JSON command: $json", e)
            callback?.invoke(false)
        }
    }

    /**
     * 处理按键动作：
     * - 系统导航键：通过 performGlobalAction
     * - 音量键：通过 AudioManager 调整 STREAM_MUSIC 音量
     */
    fun handleKeyAction(action: String): Boolean {
        val normalized = action.uppercase()
        Log.d(TAG, "handleKeyAction: action=$normalized")

        return try {
            when (normalized) {
                "BACK" -> {
                    val ok = performGlobalAction(GLOBAL_ACTION_BACK)
                    Log.d(TAG, "GLOBAL_ACTION_BACK result=$ok")
                    ok
                }
                "HOME" -> {
                    val ok = performGlobalAction(GLOBAL_ACTION_HOME)
                    Log.d(TAG, "GLOBAL_ACTION_HOME result=$ok")
                    ok
                }
                "RECENT", "RECENTS", "MENU" -> {
                    val ok = performGlobalAction(GLOBAL_ACTION_RECENTS)
                    Log.d(TAG, "GLOBAL_ACTION_RECENTS result=$ok")
                    ok
                }
                "POWER" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        // Android 9.0+ 支持锁屏全局操作
                        val ok = performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
                        Log.d(TAG, "GLOBAL_ACTION_LOCK_SCREEN result=$ok")
                        ok
                    } else {
                        Log.w(TAG, "GLOBAL_ACTION_LOCK_SCREEN requires Android 9.0+, current=${Build.VERSION.SDK_INT}")
                        false
                    }
                }
                "VOLUME_UP" -> {
                    val am = audioManager
                    if (am == null) {
                        Log.w(TAG, "AudioManager is null, cannot adjust volume up")
                        false
                    } else {
                        am.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_RAISE,
                            0
                        )
                        Log.d(TAG, "Volume up (STREAM_MUSIC)")
                        true
                    }
                }
                "VOLUME_DOWN" -> {
                    val am = audioManager
                    if (am == null) {
                        Log.w(TAG, "AudioManager is null, cannot adjust volume down")
                        false
                    } else {
                        am.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_LOWER,
                            0
                        )
                        Log.d(TAG, "Volume down (STREAM_MUSIC)")
                        true
                    }
                }
                else -> {
                    Log.w(TAG, "Unknown key action: '$action'")
                    false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling key action: '$action'", e)
            false
        }
    }
    
    /**
     * 执行长按手势
     * @param x X 坐标（控制端坐标）
     * @param y Y 坐标（控制端坐标）
     * @param duration 长按持续时间（毫秒），默认 500ms
     * @param callback 执行结果回调
     */
    fun performLongPress(x: Float, y: Float, duration: Long = 500, callback: (Boolean) -> Unit) {
        // 映射坐标
        val (mappedX, mappedY) = mapCoordinates(x, y)
        
        Log.d(TAG, "Performing long press at ($x, $y) -> ($mappedX, $mappedY), duration=$duration")
        
        // 创建长按路径
        val path = Path().apply {
            moveTo(mappedX, mappedY)
        }
        
        // 创建手势描述（长按持续时间）
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        
        // 执行手势
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Long press gesture completed")
                callback(true)
            }
            
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "Long press gesture cancelled")
                callback(false)
            }
        }, null)
    }
    
    /**
     * 执行滑动手势
     * @param startX 起始 X 坐标（控制端坐标）
     * @param startY 起始 Y 坐标（控制端坐标）
     * @param endX 结束 X 坐标（控制端坐标）
     * @param endY 结束 Y 坐标（控制端坐标）
     * @param duration 滑动持续时间（毫秒），默认 500ms
     * @param callback 执行结果回调
     */
    fun performSwipe(
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        duration: Long = 500,
        callback: (Boolean) -> Unit
    ) {
        // 映射坐标
        val (mappedStartX, mappedStartY) = mapCoordinates(startX, startY)
        val (mappedEndX, mappedEndY) = mapCoordinates(endX, endY)

        // 确保持续时间在合理范围内（200-1000ms）
        val safeDuration = duration.coerceIn(200L, 1000L)

        Log.d(TAG, "Performing swipe from ($startX, $startY) -> ($endX, $endY)")
        Log.d(TAG, "  Mapped: ($mappedStartX, $mappedStartY) -> ($mappedEndX, $mappedEndY), duration=$safeDuration")

        // 创建更平滑的滑动路径，添加中间点使手势更自然
        val path = Path().apply {
            moveTo(mappedStartX, mappedStartY)
            // 添加中间点（2个插值点），使滑动路径更平滑
            val stepX = (mappedEndX - mappedStartX) / 3
            val stepY = (mappedEndY - mappedStartY) / 3
            lineTo(mappedStartX + stepX, mappedStartY + stepY)
            lineTo(mappedStartX + stepX * 2, mappedStartY + stepY * 2)
            lineTo(mappedEndX, mappedEndY)
        }

        // 创建手势描述
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, safeDuration))
            .build()

        // 执行手势
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Swipe gesture completed successfully")
                callback(true)
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "Swipe gesture cancelled")
                callback(false)
            }
        }, null)
    }
    
    /**
     * 执行拖动手势（按下 -> 移动 -> 抬起）
     * @param points 点序列（控制端坐标）
     * @param duration 总持续时间（毫秒）
     * @param callback 执行结果回调
     */
    fun performDrag(
        points: List<Pair<Float, Float>>,
        duration: Long = 500,
        callback: (Boolean) -> Unit
    ) {
        if (points.isEmpty()) {
            Log.w(TAG, "Drag points is empty")
            callback(false)
            return
        }
        
        // 映射所有坐标点
        val mappedPoints = points.map { (x, y) -> mapCoordinates(x, y) }
        
        Log.d(TAG, "Performing drag with ${points.size} points, duration=$duration")
        
        // 创建拖动路径
        val path = Path().apply {
            val (firstX, firstY) = mappedPoints[0]
            moveTo(firstX, firstY)
            for (i in 1 until mappedPoints.size) {
                val (x, y) = mappedPoints[i]
                lineTo(x, y)
            }
        }
        
        // 创建手势描述
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        
        // 执行手势
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Drag gesture completed")
                callback(true)
            }
            
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "Drag gesture cancelled")
                callback(false)
            }
        }, null)
    }
}

