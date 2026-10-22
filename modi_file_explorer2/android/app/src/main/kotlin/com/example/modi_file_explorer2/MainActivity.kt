package com.example.modi_file_explorer2

import android.content.pm.PackageManager
import android.app.AppOpsManager
import android.app.usage.StorageStatsManager
import android.content.Intent
import android.content.ComponentName
import android.content.ActivityNotFoundException
import android.net.Uri
import android.app.AlertDialog
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.media.MediaExtractor
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.storage.StorageManager
import android.provider.Settings
import android.view.Surface
import android.webkit.MimeTypeMap
import android.app.UiModeManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.common.util.UnstableApi
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileInputStream
import java.io.ByteArrayOutputStream
import java.net.URLConnection
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
	private val channelName = "modi_file_explorer2/installed_apps"
	private val storageChannelName = "modi_file_explorer2/storage_volumes"
	private val openWithChannelName = "modi_file_explorer2/open_with"
	private val navigationModeChannelName = "modi_file_explorer2/navigation_mode"
	private val videoMediaChannelName = "modi_file_explorer2/video_media"
	private val videoPlayerChannelName = "modi_file_explorer2/video_player"
	private val videoPlayerEventsChannelName = "modi_file_explorer2/video_player/events"
	private val videoPlayerHandler = Handler(Looper.getMainLooper())
	private var archivePlatformChannel: ArchivePlatformChannel? = null
	private var videoPlayerEventSink: EventChannel.EventSink? = null
	private var activeVideoPlayer: NativeVideoPlayer? = null
	private val videoMediaExecutor = ThreadPoolExecutor(
		3,
		3,
		0L,
		TimeUnit.MILLISECONDS,
		LinkedBlockingQueue(),
	)
	private val videoMediaRequests = ConcurrentHashMap<String, VideoMediaRequest>()
	private val packageQueryExecutor = Executors.newSingleThreadExecutor()
	private val installedAppIcons = ConcurrentHashMap<String, ByteArray>()
	private val apkFileIcons = ConcurrentHashMap<String, ByteArray>()
	private var pendingApkInstall: PendingApkInstall? = null

	private data class PendingApkInstall(
		val intent: Intent,
		val result: MethodChannel.Result,
		var awaitingSettingsReturn: Boolean = false,
	)

	private fun drawableToPng(drawable: android.graphics.drawable.Drawable, size: Int = 64): ByteArray {
		val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
		try {
			val canvas = Canvas(bitmap)
			drawable.setBounds(0, 0, size, size)
			drawable.draw(canvas)
			return ByteArrayOutputStream().use { output ->
				bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
				output.toByteArray()
			}
		} finally {
			bitmap.recycle()
		}
	}

	private fun resolveFileMimeType(file: File): String {
		val extensionMimeType = MimeTypeMap.getSingleton()
			.getMimeTypeFromExtension(file.extension.lowercase())
		if (!extensionMimeType.isNullOrBlank()) return extensionMimeType
		return try {
			FileInputStream(file).buffered().use { input ->
				URLConnection.guessContentTypeFromStream(input)
			} ?: "application/octet-stream"
		} catch (_: Exception) {
			"application/octet-stream"
		}
	}

	private fun installedAppIcon(packageName: String): ByteArray? {
		installedAppIcons[packageName]?.let { return it }
		return try {
			val icon = drawableToPng(packageManager.getApplicationIcon(packageName))
			installedAppIcons.putIfAbsent(packageName, icon) ?: icon
		} catch (_: Exception) {
			null
		}
	}

	private fun apkFileIcon(path: String, size: Int): ByteArray? {
		val file = File(path)
		if (!file.isFile || !file.canRead()) return null
		val iconSize = size.coerceIn(24, 128)
		val cacheKey =
			"${file.canonicalPath}:${file.length()}:${file.lastModified()}:$iconSize"
		apkFileIcons[cacheKey]?.let { return it }
		val diskFile = apkIconDiskFile(cacheKey)
		if (diskFile.isFile) {
			try {
				val icon = diskFile.readBytes()
				if (icon.isNotEmpty()) {
					diskFile.setLastModified(System.currentTimeMillis())
					rememberApkIcon(cacheKey, icon)
					return icon
				}
			} catch (error: Exception) {
				android.util.Log.w("MainActivity", "Could not read cached APK icon", error)
			}
			diskFile.delete()
		}
		return try {
			val packageInfo = packageManager.getPackageArchiveInfo(file.path, 0)
				?: return null
			val applicationInfo = packageInfo.applicationInfo ?: return null
			applicationInfo.sourceDir = file.path
			applicationInfo.publicSourceDir = file.path
			val icon = drawableToPng(
				packageManager.getApplicationIcon(applicationInfo),
				iconSize,
			)
			rememberApkIcon(cacheKey, icon)
			try {
				diskFile.parentFile?.mkdirs()
				diskFile.writeBytes(icon)
				trimApkIconDiskCache(diskFile.parentFile)
			} catch (error: Exception) {
				android.util.Log.w("MainActivity", "Could not cache APK icon", error)
			}
			icon
		} catch (error: Exception) {
			android.util.Log.w("MainActivity", "Could not read APK icon for $path", error)
			null
		}
	}

	private fun rememberApkIcon(cacheKey: String, icon: ByteArray) {
		if (apkFileIcons.size >= 128) {
			apkFileIcons.keys.firstOrNull()?.let(apkFileIcons::remove)
		}
		apkFileIcons[cacheKey] = icon
	}

	private fun apkIconDiskFile(cacheKey: String): File {
		val digest = MessageDigest.getInstance("SHA-256")
			.digest(cacheKey.toByteArray(Charsets.UTF_8))
			.joinToString("") { byte -> "%02x".format(byte) }
		return File(File(cacheDir, "apk_icon_thumbnails"), "$digest.png")
	}

	private fun trimApkIconDiskCache(directory: File?) {
		val files = directory?.listFiles()?.filter { it.isFile } ?: return
		var totalBytes = files.sumOf { it.length() }
		var fileCount = files.size
		for (file in files.sortedBy { it.lastModified() }) {
			if (totalBytes <= 8L * 1024 * 1024 && fileCount <= 128) break
			val fileBytes = file.length()
			if (file.delete()) {
				totalBytes -= fileBytes
				fileCount--
			}
		}
	}

	private fun hasUsageAccess(): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
		val appOps = getSystemService(AppOpsManager::class.java)
		@Suppress("DEPRECATION")
		return appOps.checkOpNoThrow(
			AppOpsManager.OPSTR_GET_USAGE_STATS,
			Process.myUid(),
			packageName,
		) == AppOpsManager.MODE_ALLOWED
	}

	private fun installedAppSize(packageName: String): Map<String, Any?> {
		val appInfo = packageManager.getApplicationInfo(packageName, 0)
		val apkBytes = (listOf(appInfo.sourceDir) + appInfo.splitSourceDirs.orEmpty())
			.sumOf { path -> File(path).length() }
		val totalBytes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && hasUsageAccess()) {
			try {
				getSystemService(StorageStatsManager::class.java)
					.queryStatsForPackage(
						android.os.storage.StorageManager.UUID_DEFAULT,
						packageName,
						Process.myUserHandle(),
					)
					.let { stats -> stats.appBytes + stats.dataBytes + stats.cacheBytes }
			} catch (_: Exception) {
				null
			}
		} else {
			null
		}
		return mapOf("apkBytes" to apkBytes, "totalBytes" to totalBytes)
	}

	@androidx.annotation.OptIn(UnstableApi::class)
	private inner class NativeVideoPlayer(
		private val sessionId: String,
		private val textureEntry: TextureRegistry.SurfaceTextureEntry,
		path: String,
		initialWidth: Int?,
		initialHeight: Int?,
		initialRotation: Int,
		initialResumePositionMilliseconds: Long,
	) : Player.Listener {
		private val textureSurface = Surface(textureEntry.surfaceTexture())
		private val player = ExoPlayer.Builder(this@MainActivity)
			.setHandleAudioBecomingNoisy(true)
			.build()
		private var width = initialWidth ?: 0
		private var height = initialHeight ?: 0
		private var rotationDegrees = initialRotation
		private var error: String? = null
		private var pendingResumePositionMilliseconds =
			initialResumePositionMilliseconds.coerceAtLeast(0L)
		private var resumeHandled = false
		private var resumedPositionMilliseconds = 0L
		private val originalWindowBrightness = window.attributes.screenBrightness
		private val positionUpdate = object : Runnable {
			override fun run() {
				if (activeVideoPlayer !== this@NativeVideoPlayer) return
				emit()
				videoPlayerHandler.postDelayed(this, 250)
			}
		}

		init {
			player.setAudioAttributes(
				AudioAttributes.Builder()
					.setUsage(C.USAGE_MEDIA)
					.setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
					.build(),
				true,
			)
			player.setVideoSurface(textureSurface)
			player.addListener(this)
			val file = File(path)
			if (!file.isFile) {
				error = "This device cannot play this video"
			} else {
				player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
				player.prepare()
			}
			videoPlayerHandler.post(positionUpdate)
		}

		override fun onIsPlayingChanged(isPlaying: Boolean) {
			if (isPlaying) {
				window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
			} else {
				window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
			}
			emit()
		}

		override fun onPlaybackStateChanged(playbackState: Int) {
			if (playbackState == Player.STATE_READY && !resumeHandled) {
				resumeHandled = true
				val duration = player.duration
				if (pendingResumePositionMilliseconds > 5_000L &&
					duration > 0L &&
					pendingResumePositionMilliseconds < duration - 10_000L
				) {
					resumedPositionMilliseconds = pendingResumePositionMilliseconds
					player.seekTo(pendingResumePositionMilliseconds)
				}
				player.play()
			}
			emit()
		}

		override fun onVideoSizeChanged(videoSize: VideoSize) {
			width = videoSize.width
			height = videoSize.height
			rotationDegrees = videoSize.unappliedRotationDegrees
			emit()
		}

		override fun onPlayerError(playbackError: PlaybackException) {
			error = "This device cannot play this video"
			emit()
		}

		fun pauseForBackground() {
			player.pause()
		}

		fun sessionMatches(candidate: String?): Boolean = candidate == sessionId

		fun command(method: String, arguments: Map<*, *>) {
			when (method) {
				"play" -> player.play()
				"pause" -> player.pause()
				"seek" -> player.seekTo((arguments["positionMilliseconds"] as? Number)?.toLong() ?: 0L)
				"setSpeed" -> {
					val speed = (arguments["speed"] as? Number)?.toFloat() ?: 1f
					player.playbackParameters = PlaybackParameters(speed, 1f)
				}
				"setVolume" -> player.volume = (
					(arguments["volume"] as? Number)?.toFloat() ?: 1f
				).coerceIn(0f, 1f)
				"setWindowBrightness" -> {
					val brightness = (arguments["brightness"] as? Number)?.toFloat() ?: 0.5f
					window.attributes = window.attributes.apply {
						screenBrightness = brightness.coerceIn(0.01f, 1f)
					}
				}
				"restoreWindowBrightness" -> {
					window.attributes = window.attributes.apply {
						screenBrightness = originalWindowBrightness
					}
				}
				"setMediaVolume" -> {
					val audioManager = getSystemService(AudioManager::class.java)
					val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
					val target = (
						((arguments["volume"] as? Number)?.toFloat() ?: 0.5f) * maximum
					).toInt().coerceIn(0, maximum)
					audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
				}
				"setSource" -> setSource(arguments)
			}
		}

		private fun setSource(arguments: Map<*, *>) {
			val path = arguments["path"] as? String
			if (path.isNullOrBlank() || !File(path).isFile) {
				error = "This device cannot play this video"
				emit()
				return
			}
			error = null
			pendingResumePositionMilliseconds =
				(arguments["resumePositionMilliseconds"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
			resumeHandled = false
			resumedPositionMilliseconds = 0L
			width = (arguments["width"] as? Number)?.toInt() ?: 0
			height = (arguments["height"] as? Number)?.toInt() ?: 0
			rotationDegrees = (arguments["rotationDegrees"] as? Number)?.toInt() ?: 0
			player.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
			player.prepare()
			player.play()
			emit()
		}

		fun emit() {
			val duration = player.duration.takeIf { it >= 0L } ?: 0L
			videoPlayerEventSink?.success(
				mapOf(
					"sessionId" to sessionId,
					"isReady" to (
						error == null &&
							(player.playbackState == Player.STATE_READY ||
								player.playbackState == Player.STATE_ENDED)
					),
					"isPlaying" to player.isPlaying,
					"isEnded" to (player.playbackState == Player.STATE_ENDED),
					"positionMilliseconds" to player.currentPosition,
					"durationMilliseconds" to duration,
					"width" to width,
					"height" to height,
					"rotationDegrees" to rotationDegrees,
					"resumedPositionMilliseconds" to resumedPositionMilliseconds,
					"error" to error,
				),
			)
		}

		fun release() {
			videoPlayerHandler.removeCallbacks(positionUpdate)
			player.removeListener(this)
			player.release()
			textureSurface.release()
			textureEntry.release()
			window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
			window.attributes = window.attributes.apply {
				screenBrightness = originalWindowBrightness
			}
		}
	}

	private class VideoMediaRequest(
		val future: FutureTask<Unit>,
		val result: MethodChannel.Result,
	) {
		val completed = AtomicBoolean(false)

		fun cancel() {
			future.cancel(true)
			if (completed.compareAndSet(false, true)) {
				result.error("CANCELLED", "Video media request was cancelled", null)
			}
		}
	}

	private fun runVideoMediaRequest(
		requestId: String,
		result: MethodChannel.Result,
		block: () -> Any?,
	) {
		if (requestId.isBlank()) {
			result.error("INVALID_ARGUMENT", "A video media request id is required", null)
			return
		}
		val task = FutureTask<Unit> {
			try {
				val value = block()
				val request = videoMediaRequests[requestId]
				if (!Thread.currentThread().isInterrupted &&
					request?.completed?.compareAndSet(false, true) == true
				) {
					result.success(value)
				}
			} catch (error: Exception) {
				val request = videoMediaRequests[requestId]
				if (!Thread.currentThread().isInterrupted &&
					request?.completed?.compareAndSet(false, true) == true
				) {
					result.error("VIDEO_MEDIA_FAILED", error.message ?: "Could not read video media", null)
				}
			} finally {
				videoMediaRequests.remove(requestId)
			}
		}
		val request = VideoMediaRequest(task, result)
		if (videoMediaRequests.putIfAbsent(requestId, request) != null) {
			result.error("DUPLICATE_REQUEST", "Video media request id is already active", null)
			return
		}
		videoMediaExecutor.execute(task)
	}

	private fun readVideoInformation(path: String): Map<String, Any?> {
		val retriever = MediaMetadataRetriever()
		try {
			retriever.setDataSource(path)
			val duration = retriever.extractMetadata(
				MediaMetadataRetriever.METADATA_KEY_DURATION,
			)?.toLongOrNull()
			val width = retriever.extractMetadata(
				MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
			)?.toIntOrNull()
			val height = retriever.extractMetadata(
				MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
			)?.toIntOrNull()
			val rotation = retriever.extractMetadata(
				MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
			)?.toIntOrNull() ?: 0
			val frameRate = readVideoFrameRate(path)
			return mapOf(
				"durationMilliseconds" to duration,
				"width" to width,
				"height" to height,
				"rotationDegrees" to rotation,
				"frameRate" to frameRate,
			)
		} finally {
			retriever.release()
		}
	}

	private fun readVideoFrameRate(path: String): Double? {
		val extractor = MediaExtractor()
		try {
			extractor.setDataSource(path)
			for (trackIndex in 0 until extractor.trackCount) {
				val format = extractor.getTrackFormat(trackIndex)
				if (!format.getString(MediaFormat.KEY_MIME).orEmpty().startsWith("video/")) continue
				if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) return null
				val rate = format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
				return rate.takeIf { it.isFinite() && it > 0.0 }
			}
			return null
		} finally {
			extractor.release()
		}
	}

	private fun generateVideoThumbnail(path: String, width: Int, height: Int): ByteArray? {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return null
		val retriever = MediaMetadataRetriever()
		try {
			retriever.setDataSource(path)
			val frame = retriever.getScaledFrameAtTime(
				0L,
				MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
				width.coerceIn(1, 640),
				height.coerceIn(1, 640),
			) ?: return null
			val rotation = retriever.extractMetadata(
				MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
			)?.toFloatOrNull() ?: 0f
			val displayFrame = if (rotation % 360f == 0f) {
				frame
			} else {
				Bitmap.createBitmap(
				frame,
				0,
				0,
				frame.width,
				frame.height,
				Matrix().apply { postRotate(rotation) },
				true,
				).also { frame.recycle() }
			}
			return try {
				ByteArrayOutputStream().use { output ->
				if (!displayFrame.compress(Bitmap.CompressFormat.JPEG, 82, output)) {
					return null
				}
				output.toByteArray()
				}
			} finally {
				displayFrame.recycle()
			}
		} finally {
			retriever.release()
		}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		val darkTheme = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
			.getString("flutter.theme.mode", "light") == "dark"
		applyApplicationNightMode(darkTheme)
		setTheme(if (darkTheme) R.style.LaunchThemeDark else R.style.LaunchThemeLight)
		super.onCreate(savedInstanceState)
	}

	override fun onResume() {
		super.onResume()
		val pending = pendingApkInstall ?: return
		if (!pending.awaitingSettingsReturn) return
		pending.awaitingSettingsReturn = false
		pendingApkInstall = null
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
			packageManager.canRequestPackageInstalls()
		) {
			launchApkInstall(pending.intent, pending.result)
		} else {
			pending.result.error(
				"UNKNOWN_SOURCES_NOT_ALLOWED",
				"Allow this app to install unknown apps in Android settings, then try again.",
				null,
			)
		}
	}

	private fun requestUnknownSourcesPermission(
		intent: Intent,
		result: MethodChannel.Result,
	) {
		if (pendingApkInstall != null) {
			result.error(
				"INSTALL_ALREADY_PENDING",
				"Another APK installation is already waiting for permission.",
				null,
			)
			return
		}
		val pending = PendingApkInstall(intent, result)
		pendingApkInstall = pending
		AlertDialog.Builder(this)
			.setTitle("Allow APK installation")
			.setMessage(
				"Android requires permission to install apps from this file manager. " +
					"Allow installs for this app in the next screen; installation will continue when you return.",
			)
			.setNegativeButton("Cancel") { _, _ ->
				if (pendingApkInstall === pending) pendingApkInstall = null
				result.error("INSTALL_CANCELLED", "APK installation was canceled.", null)
			}
			.setPositiveButton("Open settings") { _, _ ->
				pending.awaitingSettingsReturn = true
				try {
					startActivity(
						Intent(
							Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
							Uri.parse("package:$packageName"),
						),
					)
				} catch (error: Exception) {
					pendingApkInstall = null
					result.error(
						"UNKNOWN_SOURCES_SETTINGS_UNAVAILABLE",
						error.message ?: "Could not open Install unknown apps settings.",
						null,
					)
				}
			}
			.setOnCancelListener {
				if (pendingApkInstall === pending) pendingApkInstall = null
				result.error("INSTALL_CANCELLED", "APK installation was canceled.", null)
			}
			.show()
	}

	private fun launchApkInstall(intent: Intent, result: MethodChannel.Result) {
		try {
			if (intent.resolveActivity(packageManager) == null) {
				result.error(
					"INSTALLER_UNAVAILABLE",
					"No Android package installer can handle this APK.",
					null,
				)
				return
			}
			startActivity(intent)
			result.success(true)
		} catch (error: ActivityNotFoundException) {
			result.error(
				"INSTALLER_UNAVAILABLE",
				"No Android package installer can handle this APK.",
				null,
			)
		} catch (error: SecurityException) {
			result.error(
				"INSTALL_PERMISSION_DENIED",
				error.message
					?: "Android denied permission to install this APK. Check Install unknown apps settings.",
				null,
			)
		} catch (error: Exception) {
			result.error(
				"APK_INSTALL_FAILED",
				error.message ?: "Android could not start the APK installer.",
				null,
			)
		}
	}

	private fun applyApplicationNightMode(darkTheme: Boolean) {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
			val uiModeManager = getSystemService(UiModeManager::class.java)
			uiModeManager.setApplicationNightMode(
				if (darkTheme) UiModeManager.MODE_NIGHT_YES
				else UiModeManager.MODE_NIGHT_NO,
			)
		}
	}

	private fun queryActivities(
		intent: Intent,
		matchDefaultOnly: Boolean = true,
	) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
		packageManager.queryIntentActivities(
			intent,
			PackageManager.ResolveInfoFlags.of(
				(if (matchDefaultOnly) PackageManager.MATCH_DEFAULT_ONLY else 0).toLong(),
			),
		)
	} else {
		@Suppress("DEPRECATION")
		packageManager.queryIntentActivities(
			intent,
			if (matchDefaultOnly) PackageManager.MATCH_DEFAULT_ONLY else 0,
		)
	}

	private fun viewIntent(mimeType: String, uri: Uri): Intent = Intent(Intent.ACTION_VIEW).apply {
		setDataAndType(uri, mimeType)
		addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
	}

	private fun openWithActivity(resolveInfo: android.content.pm.ResolveInfo, mimeType: String): Map<String, Any?>? {
		val activity = resolveInfo.activityInfo ?: return null
		val appLabel = packageManager.getApplicationLabel(activity.applicationInfo).toString()
		val activityLabel = resolveInfo.loadLabel(packageManager)?.toString()?.takeIf { it.isNotBlank() }
			?: activity.name.substringAfterLast('.')
		val featureLabel = if (activityLabel.equals(appLabel, ignoreCase = true)) {
			"$appLabel — ${activity.name.substringAfterLast('.')}"
		} else {
			"$appLabel — $activityLabel"
		}
		val icon = try {
			val drawable = resolveInfo.loadIcon(packageManager)
			val size = 96
			val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
			val canvas = Canvas(bitmap)
			drawable.setBounds(0, 0, size, size)
			drawable.draw(canvas)
			ByteArrayOutputStream().use { output ->
				bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
				bitmap.recycle()
				output.toByteArray()
			}
		} catch (_: Exception) {
			null
		}
		return mapOf(
			"name" to featureLabel,
			"applicationName" to appLabel,
			"packageName" to activity.packageName,
			"activityName" to activity.name,
			"mimeType" to mimeType,
			"icon" to icon,
		)
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		archivePlatformChannel = ArchivePlatformChannel(
			this,
			flutterEngine.dartExecutor.binaryMessenger,
		)

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, videoPlayerEventsChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
					videoPlayerEventSink = events
					activeVideoPlayer?.emit()
				}

				override fun onCancel(arguments: Any?) {
					videoPlayerEventSink = null
				}
			})

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, videoPlayerChannelName)
			.setMethodCallHandler { call, result ->
				try {
					when (call.method) {
						"create" -> {
							val arguments = call.arguments as? Map<*, *>
							val sessionId = arguments?.get("sessionId") as? String
							val path = arguments?.get("path") as? String
							if (sessionId.isNullOrBlank() || path.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A player session and file path are required", null)
								return@setMethodCallHandler
							}
							activeVideoPlayer?.release()
							val textureEntry = flutterEngine.renderer.createSurfaceTexture()
							val player = NativeVideoPlayer(
								sessionId = sessionId,
								textureEntry = textureEntry,
								path = path,
								initialWidth = (arguments["width"] as? Number)?.toInt(),
								initialHeight = (arguments["height"] as? Number)?.toInt(),
								initialRotation = (arguments["rotationDegrees"] as? Number)?.toInt() ?: 0,
								initialResumePositionMilliseconds =
									(arguments["resumePositionMilliseconds"] as? Number)?.toLong() ?: 0L,
							)
							activeVideoPlayer = player
							result.success(mapOf("textureId" to textureEntry.id()))
							player.emit()
						}
						"dispose" -> {
							val sessionId = (call.arguments as? Map<*, *>)?.get("sessionId") as? String
							if (activeVideoPlayer?.sessionMatches(sessionId) == true) {
								activeVideoPlayer?.release()
								activeVideoPlayer = null
							}
							result.success(null)
						}
						else -> {
							val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
							val sessionId = arguments["sessionId"] as? String
							val player = activeVideoPlayer
							if (player == null || !player.sessionMatches(sessionId)) {
								result.error("PLAYER_UNAVAILABLE", "The video player is no longer available", null)
							} else {
								if (call.method == "getMediaVolume") {
									val audioManager = getSystemService(AudioManager::class.java)
									result.success(
										audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() /
											audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1),
									)
									return@setMethodCallHandler
								}
								if (call.method == "getWindowBrightness") {
									val brightness = window.attributes.screenBrightness
									result.success(if (brightness < 0f) 0.5f else brightness)
									return@setMethodCallHandler
								}
								player.command(call.method, arguments)
								result.success(null)
							}
						}
					}
				} catch (error: Exception) {
					result.error("VIDEO_PLAYER_FAILED", error.message ?: "Could not control video playback", null)
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navigationModeChannelName)
			.setMethodCallHandler { call, result ->
				if (call.method != "isButtonNavigationEnabled") {
					result.notImplemented()
					return@setMethodCallHandler
				}

				val tappableNavigationInset = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
					window.decorView.rootWindowInsets
						?.getInsets(android.view.WindowInsets.Type.tappableElement())
						?.bottom
				} else {
					null
				}
				val hasButtonNavigation = tappableNavigationInset?.let { it > 0 }
					?: (Settings.Secure.getInt(contentResolver, "navigation_mode", 0) != 2)
				result.success(hasButtonNavigation)
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "modi_file_explorer2/app_theme")
			.setMethodCallHandler { call, result ->
				if (call.method != "setDarkTheme") {
					result.notImplemented()
					return@setMethodCallHandler
				}
				val darkTheme = call.argument<Boolean>("enabled")
				if (darkTheme == null) {
					result.error("INVALID_ARGUMENT", "Theme mode is required", null)
					return@setMethodCallHandler
				}
				applyApplicationNightMode(darkTheme)
				result.success(null)
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				if (call.method == "hasUsageAccess") {
					result.success(hasUsageAccess())
					return@setMethodCallHandler
				}
				if (call.method == "openUsageAccessSettings") {
					try {
						startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
						result.success(null)
					} catch (error: Exception) {
						result.error("USAGE_SETTINGS_UNAVAILABLE", error.message, null)
					}
					return@setMethodCallHandler
				}
				if (call.method == "getApkIcon") {
					val path = call.argument<String>("path")
					val size = call.argument<Int>("size") ?: 64
					if (path.isNullOrBlank()) {
						result.error("INVALID_ARGUMENT", "An APK path is required", null)
						return@setMethodCallHandler
					}
					packageQueryExecutor.execute {
						try {
							val icon = apkFileIcon(path, size)
							runOnUiThread { result.success(icon) }
						} catch (error: Exception) {
							runOnUiThread {
								result.error("APK_ICON_UNAVAILABLE", error.message, null)
							}
						}
					}
					return@setMethodCallHandler
				}
				if (call.method == "getInstalledAppIcon" ||
					call.method == "getInstalledAppSize"
				) {
					val targetPackage = call.argument<String>("packageName")
					if (targetPackage.isNullOrBlank()) {
						result.error("INVALID_ARGUMENT", "An app package is required", null)
						return@setMethodCallHandler
					}
					packageQueryExecutor.execute {
						try {
							val value = if (call.method == "getInstalledAppIcon") {
								installedAppIcon(targetPackage)
									?: throw IllegalStateException("Could not load the app icon")
							} else {
								installedAppSize(targetPackage)
							}
							runOnUiThread { result.success(value) }
						} catch (error: Exception) {
							runOnUiThread {
								result.error(
									if (call.method == "getInstalledAppIcon") {
										"APP_ICON_UNAVAILABLE"
									} else {
										"APP_SIZE_UNAVAILABLE"
									},
									error.message,
									null,
								)
							}
						}
					}
					return@setMethodCallHandler
				}
				if (call.method != "listInstalledApps") {
					result.notImplemented()
					return@setMethodCallHandler
				}

				packageQueryExecutor.execute {
					try {
						val launcherIntent = Intent(Intent.ACTION_MAIN)
							.addCategory(Intent.CATEGORY_LAUNCHER)
						val apps = queryActivities(launcherIntent, matchDefaultOnly = false)
							.mapNotNull { resolveInfo ->
								val info = resolveInfo.activityInfo?.applicationInfo ?: return@mapNotNull null
								val version = try {
									packageManager.getPackageInfo(info.packageName, 0).versionName ?: "Unknown version"
								} catch (_: PackageManager.NameNotFoundException) {
									"Unknown version"
								}
								mapOf(
									"name" to packageManager.getApplicationLabel(info).toString(),
									"packageName" to info.packageName,
									"version" to version,
								)
							}
							.distinctBy { it["packageName"] }
							.sortedBy { it["name"].toString().lowercase() }
						runOnUiThread { result.success(apps) }
					} catch (error: Exception) {
						runOnUiThread {
							result.error("APPS_UNAVAILABLE", error.message, null)
						}
					}
				}

			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, openWithChannelName)
			.setMethodCallHandler { call, result ->
				try {
					when (call.method) {
						"listOpenWithAppsForType" -> {
							val extension = call.argument<String>("extension")?.removePrefix(".")
							val category = call.argument<String>("category")
							if (extension.isNullOrBlank() || category.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A file extension and category are required", null)
								return@setMethodCallHandler
							}
							val mimeType = MimeTypeMap.getSingleton()
								.getMimeTypeFromExtension(extension.lowercase())
								?: "application/octet-stream"
							val apps = linkedMapOf<String, Map<String, Any?>>()
							val intent = Intent(Intent.ACTION_VIEW).setType(mimeType)
							for (resolveInfo in queryActivities(intent)) {
								val activity = resolveInfo.activityInfo ?: continue
								if (activity.packageName == packageName) continue
								val key = "${activity.packageName}/${activity.name}"
								if (!apps.containsKey(key)) {
									openWithActivity(resolveInfo, mimeType)?.let { apps[key] = it }
								}
							}
							result.success(apps.values.sortedBy { it["name"]?.toString()?.lowercase() })
						}
						"listOpenWithApps" -> {
							val path = call.argument<String>("path")
							val category = call.argument<String>("category")
							if (path.isNullOrBlank() || category.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A file path and category are required", null)
								return@setMethodCallHandler
							}
							val file = File(path)
							if (!file.isFile) {
								result.error("FILE_UNAVAILABLE", "The selected file is unavailable", null)
								return@setMethodCallHandler
							}
							val authority = "$packageName.fileprovider"
							val uri = FileProvider.getUriForFile(this, authority, file)
							val appMimeType = resolveFileMimeType(file)
							val apps = linkedMapOf<String, Map<String, Any?>>()
							val intent = viewIntent(appMimeType, uri)
							for (resolveInfo in queryActivities(intent)) {
								val activity = resolveInfo.activityInfo ?: continue
								if (activity.packageName == this.packageName) continue
								val key = "${activity.packageName}/${activity.name}"
								if (!apps.containsKey(key)) {
									openWithActivity(resolveInfo, appMimeType)?.let { apps[key] = it }
								}
							}
							result.success(apps.values.sortedBy { it["name"]?.toString()?.lowercase() })
						}
						"resolveOpenWithAppName" -> {
							val targetPackage = call.argument<String>("packageName")
							if (targetPackage.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "An app package is required", null)
								return@setMethodCallHandler
							}
							val appInfo = try {
								packageManager.getApplicationInfo(targetPackage, 0)
							} catch (_: PackageManager.NameNotFoundException) {
								null
							}
							result.success(appInfo?.let { packageManager.getApplicationLabel(it).toString() })
						}
						"getOwnApplicationIcon" -> {
							val drawable = packageManager.getApplicationIcon(packageName)
							val size = 96
							val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
							val canvas = Canvas(bitmap)
							drawable.setBounds(0, 0, size, size)
							drawable.draw(canvas)
							val bytes = ByteArrayOutputStream().use { output ->
								bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
								output.toByteArray()
							}
							bitmap.recycle()
							result.success(bytes)
						}
						"openWithApp" -> {
							val path = call.argument<String>("path")
							val category = call.argument<String>("category")
							val targetPackage = call.argument<String>("packageName")
							val targetActivity = call.argument<String>("activityName")
							val mimeType = call.argument<String>("mimeType")
							if (path.isNullOrBlank() || category.isNullOrBlank() || targetPackage.isNullOrBlank() || mimeType.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A file path, category, and app are required", null)
								return@setMethodCallHandler
							}
							val file = File(path)
							if (!file.isFile) {
								result.error("FILE_UNAVAILABLE", "The selected file is unavailable", null)
								return@setMethodCallHandler
							}
							val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
							val isApkInstall = mimeType.equals(
								"application/vnd.android.package-archive",
								ignoreCase = true,
							)
							val intent = if (isApkInstall) {
								Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
									setDataAndType(uri, mimeType)
									addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
									if (targetActivity.isNullOrBlank()) {
										setPackage(targetPackage)
									} else {
										component = ComponentName(targetPackage, targetActivity)
									}
								}
							} else {
								viewIntent(mimeType, uri).apply {
									if (targetActivity.isNullOrBlank()) {
										setPackage(targetPackage)
									} else {
										component = ComponentName(targetPackage, targetActivity)
									}
								}
							}
							if (isApkInstall) {
								grantUriPermission(
									targetPackage,
									uri,
									Intent.FLAG_GRANT_READ_URI_PERMISSION,
								)
								if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
									!packageManager.canRequestPackageInstalls()
								) {
									requestUnknownSourcesPermission(intent, result)
									return@setMethodCallHandler
								}
								launchApkInstall(intent, result)
								return@setMethodCallHandler
							}
							if (intent.resolveActivity(packageManager) == null) {
								result.error("APP_UNAVAILABLE", "The selected app is no longer available", null)
								return@setMethodCallHandler
							}
							try {
								startActivity(intent)
							} catch (_: ActivityNotFoundException) {
								result.error("APP_UNAVAILABLE", "The selected app is no longer available", null)
								return@setMethodCallHandler
							}
							result.success(true)
						}
						else -> result.notImplemented()
					}
				} catch (error: SecurityException) {
					result.error(
						"OPEN_WITH_PERMISSION_DENIED",
						error.message ?: "Android denied access to this file",
						null,
					)
				} catch (error: Exception) {
					result.error("OPEN_WITH_FAILED", error.message ?: "Could not open this file", null)
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
			.setMethodCallHandler { call, result ->
				if (call.method == "openStorageAccessSettings") {
					try {
						val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
							Intent(
								Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
								Uri.parse("package:$packageName"),
							)
						} else {
							Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
								data = Uri.parse("package:$packageName")
							}
						}
						startActivity(intent)
						result.success(true)
					} catch (error: Exception) {
						result.error("STORAGE_SETTINGS_UNAVAILABLE", error.message, null)
					}
					return@setMethodCallHandler
				}

				if (call.method != "listStorageVolumes") {
					result.notImplemented()
					return@setMethodCallHandler
				}

				try {
					val storageManager = getSystemService(StorageManager::class.java)
					val volumes = storageManager.storageVolumes.mapNotNull { volume ->
						val directory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
							volume.directory
						} else {
							volume.uuid?.let { File("/storage/$it") }
						}
						if (directory == null || !directory.exists()) return@mapNotNull null
						mapOf(
							"path" to directory.absolutePath,
							"uuid" to volume.uuid,
							"description" to (volume.getDescription(this) ?: "Storage"),
							"isPrimary" to volume.isPrimary,
							"isRemovable" to volume.isRemovable,
						)
					}
					result.success(volumes)
				} catch (error: Exception) {
					result.error("STORAGE_VOLUMES_UNAVAILABLE", error.message, null)
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, videoMediaChannelName)
				.setMethodCallHandler { call, result ->
					when (call.method) {
						"readVideoInformation" -> {
							val requestId = call.argument<String>("requestId")
							val path = call.argument<String>("path")
							if (requestId.isNullOrBlank() || path.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A request id and video path are required", null)
								return@setMethodCallHandler
							}
							runVideoMediaRequest(requestId, result) {
								readVideoInformation(path)
							}
						}
						"generateVideoThumbnail" -> {
							val requestId = call.argument<String>("requestId")
							val path = call.argument<String>("path")
							val width = call.argument<Int>("width")
							val height = call.argument<Int>("height")
							if (requestId.isNullOrBlank() || path.isNullOrBlank() ||
								width == null || height == null
							) {
								result.error("INVALID_ARGUMENT", "A request id, path and thumbnail size are required", null)
								return@setMethodCallHandler
							}
							runVideoMediaRequest(requestId, result) {
								generateVideoThumbnail(path, width, height)
							}
						}
						"cancelVideoRequest" -> {
							val requestId = call.argument<String>("requestId")
							if (requestId.isNullOrBlank()) {
								result.error("INVALID_ARGUMENT", "A video media request id is required", null)
								return@setMethodCallHandler
							}
							videoMediaRequests.remove(requestId)?.cancel()
							result.success(null)
						}
						else -> result.notImplemented()
					}
				}
	}

	override fun onPause() {
		activeVideoPlayer?.pauseForBackground()
		super.onPause()
	}

	override fun onDestroy() {
		activeVideoPlayer?.release()
		activeVideoPlayer = null
		super.onDestroy()
	}
}
