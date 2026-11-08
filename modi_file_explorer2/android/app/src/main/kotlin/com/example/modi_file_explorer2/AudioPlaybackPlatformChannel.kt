package com.example.modi_file_explorer2

import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor

class AudioPlaybackPlatformChannel(
	private val context: Context,
	binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
	private val mainExecutor = Executor { command ->
		android.os.Handler(context.mainLooper).post(command)
	}

	private fun getArtwork(call: MethodCall, result: MethodChannel.Result) {
		val path = call.arguments as? String
		if (path.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "An audio file path is required", null)
			return
		}
		artworkExecutor.execute {
			val retriever = MediaMetadataRetriever()
			try {
				val file = File(path)
				if (!file.isFile) {
					result.success(null)
					return@execute
				}
				retriever.setDataSource(path)
				result.success(retriever.embeddedPicture)
			} catch (error: Exception) {
				Log.w(TAG, "Could not read embedded audio artwork from $path", error)
				result.success(null)
			} finally {
				retriever.release()
			}
		}
	}
	private val positionHandler = android.os.Handler(context.mainLooper)
	private val artworkExecutor = Executors.newSingleThreadExecutor()
	private val positionUpdate = object : Runnable {
		override fun run() {
			controller?.let { emitState(it) }
			if (eventSink != null) {
				positionHandler.postDelayed(this, POSITION_UPDATE_INTERVAL_MS)
			}
		}
	}

	fun onNotificationTapped() {
		pendingNotificationTap = true
		controller?.let { emitState(it, notificationTapped = true) }
			?: eventSink?.success(mapOf("notificationTapped" to true))
		pendingNotificationTap = false
	}
	private val methods = MethodChannel(binaryMessenger, METHOD_CHANNEL)
	private val events = EventChannel(binaryMessenger, EVENT_CHANNEL)
	private var controllerFuture: ListenableFuture<MediaController>? = null
	private var controller: MediaController? = null
	private var eventSink: EventChannel.EventSink? = null
	private var lastError: String? = null
	private var pendingNotificationTap =
		(context as? android.app.Activity)?.intent
			?.getBooleanExtra(EXTRA_OPEN_AUDIO_TAB, false) == true
	private val stopReceiver = object : BroadcastReceiver() {
		override fun onReceive(context: Context?, intent: Intent?) {
			eventSink?.success(mapOf("isStopped" to true))
		}
	}

	init {
		methods.setMethodCallHandler(this)
		events.setStreamHandler(this)
		ContextCompat.registerReceiver(
			context,
			stopReceiver,
			IntentFilter(ACTION_STOPPED),
			ContextCompat.RECEIVER_NOT_EXPORTED,
		)
	}

	fun dispose() {
		artworkExecutor.shutdownNow()
		releaseController()
		context.unregisterReceiver(stopReceiver)
		methods.setMethodCallHandler(null)
		events.setStreamHandler(null)
	}

	override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"playQueue" -> playQueue(call, result)
			"getArtwork" -> getArtwork(call, result)
			"getPlaybackState" -> withController(result) { mediaController ->
				result.success(playbackState(mediaController))
			}
			"togglePlayback" -> withController(result) { mediaController ->
				if (mediaController.isPlaying) {
					mediaController.pause()
				} else {
					mediaController.play()
				}
				result.success(null)
			}
			"seekTo" -> withController(result) { mediaController ->
				val position = (call.arguments as? Number)?.toLong()
				if (position == null || position < 0L) {
					result.error("INVALID_ARGUMENT", "A non-negative seek position is required", null)
				} else {
					mediaController.seekTo(position)
					result.success(null)
				}
			}
			"skipPrevious" -> withController(result) { mediaController ->
				if (mediaController.currentPosition > PREVIOUS_RESTART_THRESHOLD_MS ||
					!mediaController.hasPreviousMediaItem()
				) {
					mediaController.seekTo(0L)
				} else {
					mediaController.seekToPreviousMediaItem()
				}
				result.success(null)
			}
			"skipNext" -> withController(result) { mediaController ->
				if (mediaController.hasNextMediaItem()) {
					mediaController.seekToNextMediaItem()
				}
				result.success(null)
			}
			"renameQueuedTrack" -> renameQueuedTrack(call, result)
			"removeQueuedTrack" -> removeQueuedTrack(call, result)
			"stopPlayback" -> stopPlayback(result)
			else -> result.notImplemented()
		}
	}

	override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
		eventSink = events
		controller?.let { emitState(it, notificationTapped = pendingNotificationTap) }
		positionHandler.removeCallbacks(positionUpdate)
		positionHandler.post(positionUpdate)
		if (pendingNotificationTap) {
			pendingNotificationTap = false
		}
	}

	override fun onCancel(arguments: Any?) {
		eventSink = null
		positionHandler.removeCallbacks(positionUpdate)
	}

	private fun playQueue(call: MethodCall, result: MethodChannel.Result) {
		val arguments = call.arguments as? Map<*, *>
		val rawTracks = arguments?.get("tracks") as? List<*>
		val currentIndex = (arguments?.get("currentIndex") as? Number)?.toInt()
		val mode = arguments?.get("mode") as? String ?: "folder"
		val preservePlayback = arguments?.get("preservePlayback") as? Boolean ?: false
		val modeLabel = if (mode == "singleTrack") "This audio" else "All in folder"
		if (rawTracks.isNullOrEmpty() || currentIndex == null ||
			currentIndex !in rawTracks.indices
		) {
			result.error("INVALID_ARGUMENT", "An audio track list and current index are required", null)
			return
		}

		val items = rawTracks.mapIndexed { index, raw ->
			val track = raw as? Map<*, *>
			val path = track?.get("path") as? String
			val title = track?.get("title") as? String
			val folder = track?.get("folder") as? String
			if (path.isNullOrBlank() || title.isNullOrBlank() || folder.isNullOrBlank()) {
				result.error("INVALID_ARGUMENT", "Audio track $index is incomplete", null)
				return
			}
			MediaItem.Builder()
				.setMediaId(path)
				.setUri(Uri.fromFile(File(path)))
				.setMediaMetadata(
					MediaMetadata.Builder()
						.setTitle(title)
						.setArtist("$folder · $modeLabel")
						.setAlbumArtist(folder)
						.setAlbumTitle(modeLabel)
						.build(),
				)
				.build()
		}

		withController(result) { mediaController ->
			lastError = null
			val previousPath = mediaController.currentMediaItem
				?.localConfiguration?.uri?.path
			if (preservePlayback &&
				previousPath == items[currentIndex].localConfiguration?.uri?.path
			) {
				val sameQueue = mediaController.mediaItemCount == items.size &&
					items.indices.all { index ->
						mediaController.getMediaItemAt(index).localConfiguration?.uri?.path ==
							items[index].localConfiguration?.uri?.path
					}
				val currentMode = if (
					mediaController.currentMediaItem?.mediaMetadata?.albumTitle
						?.toString() == "This audio"
				) "singleTrack" else "folder"
				if (sameQueue && currentMode == mode) {
					result.success(null)
					return@withController
				}
				val selectedIndex = items.indexOfFirst {
					it.localConfiguration?.uri?.path == previousPath
				}
				val existingIndex = (0 until mediaController.mediaItemCount)
					.firstOrNull {
						mediaController.getMediaItemAt(it).localConfiguration?.uri?.path ==
							previousPath
					}
				if (selectedIndex >= 0 && existingIndex != null) {
					for (index in mediaController.mediaItemCount - 1 downTo 0) {
						if (index != existingIndex) mediaController.removeMediaItem(index)
					}
					mediaController.replaceMediaItem(0, items[selectedIndex])
					if (selectedIndex > 0) {
						mediaController.addMediaItems(0, items.subList(0, selectedIndex))
					}
					if (selectedIndex + 1 < items.size) {
						mediaController.addMediaItems(
							mediaController.mediaItemCount,
							items.subList(selectedIndex + 1, items.size),
						)
					}
					result.success(null)
					return@withController
				}
			}
			mediaController.setMediaItems(items, currentIndex, 0L)
			mediaController.prepare()
			mediaController.play()
			result.success(null)
		}
	}

	private fun stopPlayback(result: MethodChannel.Result) {
		val activeController = controller
		if (activeController == null) {
			result.success(null)
			return
		}
		activeController.stop()
		activeController.clearMediaItems()
		emitState(activeController, isStopped = true)
		releaseController()
		context.stopService(android.content.Intent(context, AudioPlaybackService::class.java))
		result.success(null)
	}

	private fun renameQueuedTrack(call: MethodCall, result: MethodChannel.Result) {
		val arguments = call.arguments as? Map<*, *>
		val path = arguments?.get("path") as? String
		val title = arguments?.get("title") as? String
		val folder = arguments?.get("folder") as? String
		if (path.isNullOrBlank() || title.isNullOrBlank() || folder.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "A renamed audio track is incomplete", null)
			return
		}
		withController(result) { mediaController ->
			val index = (0 until mediaController.mediaItemCount).firstOrNull {
				mediaController.getMediaItemAt(it).localConfiguration?.uri?.path == path
			}
			if (index != null) {
				val existing = mediaController.getMediaItemAt(index)
				val mode = existing.mediaMetadata.albumTitle?.toString() ?: "All in folder"
				val replacement = MediaItem.Builder()
					.setMediaId(existing.mediaId)
					.setUri(Uri.fromFile(File(path)))
					.setMediaMetadata(
						MediaMetadata.Builder()
							.setTitle(title)
							.setArtist("$folder · $mode")
							.setAlbumArtist(folder)
							.setAlbumTitle(mode)
							.build(),
					)
					.build()
				mediaController.replaceMediaItem(index, replacement)
			}
			result.success(null)
		}
	}

	private fun removeQueuedTrack(call: MethodCall, result: MethodChannel.Result) {
		val path = call.arguments as? String
		if (path.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "An audio track path is required", null)
			return
		}
		withController(result) { mediaController ->
			val index = (0 until mediaController.mediaItemCount).firstOrNull {
				mediaController.getMediaItemAt(it).localConfiguration?.uri?.path == path
			}
			if (index != null) {
				if (mediaController.mediaItemCount == 1) {
					mediaController.stop()
					mediaController.clearMediaItems()
					sendStoppedEvent()
					context.stopService(Intent(context, AudioPlaybackService::class.java))
				} else {
					mediaController.removeMediaItem(index)
				}
			}
			result.success(null)
		}
	}

	private fun sendStoppedEvent() {
		context.sendBroadcast(
			Intent(ACTION_STOPPED).setPackage(context.packageName),
		)
	}

	private fun withController(
		result: MethodChannel.Result,
		action: (MediaController) -> Unit,
	) {
		val activeController = controller
		if (activeController != null) {
			action(activeController)
			return
		}
		val future = controllerFuture ?: createController()
		future.addListener(
			{
				try {
					val connectedController = future.get()
					controller = connectedController
					action(connectedController)
				} catch (error: ExecutionException) {
					result.error(
						"AUDIO_SERVICE_UNAVAILABLE",
						error.cause?.message ?: error.message,
						null,
					)
				} catch (error: Exception) {
					result.error("AUDIO_SERVICE_UNAVAILABLE", error.message, null)
				}
			},
			mainExecutor,
		)
	}

	private fun createController(): ListenableFuture<MediaController> {
		val token = SessionToken(
			context,
			ComponentName(context, AudioPlaybackService::class.java),
		)
		return MediaController.Builder(context, token)
			.setListener(object : MediaController.Listener {})
			.buildAsync()
			.also { future ->
				controllerFuture = future
				future.addListener(
					{
						try {
							val connectedController = future.get()
							controller = connectedController
							connectedController.addListener(playerListener)
							emitState(connectedController)
						} catch (error: Exception) {
							eventSink?.error(
								"AUDIO_SERVICE_UNAVAILABLE",
								error.message,
								null,
							)
						}
					},
					mainExecutor,
				)
			}
	}

	private val playerListener = object : Player.Listener {
		override fun onIsPlayingChanged(isPlaying: Boolean) {
			controller?.let { emitState(it) }
		}

		override fun onPlaybackStateChanged(playbackState: Int) {
			controller?.let { emitState(it) }
		}

		override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
			lastError = null
			controller?.let { emitState(it) }
		}

		override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
			controller?.let { emitState(it) }
		}

		override fun onPositionDiscontinuity(
			oldPosition: Player.PositionInfo,
			newPosition: Player.PositionInfo,
			reason: Int,
		) {
			controller?.let { emitState(it) }
		}

		override fun onPlayerError(error: PlaybackException) {
			lastError = "Could not play the current audio file: " +
				(error.message ?: error.errorCodeName)
			controller?.let { emitState(it) }
		}
	}

	private fun emitState(
		mediaController: MediaController,
		isStopped: Boolean = false,
		notificationTapped: Boolean = false,
	) {
		eventSink?.success(playbackState(mediaController, isStopped, notificationTapped))
	}

	private fun playbackState(
		mediaController: MediaController,
		isStopped: Boolean = false,
		notificationTapped: Boolean = false,
	): Map<String, Any?> {
		val mediaItem = mediaController.currentMediaItem
		val uriPath = mediaItem?.localConfiguration?.uri?.path
		val duration = mediaController.duration
		return mapOf(
			"isPlaying" to mediaController.isPlaying,
			"isLoading" to mediaController.isLoading,
			"path" to uriPath,
			"title" to mediaItem?.mediaMetadata?.title?.toString(),
			"folder" to mediaItem?.mediaMetadata?.albumArtist?.toString(),
			"positionMilliseconds" to mediaController.currentPosition,
			"durationMilliseconds" to if (duration == C.TIME_UNSET) 0L else duration,
			"queueIndex" to mediaController.currentMediaItemIndex.coerceAtLeast(0),
			"queueLength" to mediaController.mediaItemCount,
			"mode" to if (mediaItem?.mediaMetadata?.albumTitle?.toString() == "This audio") {
				"singleTrack"
			} else {
				"folder"
			},
			"error" to lastError,
			"isStopped" to isStopped,
			"notificationTapped" to notificationTapped,
		)
	}

	private fun releaseController() {
		controller?.removeListener(playerListener)
		controllerFuture?.let { MediaController.releaseFuture(it) }
		controller = null
		controllerFuture = null
		lastError = null
	}

	companion object {
		private const val TAG = "AudioPlaybackChannel"
		const val EXTRA_OPEN_AUDIO_TAB = "open_audio_tab"
		const val ACTION_STOPPED = "com.example.modi_file_explorer2.AUDIO_STOPPED"
		private const val POSITION_UPDATE_INTERVAL_MS = 500L
		private const val PREVIOUS_RESTART_THRESHOLD_MS = 3000L
		private const val METHOD_CHANNEL = "modi_file_explorer2/audio_player"
		private const val EVENT_CHANNEL = "modi_file_explorer2/audio_player/events"
	}
}
