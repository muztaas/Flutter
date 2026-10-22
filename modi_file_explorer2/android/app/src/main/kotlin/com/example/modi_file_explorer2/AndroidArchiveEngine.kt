package com.example.modi_file_explorer2

import com.github.junrar.Archive as RarArchive
import com.github.junrar.rarfile.FileHeader
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.CompressionLevel
import net.lingala.zip4j.model.enums.CompressionMethod
import net.lingala.zip4j.model.enums.EncryptionMethod
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import org.apache.commons.compress.archivers.sevenz.SevenZMethod
import org.apache.commons.compress.archivers.sevenz.SevenZMethodConfiguration
import org.apache.commons.compress.archivers.sevenz.SevenZOutputFile
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorOutputStream
import org.apache.commons.compress.compressors.gzip.GzipParameters
import org.apache.commons.compress.compressors.xz.XZCompressorInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterOutputStream
import java.io.InputStream
import java.io.OutputStream
import org.tukaani.xz.LZMA2Options
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

internal class ArchiveEngineException(
	val code: String,
	message: String,
) : Exception(message)

internal class AndroidArchiveEngine {
	private enum class Format { ZIP, SEVEN_Z, TAR, TAR_GZ, TAR_BZ2, TAR_XZ, GZIP, BZIP2, XZ, RAR }

	private data class Entry(
		val path: String,
		val directory: Boolean,
		val size: Long,
		val modifiedMillis: Long,
		val encrypted: Boolean = false,
	)

	private data class CompressionEntry(
		val file: File,
		val path: String,
		val directory: Boolean,
		val size: Long,
	)

	fun listEntries(archive: File, password: String?): List<Map<String, Any?>> {
		requireArchive(archive)
		return try {
			entries(archive, password).map { entry ->
				mapOf(
					"path" to entry.path,
					"name" to entry.path.substringAfterLast('/'),
					"isDirectory" to entry.directory,
					"size" to entry.size,
					"modifiedMillis" to entry.modifiedMillis,
					"isEncrypted" to entry.encrypted,
				)
			}
		} catch (error: Throwable) {
			throw translate(error, password)
		}
	}

