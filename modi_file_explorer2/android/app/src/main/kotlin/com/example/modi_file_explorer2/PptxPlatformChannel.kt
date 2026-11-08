package com.example.modi_file_explorer2

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipFile

private const val PPTX_MAX_FILE_BYTES = 1L shl 30
private const val PPTX_MAX_ENTRY_BYTES = 64L * 1024 * 1024
private const val PPTX_MAX_TOTAL_INFLATED_BYTES = 256L * 1024 * 1024
private const val PPTX_MAX_ARCHIVE_ENTRIES = 20_000
private const val PPTX_MAX_SLIDES = 1_000
private const val PPTX_MAX_ELEMENTS_PER_SLIDE = 5_000
private const val PPTX_MAX_IMAGES_PER_SLIDE = 12
private const val PPTX_MAX_TABLE_ROWS = 100
private const val PPTX_MAX_TABLE_COLUMNS = 20
private const val PPTX_MAX_IMAGE_BYTES = 4L * 1024 * 1024
private const val PPTX_MAX_TEXT_CHARACTERS = 32 * 1024 * 1024
private const val PPTX_MAX_TEXT_PER_RUN = 65_536

private class PptxReaderException(val code: String, message: String) : Exception(message)

internal class PptxPlatformChannel(messenger: BinaryMessenger) {
	private val methods = MethodChannel(messenger, "modi_file_explorer2/pptx")
	private val executor = Executors.newSingleThreadExecutor()
	private val mainHandler = Handler(Looper.getMainLooper())
	private val presentations = ConcurrentHashMap<String, PptxPresentation>()

	init {
		methods.setMethodCallHandler(::handle)
	}

	private fun handle(call: MethodCall, result: MethodChannel.Result) {
		val arguments = call.arguments as? Map<*, *>
		when (call.method) {
			"openPresentation" -> {
				val path = arguments?.get("path") as? String
				if (path.isNullOrBlank()) {
					result.error("INVALID_ARGUMENT", "A PPTX file path is required", null)
					return
				}
				runWorker(result) {
					val presentation = PptxPresentation.open(File(path))
					presentations[presentation.id] = presentation
					presentation.metadata()
				}
			}
			"readSlide" -> runPresentationMethod(arguments, result) { presentation ->
				val index = (arguments?.get("index") as? Number)?.toInt()
					?: throw PptxReaderException("INVALID_ARGUMENT", "A slide index is required")
				presentation.readSlide(index)
			}
			"readImage" -> runPresentationMethod(arguments, result) { presentation ->
				val path = arguments?.get("path") as? String
					?: throw PptxReaderException("INVALID_ARGUMENT", "An image path is required")
				presentation.readImage(path)
			}
			"closePresentation" -> {
				val id = arguments?.get("id") as? String
				executor.execute {
					if (!id.isNullOrBlank()) presentations.remove(id)?.close()
					mainHandler.post { result.success(null) }
				}
			}
			else -> result.notImplemented()
		}
	}

	private fun runPresentationMethod(
		arguments: Map<*, *>?,
		result: MethodChannel.Result,
		block: (PptxPresentation) -> Any?,
	) {
		val id = arguments?.get("id") as? String
		if (id.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "A presentation identifier is required", null)
			return
		}
		runWorker(result) {
			val presentation = presentations[id]
				?: throw PptxReaderException("PRESENTATION_CLOSED", "The presentation is closed")
			block(presentation)
		}
	}

	private fun runWorker(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (error: Throwable) {
				val readerError = error as? PptxReaderException
				mainHandler.post {
					result.error(
						readerError?.code ?: "PPTX_READ_FAILED",
						readerError?.message ?: error.message ?: "Could not read the PPTX presentation",
						null,
					)
				}
			}
		}
	}
}

private data class PptxSlideRecord(val path: String, val relationshipId: String)

private data class PptxStyle(
	val bold: Boolean = false,
	val italic: Boolean = false,
	val underline: Boolean = false,
	val fontSize: Double? = null,
	val color: Int? = null,
) {
	fun channelValue(text: String): Map<String, Any?> = mapOf(
		"text" to text,
		"bold" to bold,
		"italic" to italic,
		"underline" to underline,
		"fontSize" to fontSize,
		"color" to color,
	)
}

