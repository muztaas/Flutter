package com.example.modi_file_explorer2

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class ArchivePlatformChannel(
	private val context: Context,
	messenger: BinaryMessenger,
) {
	private val methods = MethodChannel(messenger, "modi_file_explorer2/archive")
	private val events = EventChannel(messenger, "modi_file_explorer2/archive/events")
	private val engine = AndroidArchiveEngine()
	private val executor = Executors.newFixedThreadPool(2)
	private val mainHandler = Handler(Looper.getMainLooper())
	private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
	@Volatile private var eventSink: EventChannel.EventSink? = null

	init {
		events.setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
				eventSink = sink
			}

			override fun onCancel(arguments: Any?) {
				eventSink = null
			}
		})
		methods.setMethodCallHandler(::handle)
	}

	private fun handle(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"cancel" -> {
				val operationId = call.argument<String>("operationId")
				if (operationId.isNullOrBlank()) {
					result.error("INVALID_ARGUMENT", "An operation identifier is required", null)
					return
				}
				cancellations[operationId]?.set(true)
				result.success(null)
			}
			"availableBytes" -> runWorker(result) {
				val path = call.argument<String>("path")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "A destination path is required")
				val requested = File(path)
				val directory = if (requested.isDirectory) requested else requested.parentFile
				if (directory == null) {
					throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "The destination folder is unavailable")
				}
				if (!directory.isDirectory) {
					throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "The destination folder is unavailable")
				}
				StatFs(directory.absolutePath).availableBytes
			}
			"pathExists" -> runWorker(result) {
				val path = call.argument<String>("path")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "A path is required")
				File(path).exists()
			}
			"pathIsDirectory" -> runWorker(result) {
				val path = call.argument<String>("path")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "A path is required")
				File(path).isDirectory
			}
			"estimateCreateBytes" -> runWorker(result) {
				val archivePath = call.argument<String>("archivePath")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "An archive path is required")
				val sources = call.argument<List<String>>("sourcePaths")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "Source files are required")
				engine.estimateCreateBytes(
					File(archivePath),
					sources.map(::File),
					call.argument<Boolean>("excludeOutputPath") ?: true,
				)
			}
			"listEntries" -> runWorker(result) {
				val path = call.argument<String>("archivePath")
					?: throw ArchiveEngineException("INVALID_ARGUMENT", "An archive path is required")
				engine.listEntries(File(path), call.argument<String>("password"))
			}
			"extract", "create" -> {
				val operationId = call.argument<String>("operationId")
				if (operationId.isNullOrBlank()) {
					result.error("INVALID_ARGUMENT", "An operation identifier is required", null)
					return
				}
				val cancellation = AtomicBoolean(false)
				cancellations[operationId] = cancellation
				executor.execute {
					try {
						val progress: (Map<String, Any?>) -> Unit = { event ->
							mainHandler.post {
								eventSink?.success(mapOf("operationId" to operationId) + event)
							}
						}
						val answer = if (call.method == "extract") {
							val archivePath = call.argument<String>("archivePath")
								?: throw ArchiveEngineException("INVALID_ARGUMENT", "An archive path is required")
							val destinationPath = call.argument<String>("destinationPath")
								?: throw ArchiveEngineException("INVALID_ARGUMENT", "A destination folder is required")
							val selected = call.argument<List<String>>("selectedEntries")
							val conflicts = call.argument<Map<String, String>>("conflictActions") ?: emptyMap()
							engine.extract(
								File(archivePath),
								File(destinationPath),
								selected?.toSet(),
								call.argument<String>("password"),
								conflicts,
								cancellation,
								progress,
							)
						} else {
							val archivePath = call.argument<String>("archivePath")
								?: throw ArchiveEngineException("INVALID_ARGUMENT", "An archive path is required")
							val format = call.argument<String>("format")
								?: throw ArchiveEngineException("INVALID_ARGUMENT", "An archive format is required")
							val sources = call.argument<List<String>>("sourcePaths")
								?: throw ArchiveEngineException("INVALID_ARGUMENT", "Source files are required")
							engine.create(
								File(archivePath),
								format,
								sources.map(::File),
								call.argument<String>("password"),
								call.argument<String>("compressionLevel") ?: "normal",
								call.argument<String>("conflictAction") ?: "cancel",
								cancellation,
								progress,
							)
						}
						mainHandler.post { result.success(answer) }
					} catch (error: Throwable) {
						val archiveError = error as? ArchiveEngineException
						mainHandler.post {
							result.error(
								archiveError?.code ?: "ARCHIVE_OPERATION_FAILED",
								archiveError?.message ?: error.message ?: "Archive operation failed",
								null,
							)
						}
					} finally {
						cancellations.remove(operationId)
					}
				}
			}
			else -> result.notImplemented()
		}
	}

	private fun <T> runWorker(result: MethodChannel.Result, block: () -> T) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (error: Throwable) {
				val archiveError = error as? ArchiveEngineException
				mainHandler.post {
					result.error(
						archiveError?.code ?: "ARCHIVE_OPERATION_FAILED",
						archiveError?.message ?: error.message ?: "Archive operation failed",
						null,
					)
				}
			}
		}
	}
}