	fun extract(
		archive: File,
		destination: File,
		selectedEntries: Set<String>?,
		password: String?,
		conflictActions: Map<String, String>,
		cancelled: AtomicBoolean,
		progress: (Map<String, Any?>) -> Unit,
	): Map<String, Any?> {
		requireArchive(archive)
		if (!destination.exists() && !destination.mkdirs()) {
			throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "Could not create the destination folder")
		}
		if (!destination.isDirectory) {
			throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "The destination folder is unavailable")
		}
		val selected = selectedEntries?.map(::normalizeEntryPath)?.toSet()
		val allEntries = try {
			entries(archive, password)
		} catch (error: Throwable) {
			throw translate(error, password)
		}
		val applicable = allEntries.filter { entry ->
			selected == null || selected.any { chosen ->
				entry.path == chosen || entry.path.startsWith("$chosen/")
			}
		}
		val totalBytes = applicable.sumOf { it.size.coerceAtLeast(0) }
		var completedBytes = 0L
		var completed = 0
		var skipped = 0
		var failed = 0
		var cancelledOperation = false
		val messages = mutableListOf<String>()
		val conflictMap = conflictActions.mapKeys { normalizeEntryPath(it.key) }
		val renamedDirectories = mutableListOf<Pair<String, String>>()
		val skippedDirectories = mutableSetOf<String>()

		fun mappedPath(path: String): String {
			val mapping = renamedDirectories
				.filter { (source, _) -> path == source || path.startsWith("$source/") }
				.maxByOrNull { (source, _) -> source.length }
				?: return path
			return mapping.second + path.removePrefix(mapping.first)
		}

		fun report(current: String? = null) {
			progress(
				mapOf(
					"completedBytes" to completedBytes,
					"totalBytes" to totalBytes,
					"completedEntries" to completed,
					"totalEntries" to applicable.size,
					"currentEntry" to current,
				),
			)
		}

		fun writeEntry(entry: Entry, write: (OutputStream) -> Unit) {
			if (cancelled.get()) throw CancellationException()
			val originalPath = normalizeEntryPath(entry.path)
			if (skippedDirectories.any {
					originalPath == it || originalPath.startsWith("$it/")
				}
			) {
				skipped++
				messages += "Skipped item inside an existing folder: $originalPath"
				report(originalPath)
				return
			}
			val path = mappedPath(originalPath)
			if (entry.directory) {
				val directory = safeTarget(destination, path)
				if (directory == null) {
					skipped++
					messages += "Skipped unsafe archive path: $path"
				} else {
					val action = conflictMap[originalPath] ?: conflictMap["*"] ?: "skip"
					if (directory.exists()) {
						when (action) {
							"replace" -> {
								if (!directory.deleteRecursively() || !directory.mkdirs()) {
									failed++
									messages += "Could not replace folder: $path"
								} else {
									completed++
								}
							}
							"rename" -> {
								val renamed = uniqueTarget(directory)
								val parent = originalPath.substringBeforeLast('/', "")
								val renamedPath = if (parent.isEmpty()) {
									renamed.name
								} else {
									"$parent/${renamed.name}"
								}
								if (!renamed.mkdirs()) {
									failed++
									messages += "Could not create renamed folder: $renamedPath"
								} else {
									renamedDirectories += originalPath to renamedPath
									completed++
								}
							}
							else -> {
								skipped++
								skippedDirectories += originalPath
								messages += "Skipped existing folder: $originalPath"
							}
						}
					} else if (!directory.mkdirs()) {
						failed++
						messages += "Could not create folder: $path"
					} else {
						completed++
					}
				}
				report(path)
				return
			}
			val target = safeTarget(destination, path)
			if (target == null) {
				skipped++
				messages += "Skipped unsafe archive path: $path"
				report(path)
				return
			}
			target.parentFile?.let { parent ->
				if (!parent.exists() && !parent.mkdirs()) {
					failed++
					messages += "Could not create folder: ${parent.name}"
					report(path)
					return
				}
			}
			val action = conflictMap[originalPath] ?: conflictMap["*"] ?: "skip"
			val output = if (target.exists()) {
				when (action) {
					"replace" -> {
						if (!target.deleteRecursively()) {
							failed++
							messages += "Could not replace existing item: $path"
							report(path)
							return
						}
						target
					}
					"rename" -> uniqueTarget(target)
					else -> {
						skipped++
						messages += "Skipped existing item: $path"
						report(path)
						return
					}
				}
			} else {
				target
			}
			try {
				FileOutputStream(output).use { fileOutput ->
					val countingOutput = object : FilterOutputStream(BufferedOutputStream(fileOutput)) {
						override fun write(bytes: ByteArray, offset: Int, length: Int) {
							if (cancelled.get()) throw CancellationException()
							out.write(bytes, offset, length)
							completedBytes += length
							report(path)
						}
					}
					write(countingOutput)
					countingOutput.flush()
				}
				if (entry.modifiedMillis > 0) output.setLastModified(entry.modifiedMillis)
				completed++
			} catch (error: CancellationException) {
				output.delete()
				throw error
			} catch (error: Throwable) {
				output.delete()
				failed++
				messages += "Failed to extract ${entry.path}: ${error.message ?: "unknown error"}"
			}
			report(path)
		}

		try {
			when (formatOf(archive)) {
				Format.ZIP -> extractZip(archive, selected, password, ::writeEntry, cancelled)
				Format.SEVEN_Z -> extractSevenZ(archive, selected, password, ::writeEntry, cancelled)
				Format.RAR -> extractRar(archive, selected, password, ::writeEntry, cancelled)
				Format.TAR, Format.TAR_GZ, Format.TAR_BZ2, Format.TAR_XZ ->
					extractTar(archive, formatOf(archive), selected, ::writeEntry, cancelled)
				Format.GZIP, Format.BZIP2, Format.XZ ->
					extractSingleCompressed(archive, formatOf(archive), ::writeEntry, cancelled)
			}
		} catch (error: CancellationException) {
			cancelledOperation = true
			messages += "Operation cancelled"
		} catch (error: Throwable) {
			throw translate(error, password)
		}
		return mapOf(
			"completed" to completed,
			"skipped" to skipped,
			"failed" to failed,
			"cancelled" to cancelledOperation,
			"messages" to messages,
		)
	}

	fun estimateCreateBytes(
		archive: File,
		sources: List<File>,
		excludeOutputPath: Boolean,
	): Long =
		collectCompressionEntries(if (excludeOutputPath) archive else null, null, sources)
			.first.sumOf { it.size }

	fun create(
		archive: File,
		formatName: String,
		sources: List<File>,
		password: String?,
		compressionLevel: String,
		conflictAction: String,
		cancelled: AtomicBoolean,
		progress: (Map<String, Any?>) -> Unit,
	): Map<String, Any?> {
		if (sources.isEmpty()) {
			throw ArchiveEngineException("INVALID_ARGUMENT", "Select at least one file or folder")
		}
		val format = when (formatName.lowercase().removePrefix(".")) {
			"zip" -> Format.ZIP
			"7z" -> Format.SEVEN_Z
			"tar" -> Format.TAR
			"tar.gz" -> Format.TAR_GZ
			else -> throw ArchiveEngineException("UNSUPPORTED_FORMAT", "Choose ZIP, 7z, TAR, or TAR.GZ")
		}
		if (!password.isNullOrEmpty() && format != Format.ZIP) {
			throw ArchiveEngineException("UNSUPPORTED_ENCRYPTION", "Passwords are supported only for ZIP creation")
		}
		val parent = archive.absoluteFile.parentFile
			?: throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "The destination folder is unavailable")
		if (!parent.isDirectory) {
			throw ArchiveEngineException("DESTINATION_UNAVAILABLE", "The destination folder is unavailable")
		}
		if (archive.isDirectory && conflictAction != "rename") {
			throw ArchiveEngineException("OUTPUT_IS_DIRECTORY", "A folder already uses this archive name")
		}
		if (archive.exists() && conflictAction == "cancel") {
			throw ArchiveEngineException("OUTPUT_EXISTS", "An item with this archive name already exists")
		}
		if (conflictAction !in setOf("replace", "rename", "cancel")) {
			throw ArchiveEngineException("INVALID_ARGUMENT", "The archive conflict action is invalid")
		}
		var output = if (archive.exists() && conflictAction == "rename") uniqueTarget(archive) else archive
		if (output.exists() && conflictAction != "replace") {
			throw ArchiveEngineException("OUTPUT_EXISTS", "An item with this archive name already exists")
		}
		val temporary = File(parent, ".${archive.name}.${System.nanoTime()}.partial")
		var items = emptyList<CompressionEntry>()
		var totalBytes = 0L
		var completedBytes = 0L
		var completed = 0
		var skipped = 0

		fun report(current: String? = null) {
			progress(
				mapOf(
					"completedBytes" to completedBytes.coerceAtMost(totalBytes),
					"totalBytes" to totalBytes,
					"completedEntries" to completed,
					"totalEntries" to items.size,
					"currentEntry" to current,
				),
			)
		}

		fun copy(input: InputStream, target: OutputStream, name: String) {
			val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
			while (true) {
				if (cancelled.get()) throw CancellationException()
				val count = input.read(buffer)
				if (count < 0) break
				target.write(buffer, 0, count)
				completedBytes += count
				report(name)
			}
		}
		fun copySevenZ(input: InputStream, target: SevenZOutputFile, name: String) {
			val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
			while (true) {
				if (cancelled.get()) throw CancellationException()
				val count = input.read(buffer)
				if (count < 0) break
				target.write(buffer, 0, count)
				completedBytes += count
				report(name)
			}
		}

		fun onEntryComplete(item: CompressionEntry) {
			if (item.directory) completedBytes += item.size
			completed++
			report(item.path)
		}
		fun onZipProgress(name: String, fileBytes: Long, previousBytes: Long, percent: Int) {
			completedBytes = previousBytes + fileBytes * percent / 100
			report(name)
		}
		fun onZipSkip(name: String, previousBytes: Long) {
			completedBytes = previousBytes
			skipped++
			report(name)
		}

		try {
			val inventory = collectCompressionEntries(output, temporary, sources, cancelled)
			items = inventory.first
			skipped = inventory.second
			totalBytes = items.sumOf { it.size }
			if (items.isEmpty() && skipped == 0) {
				throw ArchiveEngineException(
					"EMPTY_INPUT",
					"The archive output cannot also be the only selected source file",
				)
			}
			when (format) {
				Format.ZIP -> createZip(
					temporary,
					items,
					password,
					compressionLevel,
					cancelled,
					::onEntryComplete,
					::onZipSkip,
					::onZipProgress,
				)
				Format.SEVEN_Z -> createSevenZ(
					temporary,
					items,
					compressionLevel,
					cancelled,
					::copySevenZ,
					::onEntryComplete,
					{ name ->
						skipped++
						report(name)
					},
				)
				Format.TAR, Format.TAR_GZ -> createTar(
					temporary,
					format,
					items,
					compressionLevel,
					cancelled,
					::copy,
					::onEntryComplete,
					{ name ->
						skipped++
						report(name)
					},
				)
				else -> throw ArchiveEngineException("UNSUPPORTED_FORMAT", "This archive format cannot be created")
			}
			if (cancelled.get()) throw CancellationException()
			if (output.exists() && conflictAction == "rename") output = uniqueTarget(output)
			output = commitArchive(temporary, output, conflictAction)
		} catch (error: CancellationException) {
			temporary.delete()
			return mapOf(
				"completed" to completed,
				"skipped" to skipped,
				"failed" to 0,
				"cancelled" to true,
				"messages" to listOf("Operation cancelled; the partial archive was removed"),
			)
		} catch (error: Throwable) {
			temporary.delete()
			throw translate(error, password)
		}
		return mapOf(
			"completed" to completed,
			"skipped" to skipped,
			"failed" to 0,
			"cancelled" to false,
			"messages" to emptyList<String>(),
			"outputPath" to output.absolutePath,
			"outputSize" to output.length(),
		)
	}

	private fun entries(archive: File, password: String?): List<Entry> =
		when (formatOf(archive)) {
			Format.ZIP -> ZipFile(archive, password?.toCharArray()).use { zip ->
				zip.fileHeaders.map { header ->
					Entry(
						header.fileName,
						header.isDirectory,
						header.uncompressedSize,
						header.lastModifiedTime,
						header.isEncrypted,
					)
				}
			}
			Format.SEVEN_Z -> SevenZFile.builder()
				.setFile(archive)
				.setPassword(password?.toCharArray())
				.get()
				.use { seven ->
					buildList {
						while (true) {
							val entry = seven.nextEntry ?: break
							add(
								Entry(
									entry.name,
									entry.isDirectory,
									entry.size,
									entry.lastModifiedDate?.time ?: 0L,
									false,
								),
							)
						}
					}
				}
			Format.RAR -> {
				// The UnRAR license permits extraction only; this engine never creates RAR files.
				RarArchive(archive, password).use { rar ->
					rar.fileHeaders.map { header ->
						Entry(
							rarName(header),
							header.isDirectory,
							header.fullUnpackSize,
							header.mTime?.time ?: 0L,
							header.isEncrypted,
						)
					}
				}
			}
			Format.TAR, Format.TAR_GZ, Format.TAR_BZ2, Format.TAR_XZ -> {
				val result = mutableListOf<Entry>()
				openTarInput(archive, formatOf(archive)).use { tar ->
					while (true) {
						val entry = tar.nextTarEntry ?: break
						result += Entry(entry.name, entry.isDirectory, entry.size, entry.lastModifiedDate.time)
					}
				}
				result
			}
			Format.GZIP, Format.BZIP2, Format.XZ -> {
				val name = compressedOutputName(archive.name)
				var size = 0L
				openSingleCompressedInput(archive, formatOf(archive)).use { input ->
					val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
					while (true) {
						val read = input.read(buffer)
						if (read < 0) break
						size += read
					}
				}
				listOf(Entry(name, false, size, archive.lastModified()))
			}
		}

	private fun extractZip(
		archive: File,
		selected: Set<String>?,
		password: String?,
		writeEntry: (Entry, (OutputStream) -> Unit) -> Unit,
		cancelled: AtomicBoolean,
	) {
		ZipFile(archive, password?.toCharArray()).use { zip ->
			for (header in zip.fileHeaders) {
				if (cancelled.get()) throw CancellationException()
				val name = normalizeEntryPath(header.fileName)
				if (!isSelected(name, selected)) continue
				val entry = Entry(name, header.isDirectory, header.uncompressedSize, header.lastModifiedTime, header.isEncrypted)
				if (entry.encrypted && password.isNullOrEmpty()) {
					throw ArchiveEngineException("PASSWORD_REQUIRED", "This ZIP archive requires a password")
				}
				writeEntry(entry) { output ->
					zip.getInputStream(header).use { input -> copy(input, output, cancelled) }
				}
			}
		}
	}

	private fun extractSevenZ(
		archive: File,
		selected: Set<String>?,
		password: String?,
		writeEntry: (Entry, (OutputStream) -> Unit) -> Unit,
		cancelled: AtomicBoolean,
	) {
		SevenZFile.builder()
			.setFile(archive)
			.setPassword(password?.toCharArray())
			.get()
			.use { seven ->
				while (true) {
					if (cancelled.get()) throw CancellationException()
					val header = seven.nextEntry ?: break
					val name = normalizeEntryPath(header.name)
					val entry = Entry(name, header.isDirectory, header.size, header.lastModifiedDate?.time ?: 0L)
					if (!isSelected(name, selected)) continue
					writeEntry(entry) { output ->
						val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
						while (true) {
							if (cancelled.get()) throw CancellationException()
							val read = seven.read(buffer, 0, buffer.size)
							if (read <= 0) break
							output.write(buffer, 0, read)
						}
					}
				}
			}
	}

	private fun extractRar(
		archive: File,
		selected: Set<String>?,
		password: String?,
		writeEntry: (Entry, (OutputStream) -> Unit) -> Unit,
		cancelled: AtomicBoolean,
	) {
		RarArchive(archive, password).use { rar ->
			for (header in rar.fileHeaders) {
				if (cancelled.get()) throw CancellationException()
				val name = normalizeEntryPath(rarName(header))
				if (!isSelected(name, selected)) continue
				val entry = Entry(name, header.isDirectory, header.fullUnpackSize, header.mTime?.time ?: 0L, header.isEncrypted)
				if (entry.encrypted && password.isNullOrEmpty()) {
					throw ArchiveEngineException("PASSWORD_REQUIRED", "This RAR archive requires a password")
				}
				writeEntry(entry) { output -> rar.extractFile(header, output) }
			}
		}
	}

	private fun extractTar(
		archive: File,
		format: Format,
		selected: Set<String>?,
		writeEntry: (Entry, (OutputStream) -> Unit) -> Unit,
		cancelled: AtomicBoolean,
	) {
		openTarInput(archive, format).use { tar ->
			while (true) {
				if (cancelled.get()) throw CancellationException()
				val header = tar.nextTarEntry ?: break
				val name = normalizeEntryPath(header.name)
				if (!isSelected(name, selected)) continue
				if (header.isSymbolicLink || header.isLink) {
					writeEntry(Entry(name, false, 0, header.lastModifiedDate.time)) {
						throw ArchiveEngineException("UNSUPPORTED_ENTRY", "Symbolic links are not extracted")
					}
					continue
				}
				val entry = Entry(name, header.isDirectory, header.size, header.lastModifiedDate.time)
				writeEntry(entry) { output -> copy(tar, output, cancelled) }
			}
		}
	}

	private fun extractSingleCompressed(
		archive: File,
		format: Format,
		writeEntry: (Entry, (OutputStream) -> Unit) -> Unit,
		cancelled: AtomicBoolean,
	) {
		val name = compressedOutputName(archive.name)
		writeEntry(Entry(name, false, 0, archive.lastModified())) { output ->
			openSingleCompressedInput(archive, format).use { input -> copy(input, output, cancelled) }
		}
	}

	private fun collectCompressionEntries(
		archive: File?,
		temporary: File?,
		sources: List<File>,
		cancelled: AtomicBoolean? = null,
	): Pair<List<CompressionEntry>, Int> {
		val excluded = (listOfNotNull(archive, temporary)).mapNotNull {
			try {
				it.canonicalPath
			} catch (_: Exception) {
				null
			}
		}.toSet()
		val entries = mutableListOf<CompressionEntry>()
		var skipped = 0

		fun visit(file: File, path: String) {
			if (cancelled?.get() == true) throw CancellationException()
			if (file.canonicalPath in excluded) return
			if (isSymbolicLink(file) || !file.exists() || !file.canRead()) {
				skipped++
				return
			}
			if (file.isDirectory) {
				entries += CompressionEntry(file, path, true, 0)
				val children = try {
					file.listFiles()
				} catch (_: SecurityException) {
					null
				}
				if (children == null) {
					skipped++
					return
				}
				for (child in children.sortedBy { it.name.lowercase() }) {
					try {
						visit(child, "$path/${child.name}")
					} catch (_: Exception) {
						if (cancelled?.get() == true) throw CancellationException()
						skipped++
					}
				}
			} else if (file.isFile) {
				try {
					FileInputStream(file).use { }
					entries += CompressionEntry(file, path, false, file.length())
				} catch (_: Exception) {
					skipped++
				}
			} else {
				skipped++
			}
		}

		for (source in sources) {
			if (cancelled?.get() == true) throw CancellationException()
			try {
				visit(source, source.name)
			} catch (_: Exception) {
				if (cancelled?.get() == true) throw CancellationException()
				skipped++
			}
		}
		return entries to skipped
	}

	private fun isSymbolicLink(file: File): Boolean {
		val parent = file.absoluteFile.parentFile ?: return false
		return file.canonicalFile.path != File(parent.canonicalFile, file.name).absolutePath
	}

	private fun createZip(
		archive: File,
		items: List<CompressionEntry>,
		password: String?,
		compressionLevel: String,
		cancelled: AtomicBoolean,
		complete: (CompressionEntry) -> Unit,
		skip: (String, Long) -> Unit,
		progressFile: (String, Long, Long, Int) -> Unit,
	) {
		val zip = ZipFile(archive, password?.toCharArray()).apply {
			isRunInThread = true
		}
		zip.use {
			var successfulBytes = 0L

			fun awaitTask(item: CompressionEntry, byteOffset: Long) {
				val monitor = zip.progressMonitor
				while (monitor.state == net.lingala.zip4j.progress.ProgressMonitor.State.BUSY ||
					monitor.result == net.lingala.zip4j.progress.ProgressMonitor.Result.WORK_IN_PROGRESS
				) {
					if (cancelled.get()) monitor.isCancelAllTasks = true
					progressFile(item.path, item.size, byteOffset, monitor.percentDone.coerceIn(0, 100))
					Thread.sleep(50)
				}
				if (cancelled.get() ||
					monitor.result == net.lingala.zip4j.progress.ProgressMonitor.Result.CANCELLED
				) {
					throw CancellationException()
				}
				if (monitor.result == net.lingala.zip4j.progress.ProgressMonitor.Result.ERROR) {
					throw monitor.exception ?: java.io.IOException("Could not add ${item.path}")
				}
			}

			for (item in items) {
				if (cancelled.get()) throw CancellationException()
				val parameters = ZipParameters().apply {
					fileNameInZip = if (item.directory) "${item.path}/" else item.path
					compressionMethod = if (item.directory) CompressionMethod.STORE else CompressionMethod.DEFLATE
					this.compressionLevel = when (compressionLevel.lowercase()) {
						"fast" -> CompressionLevel.FAST
						"maximum" -> CompressionLevel.MAXIMUM
						else -> CompressionLevel.NORMAL
					}
					if (item.directory) {
						entrySize = 0
						entryCRC = 0
					}
					if (!password.isNullOrEmpty()) {
						isEncryptFiles = true
						encryptionMethod = EncryptionMethod.AES
						aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
					}
				}
				if (item.directory) {
					zip.addStream(ByteArrayInputStream(ByteArray(0)), parameters)
					awaitTask(item, successfulBytes)
					complete(item)
					continue
				}
				try {
					zip.addFile(item.file, parameters)
					awaitTask(item, successfulBytes)
					complete(item)
					successfulBytes += item.size
				} catch (error: CancellationException) {
					throw error
				} catch (error: Exception) {
					if (!item.file.exists() || !item.file.canRead()) {
						skip(item.path, successfulBytes)
					} else {
						throw error
					}
				}
			}
		}
	}

	private fun createSevenZ(
		archive: File,
		items: List<CompressionEntry>,
		compressionLevel: String,
		cancelled: AtomicBoolean,
		copy: (InputStream, SevenZOutputFile, String) -> Unit,
		complete: (CompressionEntry) -> Unit,
		skip: (String) -> Unit,
	) {
		val preset = when (compressionLevel.lowercase()) {
			"fast" -> 1
			"maximum" -> 7
			else -> 5
		}
		SevenZOutputFile(archive).use { output ->
			output.setContentMethods(
				listOf(SevenZMethodConfiguration(SevenZMethod.LZMA2, LZMA2Options(preset))),
			)
			for (item in items) {
				if (cancelled.get()) throw CancellationException()
				val input = if (item.directory) {
					null
				} else {
					try {
						BufferedInputStream(FileInputStream(item.file))
					} catch (_: Exception) {
						skip(item.path)
						continue
					}
				}
				val entry = output.createArchiveEntry(item.file, item.path)
				try {
					output.putArchiveEntry(entry)
					if (input != null) input.use { copy(it, output, item.path) }
					output.closeArchiveEntry()
				} finally {
					input?.close()
				}
				complete(item)
			}
			output.finish()
		}
	}

	private fun createTar(
		archive: File,
		format: Format,
		items: List<CompressionEntry>,
		compressionLevel: String,
		cancelled: AtomicBoolean,
		copy: (InputStream, OutputStream, String) -> Unit,
		complete: (CompressionEntry) -> Unit,
		skip: (String) -> Unit,
	) {
		val raw = FileOutputStream(archive)
		val compressed: OutputStream = if (format == Format.TAR_GZ) {
			val parameters = GzipParameters().apply {
				this.compressionLevel = when (compressionLevel.lowercase()) {
					"fast" -> 1
					"maximum" -> 9
					else -> 6
				}
			}
			GzipCompressorOutputStream(raw, parameters)
		} else {
			raw
		}
		TarArchiveOutputStream(BufferedOutputStream(compressed)).use { tar ->
			tar.setLongFileMode(TarArchiveOutputStream.LONGFILE_POSIX)
			for (item in items) {
				if (cancelled.get()) throw CancellationException()
				val input = if (item.directory) {
					null
				} else {
					try {
						BufferedInputStream(FileInputStream(item.file))
					} catch (_: Exception) {
						skip(item.path)
						continue
					}
				}
				try {
					tar.putArchiveEntry(TarArchiveEntry(item.file, item.path))
					if (input != null) input.use { copy(it, tar, item.path) }
					tar.closeArchiveEntry()
				} finally {
					input?.close()
				}
				complete(item)
			}
			tar.finish()
		}
	}

	private fun commitArchive(temporary: File, target: File, conflictAction: String): File {
		if (target.exists() && conflictAction == "rename") {
			val renamed = uniqueTarget(target)
			if (!temporary.renameTo(renamed)) {
				throw ArchiveEngineException("WRITE_FAILED", "Could not finish the archive")
			}
			return renamed
		}
		if (target.exists() && conflictAction != "replace") {
			throw ArchiveEngineException("OUTPUT_EXISTS", "An item with this archive name already exists")
		}
		if (!target.exists()) {
			if (!temporary.renameTo(target)) {
				throw ArchiveEngineException("WRITE_FAILED", "Could not finish the archive")
			}
			return target
		}
		val backup = File(target.parentFile, ".${target.name}.${System.nanoTime()}.backup")
		if (!target.renameTo(backup)) {
			throw ArchiveEngineException("WRITE_FAILED", "Could not replace the existing archive")
		}
		if (!temporary.renameTo(target)) {
			backup.renameTo(target)
			throw ArchiveEngineException("WRITE_FAILED", "Could not finish the replacement archive")
		}
		backup.delete()
		return target
	}

	private fun openTarInput(archive: File, format: Format): TarArchiveInputStream {
		val fileInput = BufferedInputStream(FileInputStream(archive))
		val decoded: InputStream = when (format) {
			Format.TAR_GZ -> GzipCompressorInputStream(fileInput)
			Format.TAR_BZ2 -> BZip2CompressorInputStream(fileInput)
			Format.TAR_XZ -> XZCompressorInputStream(fileInput)
			else -> fileInput
		}
		return TarArchiveInputStream(decoded)
	}

	private fun openSingleCompressedInput(archive: File, format: Format): InputStream {
		val fileInput = BufferedInputStream(FileInputStream(archive))
		return when (format) {
			Format.GZIP -> GzipCompressorInputStream(fileInput)
			Format.BZIP2 -> BZip2CompressorInputStream(fileInput)
			Format.XZ -> XZCompressorInputStream(fileInput)
			else -> fileInput
		}
	}

	private fun safeTarget(destination: File, entryPath: String): File? {
		val normalized = normalizeEntryPath(entryPath)
		if (normalized.isEmpty() ||
			normalized.startsWith("/") ||
			normalized.split('/').any { it == ".." || it == "." } ||
			Regex("^[A-Za-z]:").containsMatchIn(normalized)
		) return null
		val root = destination.canonicalFile
		val target = File(root, normalized.replace('/', File.separatorChar)).canonicalFile
		return target.takeIf { it.path.startsWith(root.path + File.separator) }
	}

	private fun uniqueTarget(target: File): File {
		val extension = target.extension
		val stem = if (extension.isEmpty()) target.name else target.name.removeSuffix(".$extension")
		for (index in 1..Int.MAX_VALUE) {
			val candidate = File(target.parentFile, if (extension.isEmpty()) "$stem ($index)" else "$stem ($index).$extension")
			if (!candidate.exists()) return candidate
		}
		throw ArchiveEngineException("NAME_CONFLICT", "Could not create a unique destination name")
	}

	private fun normalizeEntryPath(path: String): String =
		path.replace('\\', '/').trimEnd('/')

	private fun isSelected(path: String, selected: Set<String>?): Boolean =
		selected == null || selected.any { path == it || path.startsWith("$it/") }

	private fun compressedOutputName(name: String): String = when {
		name.endsWith(".tar.gz", true) -> name.dropLast(7)
		name.endsWith(".tgz", true) -> name.dropLast(4) + ".tar"
		name.endsWith(".gz", true) || name.endsWith(".bz2", true) || name.endsWith(".xz", true) ->
			name.substringBeforeLast('.')
		else -> name
	}

	private fun formatOf(archive: File): Format = formatOfName(archive.name)

	private fun formatOfName(name: String): Format {
		val lower = name.lowercase()
		return when {
			lower.endsWith(".tar.gz") || lower.endsWith(".tgz") -> Format.TAR_GZ
			lower.endsWith(".tar.bz2") || lower.endsWith(".tbz2") || lower.endsWith(".tbz") -> Format.TAR_BZ2
			lower.endsWith(".tar.xz") || lower.endsWith(".txz") -> Format.TAR_XZ
			lower.endsWith(".zip") -> Format.ZIP
			lower.endsWith(".7z") -> Format.SEVEN_Z
			lower.endsWith(".tar") -> Format.TAR
			lower.endsWith(".gz") -> Format.GZIP
			lower.endsWith(".bz2") -> Format.BZIP2
			lower.endsWith(".xz") -> Format.XZ
			lower.endsWith(".rar") -> Format.RAR
			else -> throw ArchiveEngineException("UNSUPPORTED_FORMAT", "This archive format is not supported")
		}
	}

	private fun requireArchive(archive: File) {
		if (!archive.isFile) {
			throw ArchiveEngineException("ARCHIVE_UNAVAILABLE", "The selected archive is unavailable")
		}
		formatOf(archive)
	}

	private fun translate(error: Throwable, password: String?): ArchiveEngineException {
		if (error is ArchiveEngineException) return error
		val chain = generateSequence(error) { it.cause }
			.joinToString(" ") { "${it.javaClass.simpleName} ${it.message.orEmpty()}" }
			.lowercase()
		return when {
			"passwordrequiredexception" in chain || "password is required" in chain ->
				ArchiveEngineException("PASSWORD_REQUIRED", "This archive requires a password")
			"wrongpassword" in chain || "wrong password" in chain ||
				("password" in chain && !password.isNullOrEmpty()) ->
				ArchiveEngineException("WRONG_PASSWORD", "The archive password is incorrect")
			"unsupported" in chain && "encrypt" in chain ->
				ArchiveEngineException("UNSUPPORTED_ENCRYPTION", "This archive uses an unsupported encryption method")
			else -> ArchiveEngineException("ARCHIVE_OPERATION_FAILED", error.message ?: "Could not process the archive")
		}
	}

	private fun copy(input: InputStream, output: OutputStream, cancelled: AtomicBoolean) {
		val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
		while (true) {
			if (cancelled.get()) throw CancellationException()
			val read = input.read(buffer)
			if (read < 0) break
			output.write(buffer, 0, read)
		}
	}

	private fun rarName(header: FileHeader): String =
		header.fileName

}