private class PptxPresentation private constructor(
	private val archive: ZipFile,
	private val file: File,
	val id: String,
	val width: Double,
	val height: Double,
	private val slides: List<PptxSlideRecord>,
	initialInflatedBytes: Long,
	initialEntryBytes: Map<String, Long>,
) {
	private var inflatedBytes = initialInflatedBytes
	private var retainedCharacters = 0
	private var closed = false
	private val inflatedEntryBytes = initialEntryBytes.toMutableMap()
	private val slideCache = LinkedHashMap<Int, Map<String, Any?>>(4, 0.75f, true)
	private val slideCharacterCounts = mutableMapOf<Int, Int>()
	private var parsingSlideCharacters = 0
	private var parsingSlideTruncated = false

	fun metadata(): Map<String, Any?> = mapOf(
		"id" to id,
		"width" to width,
		"height" to height,
		"slideCount" to slides.size,
	)

	fun readSlide(index: Int): Map<String, Any?> {
		ensureOpen()
		if (index !in slides.indices) {
			throw PptxReaderException("INVALID_SLIDE", "The requested slide does not exist")
		}
		synchronized(slideCache) { slideCache[index]?.let { return it } }
		while (slideCache.size >= 3) {
			val oldest = slideCache.keys.firstOrNull() ?: break
			slideCache.remove(oldest)
			retainedCharacters -= slideCharacterCounts.remove(oldest) ?: 0
		}
		val slide = slides[index]
		val relationships = readRelationships(relationshipPath(slide.path))
		val layoutPath = relationships.values.firstOrNull { it.endsWith(".xml") &&
			relationshipTypeForTarget(relationshipPath(slide.path), it).endsWith("/slideLayout")
		}
		val layoutRelationships = layoutPath?.let { readRelationships(relationshipPath(it)) }.orEmpty()
		val masterPath = layoutRelationships.values.firstOrNull { it.endsWith(".xml") &&
			relationshipTypeForTarget(relationshipPath(layoutPath), it).endsWith("/slideMaster")
		}
		val inheritedBackground = layoutPath?.let(::readBackground)
			?: masterPath?.let(::readBackground)
		parsingSlideCharacters = 0
		val result = parseSlide(slide.path, index, relationships, inheritedBackground)
		retainedCharacters += parsingSlideCharacters
		synchronized(slideCache) {
			slideCache[index] = result
			slideCharacterCounts[index] = parsingSlideCharacters
		}
		return result
	}

	fun readImage(path: String): ByteArray {
		ensureOpen()
		if (!path.startsWith("ppt/media/") || path.contains("..")) {
			throw PptxReaderException("INVALID_IMAGE", "The embedded image path is invalid")
		}
		val entry = archive.getEntry(path)
			?: throw PptxReaderException("IMAGE_MISSING", "The embedded image is unavailable")
		if (entry.size > PPTX_MAX_IMAGE_BYTES) {
			throw PptxReaderException("IMAGE_TOO_LARGE", "Embedded images larger than 4 MiB are not supported")
		}
		val input = openEntry(path)
		return try {
			val output = ByteArrayOutputStream()
			val buffer = ByteArray(8 * 1024)
			while (true) {
				val count = input.read(buffer)
				if (count < 0) break
				if (output.size() + count > PPTX_MAX_IMAGE_BYTES) {
					throw PptxReaderException("IMAGE_TOO_LARGE", "Embedded images larger than 4 MiB are not supported")
				}
				output.write(buffer, 0, count)
			}
			output.toByteArray()
		} finally {
			input.close()
		}
	}

	private fun parseSlide(
		path: String,
		index: Int,
		relationships: Map<String, String>,
		inheritedBackground: Int?,
	): Map<String, Any?> {
		val input = openEntry(path)
		val parser = createParser(input)
		val elements = mutableListOf<Map<String, Any?>>()
		var background = inheritedBackground
		var imageCount = 0
		parsingSlideTruncated = false
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG) continue
				when (parser.name) {
					"bg" -> background = parseBackgroundElement(parser) ?: background
					"sp" -> elements.add(parseShape(parser))
					"cxnSp" -> elements.add(parseShape(parser))
					"pic" -> {
						val picture = parsePicture(parser, relationships)
						if (picture["imagePath"] != null) {
							imageCount++
							elements.add(
								if (imageCount <= PPTX_MAX_IMAGES_PER_SLIDE) picture
								else imageLimitPlaceholder(picture),
							)
						} else {
							elements.add(picture)
						}
					}
					"graphicFrame" -> elements.add(parseGraphicFrame(parser))
					"oleObj", "contentPart" -> {
						elements.add(placeholderElement())
						skipElement(parser)
					}
				}
				if (elements.size >= PPTX_MAX_ELEMENTS_PER_SLIDE) {
					throw PptxReaderException(
						"SLIDE_TOO_COMPLEX",
						"A slide exceeds the 5,000 element limit",
					)
				}
			}
		} finally {
			input.close()
		}
		if (parsingSlideTruncated && elements.size < PPTX_MAX_ELEMENTS_PER_SLIDE) {
			val paragraph = mapOf(
				"alignment" to "center",
				"runs" to listOf(PptxStyle(fontSize = 10.0, color = 0x666666)
					.channelValue("Some text omitted by the viewer's text limit")),
			)
			elements.add(
				element(
					"shape",
					(width * SLIDE_UNIT * 0.05).toLong(),
					(height * SLIDE_UNIT * 0.92).toLong(),
					(width * SLIDE_UNIT * 0.9).toLong(),
					(height * SLIDE_UNIT * 0.06).toLong(),
					paragraphs = listOf(paragraph),
				),
			)
		}
		return mapOf("index" to index, "backgroundColor" to background, "elements" to elements)
	}

	private fun parseShape(parser: XmlPullParser): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		var shape = "rect"
		var fill: Int? = null
		var line: Int? = null
		var lineWidth = 1.0
		var lineMode = false
		var unsupportedMediaLabel: String? = null
		var paragraphs = mutableListOf<Map<String, Any?>>()
		var paragraph: MutableMap<String, Any?>? = null
		var paragraphRuns: MutableList<Map<String, Any?>>? = null
		var paragraphDefaultStyle = PptxStyle()
		var runStyle = PptxStyle()
		var inRunProperties = false
		var runPropertiesTag: String? = null
		var bulletCounter = 0
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"off" -> {
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> {
						cx = parser.getAttributeValue(null, "cx")?.toLongOrNull() ?: cx
						cy = parser.getAttributeValue(null, "cy")?.toLongOrNull() ?: cy
					}
					"prstGeom" -> shape = normalizedShape(parser.getAttributeValue(null, "prst"))
					"ln" -> {
						lineMode = true
						lineWidth = (parser.getAttributeValue(null, "w")?.toDoubleOrNull()
							?.div(12_700.0) ?: 1.0).coerceIn(0.5, 24.0)
					}
					"p" -> {
						paragraph = mutableMapOf("alignment" to "left")
						paragraphRuns = mutableListOf()
						paragraphDefaultStyle = PptxStyle()
					}
					"r", "fld" -> runStyle = PptxStyle()
					"pPr" -> {
						paragraph?.set(
							"alignment",
							when (parser.getAttributeValue(null, "algn")) {
								"ctr" -> "center"
								"r" -> "right"
								"just" -> "justify"
								else -> "left"
							},
						)
					}
					"buChar" -> paragraph?.set("bullet", parser.getAttributeValue(null, "char") ?: "•")
					"buAutoNum" -> {
						bulletCounter++
						paragraph?.set("bullet", "$bulletCounter.")
					}
					"rPr", "defRPr" -> {
						inRunProperties = true
						runPropertiesTag = parser.name
						runStyle = styleFromAttributes(
							parser,
							if (parser.name == "rPr") paragraphDefaultStyle else runStyle,
						)
						if (parser.name == "defRPr") paragraphDefaultStyle = runStyle
					}
					"srgbClr", "schemeClr" -> {
						val color = parseColor(parser.getAttributeValue(null, "val"))
						if (inRunProperties) {
							runStyle = runStyle.copy(color = color)
							if (runPropertiesTag == "defRPr") {
								paragraphDefaultStyle = paragraphDefaultStyle.copy(color = color)
							}
						}
						else if (lineMode) line = color else fill = color
					}
					"noFill" -> if (!lineMode && !inRunProperties) fill = null
					"r", "fld" -> runStyle = paragraphDefaultStyle
					"t" -> {
						val text = readText(parser, "t")
						depth--
						val kept = retainText(text)
						val runs = paragraphRuns
						if (runs != null && kept.isNotEmpty()) runs.add(runStyle.channelValue(kept))
					}
					"br" -> paragraphRuns?.add(runStyle.channelValue("\n"))
					"videoFile", "media" -> unsupportedMediaLabel = "Video not shown"
					"audioFile", "audioCd" -> unsupportedMediaLabel = "Audio not shown"
					"oleObj", "object" -> unsupportedMediaLabel = "Embedded object not shown"
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				when (parser.name) {
					"p" -> {
						val current = paragraph
						val runs = paragraphRuns
						if (current != null && runs != null) {
							current["fontSize"] = paragraphDefaultStyle.fontSize
							current["color"] = paragraphDefaultStyle.color
							current["runs"] = runs
							paragraphs.add(current)
						}
						paragraph = null
						paragraphRuns = null
					}
					"rPr", "defRPr" -> {
						inRunProperties = false
						runPropertiesTag = null
					}
					"r", "fld" -> runStyle = PptxStyle()
					"ln" -> lineMode = false
				}
				depth--
			}
		}
		if (paragraph != null && paragraphRuns != null) {
			paragraph!!["runs"] = paragraphRuns!!
			paragraphs.add(paragraph!!)
		}
		if (unsupportedMediaLabel != null) {
			return positionedPlaceholder(x, y, cx, cy, unsupportedMediaLabel!!)
		}
		return element("shape", x, y, cx, cy, shape, fill, line, lineWidth, paragraphs)
	}

	private fun parsePicture(
		parser: XmlPullParser,
		relationships: Map<String, String>,
	): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		var relationId: String? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"off" -> {
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> {
						cx = parser.getAttributeValue(null, "cx")?.toLongOrNull() ?: cx
						cy = parser.getAttributeValue(null, "cy")?.toLongOrNull() ?: cy
					}
					"blip" -> relationId = parser.getAttributeValue(REL_NS, "embed")
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		val target = relationId?.let(relationships::get)
			?: return placeholderElement()
		return element("image", x, y, cx, cy, imagePath = target)
	}

	private fun parseGraphicFrame(parser: XmlPullParser): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		val rows = mutableListOf<List<String>>()
		var row: MutableList<String>? = null
		var cell: StringBuilder? = null
		var tableTruncated = false
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"off" -> {
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> {
						cx = parser.getAttributeValue(null, "cx")?.toLongOrNull() ?: cx
						cy = parser.getAttributeValue(null, "cy")?.toLongOrNull() ?: cy
					}
					"tr" -> {
						if (rows.size < PPTX_MAX_TABLE_ROWS) row = mutableListOf()
						else {
							row = null
							tableTruncated = true
						}
					}
					"tc" -> cell = StringBuilder()
					"t" -> {
						val text = readText(parser, "t")
						depth--
						cell?.let {
							if (row != null) {
								val kept = retainText(text)
								if (it.length < PPTX_MAX_TEXT_PER_RUN) {
									it.append(kept.take(PPTX_MAX_TEXT_PER_RUN - it.length))
								} else {
									tableTruncated = true
								}
								if (kept.length < text.length) tableTruncated = true
							} else {
								tableTruncated = true
							}
						}
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				when (parser.name) {
					"tc" -> {
						val currentRow = row
						if (currentRow != null) {
							if (currentRow.size < PPTX_MAX_TABLE_COLUMNS) {
								currentRow.add(cell?.toString().orEmpty())
							} else {
								tableTruncated = true
							}
						}
						cell = null
					}
					"tr" -> row?.let { rows.add(it) }
				}
				depth--
			}
		}
		if (rows.isEmpty()) return placeholderElement()
		val result = element("table", x, y, cx, cy).toMutableMap()
		result["tableRows"] = rows
		if (tableTruncated) {
			result["tableRows"] = if (rows.size < PPTX_MAX_TABLE_ROWS) {
				rows + listOf(listOf("Table truncated by viewer limit"))
			} else {
				rows.dropLast(1) + listOf(
					rows.last().dropLast(1) + "Table truncated by viewer limit",
				)
			}
		}
		return result
	}

	private fun element(
		type: String,
		x: Long,
		y: Long,
		cx: Long,
		cy: Long,
		shape: String = "rect",
		fill: Int? = null,
		line: Int? = null,
		lineWidth: Double = 1.0,
		paragraphs: List<Map<String, Any?>> = emptyList(),
		imagePath: String? = null,
		tableRows: List<List<String>> = emptyList(),
	): Map<String, Any?> = mapOf(
		"type" to type,
		"x" to (x.toDouble() / SLIDE_UNIT),
		"y" to (y.toDouble() / SLIDE_UNIT),
		"width" to (cx.toDouble() / SLIDE_UNIT),
		"height" to (cy.toDouble() / SLIDE_UNIT),
		"shape" to shape,
		"fillColor" to fill,
		"lineColor" to line,
		"lineWidth" to lineWidth,
		"paragraphs" to paragraphs,
		"tableRows" to tableRows,
		"imagePath" to imagePath,
	)

	private fun placeholderElement(label: String = "Object not shown"): Map<String, Any?> {
		return positionedPlaceholder(
			(width * SLIDE_UNIT * 0.1).toLong(),
			(height * SLIDE_UNIT * 0.45).toLong(),
			(width * SLIDE_UNIT * 0.8).toLong(),
			(height * SLIDE_UNIT * 0.1).toLong(),
			label,
		)
	}

	private fun positionedPlaceholder(
		x: Long,
		y: Long,
		cx: Long,
		cy: Long,
		label: String,
	): Map<String, Any?> {
		val runs = listOf(PptxStyle().channelValue(label))
		val paragraph = mapOf("alignment" to "center", "runs" to runs)
		return element(
			"shape",
			x,
			y,
			cx,
			cy,
			fill = 0xf0f0f0,
			line = 0x888888,
			paragraphs = listOf(paragraph),
		)
	}

	private fun imageLimitPlaceholder(picture: Map<String, Any?>): Map<String, Any?> {
		val paragraph = mapOf(
			"alignment" to "center",
			"runs" to listOf(PptxStyle(fontSize = 12.0, color = 0x555555)
				.channelValue("Additional image omitted")),
		)
		return picture.toMutableMap().apply {
			put("type", "shape")
			put("shape", "rect")
			put("fillColor", 0xf0f0f0)
			put("lineColor", 0x888888)
			put("paragraphs", listOf(paragraph))
			put("imagePath", null)
		}
	}

	private fun readBackground(path: String): Int? {
		if (archive.getEntry(path) == null) return null
		val input = openEntry(path)
		val parser = createParser(input)
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG && parser.name == "bg") {
					return parseBackgroundElement(parser)
				}
			}
		} finally {
			input.close()
		}
		return null
	}

	private fun parseBackgroundElement(parser: XmlPullParser): Int? {
		var depth = 1
		var color: Int? = null
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				if (parser.name == "srgbClr" || parser.name == "schemeClr") {
					color = parseColor(parser.getAttributeValue(null, "val")) ?: color
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		return color
	}

	private fun readRelationships(path: String): Map<String, String> {
		if (path.isBlank() || archive.getEntry(path) == null) return emptyMap()
		val input = openEntry(path)
		val parser = createParser(input)
		val result = mutableMapOf<String, String>()
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG || parser.name != "Relationship") continue
				if (parser.getAttributeValue(null, "TargetMode") == "External") continue
				val id = parser.getAttributeValue(null, "Id") ?: continue
				val target = parser.getAttributeValue(null, "Target") ?: continue
				result[id] = resolveTarget(path.substringBefore("/_rels/"), target)
			}
		} finally {
			input.close()
		}
		return result
	}

	private fun relationshipTypeForTarget(relationshipPath: String?, target: String): String {
		if (relationshipPath == null) return ""
		val input = if (archive.getEntry(relationshipPath) == null) return ""
		else openEntry(relationshipPath)
		val parser = createParser(input)
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG &&
					parser.name == "Relationship" &&
					parser.getAttributeValue(null, "Target")?.let {
						resolveTarget(relationshipPath.substringBefore("/_rels/"), it)
					} == target
				) return parser.getAttributeValue(null, "Type") ?: ""
			}
		} finally {
			input.close()
		}
		return ""
	}

	private fun relationshipPath(part: String?): String =
		if (part == null) "" else "${part.substringBeforeLast('/')}/_rels/${part.substringAfterLast('/')}.rels"

	private fun resolveTarget(ownerFolder: String, target: String): String {
		val combined = if (target.startsWith("/")) target.removePrefix("/")
		else "$ownerFolder/$target"
		val parts = mutableListOf<String>()
		for (part in combined.replace('\\', '/').split('/')) {
			when (part) {
				"", "." -> Unit
				".." -> if (parts.isNotEmpty()) parts.removeAt(parts.lastIndex)
				else -> parts.add(part)
			}
		}
		val resolved = parts.joinToString("/")
		if (!resolved.startsWith("ppt/")) {
			throw PptxReaderException("INVALID_DOCUMENT", "A presentation relationship is invalid")
		}
		return resolved
	}

	private fun openEntry(path: String): InputStream {
		val entry = archive.getEntry(path)
			?: throw PptxReaderException("INVALID_DOCUMENT", "Required presentation data is missing")
		if (entry.isDirectory || entry.size > PPTX_MAX_ENTRY_BYTES) {
			throw PptxReaderException("ENTRY_TOO_LARGE", "A presentation section exceeds the 64 MiB limit")
		}
		var entryBytes = 0L
		return object : FilterInputStream(archive.getInputStream(entry)) {
			override fun read(): Int {
				val value = super.read()
				if (value >= 0) record(1)
				return value
			}

			override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
				val count = super.read(buffer, offset, length)
				if (count > 0) record(count.toLong())
				return count
			}

			private fun record(count: Long) {
				entryBytes += count
				val previouslyCounted = inflatedEntryBytes[path] ?: 0L
				if (entryBytes > previouslyCounted) {
					val additional = entryBytes - previouslyCounted
					if (inflatedBytes + additional > PPTX_MAX_TOTAL_INFLATED_BYTES) {
						throw PptxReaderException(
							"PRESENTATION_TOO_LARGE",
							"Presentation data exceeds the 256 MiB decompressed limit",
						)
					}
					inflatedBytes += additional
					inflatedEntryBytes[path] = entryBytes
				}
				if (entryBytes > PPTX_MAX_ENTRY_BYTES ||
					(entry.size >= 0 && entryBytes > entry.size + 1_024)
				) {
					throw PptxReaderException("ENTRY_TOO_LARGE", "A presentation section exceeds the 64 MiB limit")
				}
			}
		}
	}

	private fun createParser(input: InputStream): XmlPullParser {
		val factory = XmlPullParserFactory.newInstance()
		factory.isNamespaceAware = true
		factory.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		return factory.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(input, null)
		}
	}

	private fun styleFromAttributes(parser: XmlPullParser, original: PptxStyle): PptxStyle {
		fun enabled(name: String, old: Boolean): Boolean {
			val value = parser.getAttributeValue(null, name) ?: return old
			return value != "0" && value != "false" && value != "none"
		}
		val size = parser.getAttributeValue(null, "sz")?.toDoubleOrNull()?.div(100.0)
			?.coerceIn(4.0, 120.0)
		return PptxStyle(
			bold = enabled("b", original.bold),
			italic = enabled("i", original.italic),
			underline = enabled("u", original.underline),
			fontSize = size ?: original.fontSize,
			color = original.color,
		)
	}

	private fun normalizedShape(value: String?): String = when (value) {
		"ellipse", "arc", "pie", "wedgeRoundRectCallout" -> "ellipse"
		"roundRect", "round1Rect", "round2SameRect", "round2DiagRect" -> "roundRect"
		"line", "lineInv" -> "line"
		else -> "rect"
	}

	private fun parseColor(value: String?): Int? {
		if (value == null) return null
		return value.toLongOrNull(16)?.takeIf { it <= 0xffffff }?.toInt()
			?: when (value.lowercase()) {
				"dk1", "tx1" -> 0x000000
				"lt1", "bg1" -> 0xffffff
				"dk2", "tx2" -> 0x44546a
				"lt2", "bg2" -> 0xe7e6e6
				"accent1" -> 0x4472c4
				"accent2" -> 0xed7d31
				"accent3" -> 0xa5a5a5
				"accent4" -> 0xffc000
				"accent5" -> 0x5b9bd5
				"accent6" -> 0x70ad47
				"ltblue" -> 0x9cc2e5
				"red" -> 0xff0000
				else -> null
			}
	}

	private fun readText(parser: XmlPullParser, tag: String): String {
		val text = StringBuilder()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.TEXT || parser.eventType == XmlPullParser.CDSECT) {
				text.append(parser.text)
			} else if (parser.eventType == XmlPullParser.END_TAG && parser.name == tag) {
				break
			}
		}
		return text.toString()
	}

	private fun retainText(text: String): String {
		val remaining =
			(PPTX_MAX_TEXT_CHARACTERS - retainedCharacters - parsingSlideCharacters)
				.coerceAtLeast(0)
		val count = minOf(text.length, PPTX_MAX_TEXT_PER_RUN, remaining)
		parsingSlideCharacters += count
		if (count < text.length) parsingSlideTruncated = true
		return text.take(count)
	}

	private fun skipElement(parser: XmlPullParser) {
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) depth++
			else if (parser.eventType == XmlPullParser.END_TAG) depth--
		}
	}

	private fun ensureOpen() {
		if (closed) throw PptxReaderException("PRESENTATION_CLOSED", "The presentation is closed")
		if (!file.isFile) throw PptxReaderException("FILE_NOT_FOUND", "The presentation file is unavailable")
	}

	fun close() {
		if (closed) return
		closed = true
		synchronized(slideCache) {
			slideCache.clear()
			slideCharacterCounts.clear()
		}
		archive.close()
	}

	companion object {
		private const val P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
		private const val REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
		private const val CONTENT_TYPE =
			"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
		private const val SLIDE_UNIT = 12_700.0

		fun open(file: File): PptxPresentation {
			if (!file.isFile || !file.canRead() || file.length() <= 0L) {
				throw PptxReaderException("FILE_UNAVAILABLE", "The PPTX file is unavailable")
			}
			if (file.length() > PPTX_MAX_FILE_BYTES) {
				throw PptxReaderException("FILE_TOO_LARGE", "PPTX files larger than 1 GiB are not supported")
			}
			val archive = try {
				ZipFile(file)
			} catch (_: Exception) {
				throw PptxReaderException("INVALID_PRESENTATION", "This is not a readable PPTX presentation")
			}
			try {
				var metadataInflatedBytes = 0L
				val metadataEntryBytes = mutableMapOf<String, Long>()
				fun openMetadataEntry(path: String): InputStream {
					val entry = archive.getEntry(path)
						?: throw PptxReaderException("INVALID_PRESENTATION", "Required presentation data is missing")
					if (entry.isDirectory || entry.size > PPTX_MAX_ENTRY_BYTES) {
						throw PptxReaderException("ENTRY_TOO_LARGE", "A presentation section exceeds the 64 MiB limit")
					}
					var entryBytes = 0L
					return object : FilterInputStream(archive.getInputStream(entry)) {
						override fun read(): Int {
							val value = super.read()
							if (value >= 0) record(1)
							return value
						}

						override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
							val count = super.read(buffer, offset, length)
							if (count > 0) record(count.toLong())
							return count
						}

						private fun record(count: Long) {
							entryBytes += count
							val counted = metadataEntryBytes[path] ?: 0L
							if (entryBytes > counted) {
								val additional = entryBytes - counted
								if (metadataInflatedBytes + additional > PPTX_MAX_TOTAL_INFLATED_BYTES) {
									throw PptxReaderException(
										"PRESENTATION_TOO_LARGE",
										"Presentation data exceeds the 256 MiB decompressed limit",
									)
								}
								metadataInflatedBytes += additional
								metadataEntryBytes[path] = entryBytes
							}
							if (entryBytes > PPTX_MAX_ENTRY_BYTES) {
								throw PptxReaderException(
									"ENTRY_TOO_LARGE",
									"A presentation section exceeds the 64 MiB limit",
								)
							}
						}
					}
				}
				if (archive.size() > PPTX_MAX_ARCHIVE_ENTRIES) {
					throw PptxReaderException("TOO_MANY_ENTRIES", "The presentation contains too many ZIP entries")
				}
				val contentInput = openMetadataEntry("[Content_Types].xml")
				val contentParser = createParser(contentInput)
				var valid = false
				try {
					while (contentParser.next() != XmlPullParser.END_DOCUMENT) {
						if (contentParser.eventType == XmlPullParser.START_TAG &&
							contentParser.name == "Override" &&
							contentParser.getAttributeValue(null, "PartName") == "/ppt/presentation.xml"
						) {
							valid = contentParser.getAttributeValue(null, "ContentType") == CONTENT_TYPE
							break
						}
					}
				} finally {
					contentInput.close()
				}
				if (!valid) {
					throw PptxReaderException(
						"UNSUPPORTED_PRESENTATION",
						"Only standard .pptx presentations are supported; macro-enabled files are not handled",
					)
				}
				val relationshipInput = openMetadataEntry("ppt/_rels/presentation.xml.rels")
				val relationshipParser = createParser(relationshipInput)
				val rootRelationships = mutableMapOf<String, String>()
				val rootTypes = mutableMapOf<String, String>()
				try {
					while (relationshipParser.next() != XmlPullParser.END_DOCUMENT) {
						if (relationshipParser.eventType != XmlPullParser.START_TAG ||
							relationshipParser.name != "Relationship"
						) continue
						if (relationshipParser.getAttributeValue(null, "TargetMode") == "External") continue
						val relationId = relationshipParser.getAttributeValue(null, "Id") ?: continue
						val target = relationshipParser.getAttributeValue(null, "Target") ?: continue
						rootRelationships[relationId] = resolveRootTarget(target)
						rootTypes[relationId] = relationshipParser.getAttributeValue(null, "Type") ?: ""
					}
				} finally {
					relationshipInput.close()
				}
				var width = 914_400.0 * 10
				var height = 914_400.0 * 5.625
				val records = mutableListOf<PptxSlideRecord>()
				val presentationInput = openMetadataEntry("ppt/presentation.xml")
				val presentationParser = createParser(presentationInput)
				try {
					while (presentationParser.next() != XmlPullParser.END_DOCUMENT) {
						if (presentationParser.eventType != XmlPullParser.START_TAG) continue
						when (presentationParser.name) {
							"sldSz" -> {
								width = presentationParser.getAttributeValue(null, "cx")?.toDoubleOrNull() ?: width
								height = presentationParser.getAttributeValue(null, "cy")?.toDoubleOrNull() ?: height
							}
							"sldId" -> {
								if (presentationParser.getAttributeValue(null, "show") in setOf("0", "false")) continue
								val relationId = presentationParser.getAttributeValue(REL_NS, "id") ?: continue
								if (rootTypes[relationId]?.endsWith("/slide") != true) continue
								val target = rootRelationships[relationId] ?: continue
								records.add(PptxSlideRecord(target, relationId))
								if (records.size > PPTX_MAX_SLIDES) {
									throw PptxReaderException("TOO_MANY_SLIDES", "Presentations are limited to 1,000 visible slides")
								}
							}
						}
					}
				} finally {
					presentationInput.close()
				}
				if (width <= 0 ||
					height <= 0 ||
					width > 20_000 * SLIDE_UNIT ||
					height > 20_000 * SLIDE_UNIT
				) {
					throw PptxReaderException("INVALID_PRESENTATION", "The slide dimensions are invalid")
				}
				if (records.isEmpty()) {
					throw PptxReaderException("NO_VISIBLE_SLIDES", "The presentation has no visible slides")
				}
				return PptxPresentation(
					archive,
					file,
					UUID.randomUUID().toString(),
					width / SLIDE_UNIT,
					height / SLIDE_UNIT,
					records,
					metadataInflatedBytes,
					metadataEntryBytes,
				)
			} catch (error: Throwable) {
				archive.close()
				throw error
			}
		}

		private fun resolveRootTarget(target: String): String {
			val normalizedTarget = target.replace('\\', '/')
			val combined = when {
				normalizedTarget.startsWith("/") -> normalizedTarget.removePrefix("/")
				normalizedTarget.startsWith("ppt/") -> normalizedTarget
				else -> "ppt/$normalizedTarget"
			}
			val path = mutableListOf<String>()
			for (part in combined.split('/')) {
				when (part) {
					"", "." -> Unit
					".." -> {
						if (path.isEmpty()) {
							throw PptxReaderException(
								"INVALID_PRESENTATION",
								"A presentation relationship is invalid",
							)
						}
						path.removeAt(path.lastIndex)
					}
					else -> path.add(part)
				}
			}
			val result = path.joinToString("/")
			if (!result.startsWith("ppt/") || result == "ppt/") {
				throw PptxReaderException("INVALID_PRESENTATION", "A presentation relationship is invalid")
			}
			return result
		}
	}
}

private const val SLIDE_UNIT = 12_700.0
private const val REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private fun createParser(input: InputStream): XmlPullParser {
	val factory = XmlPullParserFactory.newInstance()
	factory.isNamespaceAware = true
	factory.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
	return factory.newPullParser().apply {
		setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		setInput(input, null)
	}
}
