package com.example.android_remote_control

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlinx.coroutines.*

class ScreenCaptureManager(
    private val mediaProjection: MediaProjection,
    private val windowManager: WindowManager
) {
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var isCapturing = false
    private var captureCallback: ((ByteArray) -> Unit)? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var targetFrameRate: Int = 15 // 目标帧率
    private var lastFrameTime: Long = 0 // 上一帧的时间戳
    
    // 丢帧策略：如果上一帧还在处理/传输中，直接丢弃新帧
    @Volatile
    private var isProcessingFrame = false // 是否正在处理帧（包括压缩和传输）
    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            android.util.Log.w("ScreenCaptureManager", "MediaProjection stopped")
            stopCapture()
        }
    }

    fun startCapture(
        width: Int,
        height: Int,
        density: Int,
        frameRate: Int,
        callback: (ByteArray) -> Unit
    ) {
        if (isCapturing) {
            android.util.Log.w("ScreenCaptureManager", "Already capturing, ignoring startCapture")
            return
        }

        // 限制帧率在合理范围内（5-30 fps）
        targetFrameRate = frameRate.coerceIn(5, 30)
        lastFrameTime = 0 // 重置时间戳
        
        android.util.Log.d("ScreenCaptureManager", "startCapture: ${width}x${height}, density=$density, fps=$targetFrameRate")
        captureCallback = callback
        val metrics = DisplayMetrics()
        windowManager.defaultDisplay.getMetrics(metrics)

        // 在部分设备/ROM（包括部分鸿蒙/华为机型）上，ImageReader 回调需要显式的 HandlerThread
        try {
            handlerThread = HandlerThread("ScreenCapture").apply { start() }
            // 等待 HandlerThread 完全启动，确保 looper 可用
            val looper = handlerThread!!.looper
            if (looper == null) {
                android.util.Log.e("ScreenCaptureManager", "HandlerThread looper is null!")
                handlerThread?.quitSafely()
                handlerThread = null
                return
            }
            handler = Handler(looper)
            android.util.Log.d("ScreenCaptureManager", "HandlerThread created")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Failed to create HandlerThread", e)
            handlerThread?.quitSafely()
            handlerThread = null
            handler = null
            return
        }

        // 增加缓冲区大小到 3，防止缓冲区满导致不再接收新图像
        // ImageReader 缓冲区满后，VirtualDisplay 会停止推送新帧
        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        android.util.Log.d("ScreenCaptureManager", "ImageReader created: ${width}x${height}, maxImages=3")
        
        val surface = imageReader?.surface
        if (surface == null) {
            android.util.Log.e("ScreenCaptureManager", "ImageReader surface is null!")
            handlerThread?.quitSafely()
            handlerThread = null
            handler = null
            imageReader?.close()
            imageReader = null
            return
        }
        
        // 确保 Surface 有效
        if (!surface.isValid) {
            android.util.Log.e("ScreenCaptureManager", "ImageReader surface is invalid!")
            handlerThread?.quitSafely()
            handlerThread = null
            handler = null
            imageReader?.close()
            imageReader = null
            return
        }
        android.util.Log.d("ScreenCaptureManager", "ImageReader surface is valid")
        
        imageReader?.setOnImageAvailableListener({ reader ->
            // 关键：必须使用 acquireNextImage() 而不是 acquireLatestImage()
            // acquireLatestImage() 会丢弃旧图像，但如果处理速度慢，可能导致缓冲区问题
            // acquireNextImage() 按顺序处理，确保缓冲区正确释放
            var image: Image? = null
            try {
                // 丢帧策略：如果上一帧还在处理/传输中，直接丢弃新帧
                if (isProcessingFrame) {
                    android.util.Log.v("ScreenCaptureManager", "Previous frame still processing, dropping new frame")
                    // 必须获取并立即关闭图像，否则 ImageReader 缓冲区会满
                    image = try {
                        reader.acquireLatestImage() // 获取最新图像（丢弃旧帧）
                    } catch (e: IllegalStateException) {
                        android.util.Log.w("ScreenCaptureManager", "Failed to acquire image for dropping", e)
                        null
                    }
                    // 立即关闭，释放缓冲区
                    image?.close()
                    return@setOnImageAvailableListener
                }
                
                // 帧率控制：限制处理频率
                val currentTime = System.currentTimeMillis()
                val minFrameInterval = 1000L / targetFrameRate // 最小帧间隔（毫秒）
                
                // 先获取图像（必须获取，否则 ImageReader 缓冲区会满）
                image = try {
                    reader.acquireNextImage()
                } catch (e: IllegalStateException) {
                    // 如果缓冲区已满，尝试获取最新图像
                    android.util.Log.w("ScreenCaptureManager", "acquireNextImage failed, trying acquireLatestImage", e)
                    reader.acquireLatestImage()
                }
                
                if (image == null) {
                    android.util.Log.w("ScreenCaptureManager", "Failed to acquire image")
                    return@setOnImageAvailableListener
                }
                
                // 如果距离上一帧时间太短，跳过这一帧（但必须关闭图像释放缓冲区）
                if (currentTime - lastFrameTime < minFrameInterval) {
                    android.util.Log.v("ScreenCaptureManager", "Frame skipped for rate limiting")
                    try {
                        image.close() // 立即释放，避免缓冲区堆积
                    } catch (e: Exception) {
                        android.util.Log.e("ScreenCaptureManager", "Error closing skipped frame", e)
                    }
                    return@setOnImageAvailableListener
                }
                
                lastFrameTime = currentTime
                
                android.util.Log.v("ScreenCaptureManager", "Image available: ${image.width}x${image.height}, timestamp=${image.timestamp}")
                
                // 标记正在处理帧
                isProcessingFrame = true
                
                // 立即在后台线程处理图像，但确保 Image 在 finally 中关闭
                // 关键：必须在处理完成后关闭 Image，否则 ImageReader 缓冲区会满，不再接收新图像
                val imageToProcess = image
                scope.launch(Dispatchers.IO) {
                    try {
                        processImage(imageToProcess)
                    } catch (e: Exception) {
                        android.util.Log.e("ScreenCaptureManager", "Error processing image", e)
                    } finally {
                        // 关键：必须关闭 Image，释放 ImageReader 缓冲区
                        // 如果不关闭，ImageReader 的缓冲区会满（maxImages=3），导致不再接收新图像
                        try {
                            imageToProcess.close()
                            android.util.Log.v("ScreenCaptureManager", "Image closed, buffer released")
                        } catch (e: Exception) {
                            android.util.Log.e("ScreenCaptureManager", "Error closing image", e)
                        } finally {
                            // 重置处理标志，允许处理下一帧
                            isProcessingFrame = false
                        }
                    }
                }
                // 注意：这里不能关闭 image，因为它在协程中异步处理
                // 将 image 设为 null，避免在 catch 块中重复关闭
                image = null
            } catch (e: IllegalStateException) {
                android.util.Log.e("ScreenCaptureManager", "IllegalStateException: ImageReader may be closed or buffer full", e)
                // 如果出错，确保 Image 被关闭
                try {
                    image?.close()
                } catch (closeException: Exception) {
                    android.util.Log.e("ScreenCaptureManager", "Error closing image in exception handler", closeException)
                } finally {
                    // 重置处理标志
                    isProcessingFrame = false
                }
            } catch (e: Exception) {
                android.util.Log.e("ScreenCaptureManager", "Error in onImageAvailable", e)
                // 如果出错，确保 Image 被关闭
                try {
                    image?.close()
                } catch (closeException: Exception) {
                    android.util.Log.e("ScreenCaptureManager", "Error closing image in exception handler", closeException)
                } finally {
                    // 重置处理标志
                    isProcessingFrame = false
                }
            }
        }, handler)
        android.util.Log.d("ScreenCaptureManager", "ImageReader listener set")

        // 必须在创建 VirtualDisplay 之前注册 MediaProjection.Callback
        try {
            if (handler == null) {
                android.util.Log.e("ScreenCaptureManager", "Handler is null, cannot register callback")
                handlerThread?.quitSafely()
                handlerThread = null
                imageReader?.close()
                imageReader = null
                return
            }
            mediaProjection.registerCallback(projectionCallback, handler)
            android.util.Log.d("ScreenCaptureManager", "MediaProjection callback registered")

            // 再次检查 Surface 有效性（在创建 VirtualDisplay 之前）
            if (!surface.isValid) {
                android.util.Log.e("ScreenCaptureManager", "Surface became invalid before creating VirtualDisplay")
                mediaProjection.unregisterCallback(projectionCallback)
                handlerThread?.quitSafely()
                handlerThread = null
                handler = null
                imageReader?.close()
                imageReader = null
                return
            }
            
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "ScreenCapture",
                width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface, null, handler
            )
            if (virtualDisplay == null) {
                android.util.Log.e("ScreenCaptureManager", "Failed to create VirtualDisplay")
                mediaProjection.unregisterCallback(projectionCallback)
                handlerThread?.quitSafely()
                handlerThread = null
                handler = null
                imageReader?.close()
                imageReader = null
                return
            }
            
            // 验证 VirtualDisplay 是否成功创建
            if (virtualDisplay?.display == null) {
                android.util.Log.e("ScreenCaptureManager", "VirtualDisplay created but display is null")
                virtualDisplay?.release()
                virtualDisplay = null
                mediaProjection.unregisterCallback(projectionCallback)
                handlerThread?.quitSafely()
                handlerThread = null
                handler = null
                imageReader?.close()
                imageReader = null
                return
            }
            
            android.util.Log.d("ScreenCaptureManager", "VirtualDisplay created successfully: displayId=${virtualDisplay?.display?.displayId}")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error creating VirtualDisplay", e)
            mediaProjection.unregisterCallback(projectionCallback)
            handlerThread?.quitSafely()
            handlerThread = null
            handler = null
            imageReader?.close()
            imageReader = null
            return
        }

        isCapturing = true
        android.util.Log.d("ScreenCaptureManager", "Capture started successfully")
    }

    private suspend fun processImage(image: Image) = withContext(Dispatchers.IO) {
        var bitmap: Bitmap? = null
        var croppedBitmap: Bitmap? = null
        var scaledBitmap: Bitmap? = null
        var outputStream: ByteArrayOutputStream? = null
        
        try {
            // 检查图像是否已关闭
            if (image.format == 0) {
                android.util.Log.w("ScreenCaptureManager", "Image is already closed, skipping")
                return@withContext
            }
            
            android.util.Log.v("ScreenCaptureManager", "Processing image: ${image.width}x${image.height}, format=${image.format}, timestamp=${image.timestamp}")
            
            // 所有图像处理操作都在 IO 线程执行，不会阻塞主线程
            val planes = image.planes
            if (planes.isEmpty()) {
                android.util.Log.e("ScreenCaptureManager", "Image has no planes")
                return@withContext
            }
            
            val buffer = planes[0].buffer
            val pixelStride = planes[0].pixelStride
            val rowStride = planes[0].rowStride
            val rowPadding = rowStride - pixelStride * image.width

            // 创建 Bitmap（在 IO 线程）
            bitmap = Bitmap.createBitmap(
                image.width + rowPadding / pixelStride,
                image.height,
                Bitmap.Config.ARGB_8888
            )
            bitmap.copyPixelsFromBuffer(buffer)

            croppedBitmap = Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height)
            bitmap.recycle()
            bitmap = null // 标记已回收
            
            // ===================== 分辨率下采样：轻度优化，不缩放（100%） =====================
            // 【轻度优化】取消50%缩放，保持原始分辨率，提升清晰度
            // 【如需回滚】将下面的 1.0f 改为 0.5f 即可恢复原来的缩放
            val targetWidth = (image.width * 1.0f).toInt().coerceAtLeast(1)
            val targetHeight = (image.height * 1.0f).toInt().coerceAtLeast(1)
            scaledBitmap = Bitmap.createScaledBitmap(
                croppedBitmap,
                targetWidth,
                targetHeight,
                true  // 使用双线性插值，保证画质平滑
            )
            // 原分辨率的 Bitmap 不再需要，及时回收
            croppedBitmap.recycle()
            croppedBitmap = null

            // ===================== 图像压缩：JPEG 高质量（90%） =====================
            // 【优化】提高JPEG质量到90%，提升清晰度，减少压缩失真
            // 【如需回滚】将下面的 90 改为 75 即可恢复原来的压缩质量
            outputStream = ByteArrayOutputStream()
            val success = scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
            val imageBytes = if (success && outputStream.size() > 0) {
                outputStream.toByteArray()
            } else {
                android.util.Log.w("ScreenCaptureManager", "JPEG compression failed or empty")
                ByteArray(0)
            }
            
            scaledBitmap.recycle()
            scaledBitmap = null // 标记已回收
            outputStream.close()
            outputStream = null // 标记已关闭

            android.util.Log.v("ScreenCaptureManager", "Image processed: ${imageBytes.size} bytes, callback=${if (captureCallback != null) "not null" else "null"}")
            
            // 调用回调（回调本身会处理线程切换，这里在 IO 线程调用是安全的）
            // 注意：回调函数内部应该负责切换到正确的线程
            if (captureCallback != null) {
                captureCallback?.invoke(imageBytes)
            } else {
                android.util.Log.w("ScreenCaptureManager", "No callback set, dropping frame")
            }
        } catch (e: IllegalStateException) {
            android.util.Log.e("ScreenCaptureManager", "IllegalStateException processing image (image may be closed)", e)
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error processing image", e)
            e.printStackTrace()
        } finally {
            // 确保所有资源都被释放（即使在异常情况下）
            try {
                bitmap?.recycle()
            } catch (e: Exception) {
                android.util.Log.e("ScreenCaptureManager", "Error recycling bitmap", e)
            }
            try {
                croppedBitmap?.recycle()
            } catch (e: Exception) {
                android.util.Log.e("ScreenCaptureManager", "Error recycling croppedBitmap", e)
            }
            try {
                scaledBitmap?.recycle()
            } catch (e: Exception) {
                android.util.Log.e("ScreenCaptureManager", "Error recycling scaledBitmap", e)
            }
            try {
                outputStream?.close()
            } catch (e: Exception) {
                android.util.Log.e("ScreenCaptureManager", "Error closing outputStream", e)
            }
        }
    }

    fun stopCapture() {
        if (!isCapturing) {
            android.util.Log.d("ScreenCaptureManager", "stopCapture called but not capturing")
            return
        }

        android.util.Log.d("ScreenCaptureManager", "Stopping capture - starting resource cleanup")
        
        // 重置状态标志
        isCapturing = false
        lastFrameTime = 0
        isProcessingFrame = false
        
        // 按顺序清理资源（重要：必须按此顺序）
        // 1. 先停止 VirtualDisplay，停止推送新帧到 ImageReader
        try {
            virtualDisplay?.release()
            android.util.Log.d("ScreenCaptureManager", "VirtualDisplay released")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error releasing VirtualDisplay", e)
        } finally {
            virtualDisplay = null
        }
        
        // 2. 取消注册 MediaProjection 回调
        try {
            mediaProjection.unregisterCallback(projectionCallback)
            android.util.Log.d("ScreenCaptureManager", "MediaProjection callback unregistered")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error unregistering callback", e)
        }
        
        // 3. 关闭 ImageReader（必须先移除监听器，再关闭）
        try {
            imageReader?.setOnImageAvailableListener(null, null)
            android.util.Log.d("ScreenCaptureManager", "ImageReader listener removed")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error removing ImageReader listener", e)
        }
        
        try {
            imageReader?.close()
            android.util.Log.d("ScreenCaptureManager", "ImageReader closed")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error closing ImageReader", e)
        } finally {
            imageReader = null
        }
        
        // 4. 清理回调
        captureCallback = null
        
        // 5. 清理 Handler 和 HandlerThread
        handler = null
        try {
            handlerThread?.quitSafely()
            handlerThread?.join(1000) // 等待最多1秒
            android.util.Log.d("ScreenCaptureManager", "HandlerThread quit")
        } catch (e: Exception) {
            android.util.Log.e("ScreenCaptureManager", "Error quitting HandlerThread", e)
        } finally {
            handlerThread = null
        }
        
        android.util.Log.d("ScreenCaptureManager", "Capture stopped - all resources cleaned")
    }

    fun release() {
        stopCapture()
        scope.cancel()
    }
}

