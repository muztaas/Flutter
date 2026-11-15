package com.example.modi_file_explorer2

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
private const val PPTX_MAX_IMAGES_PER_SLIDE = 24
private const val PPTX_MAX_CHARTS_PER_SLIDE = 16
private const val PPTX_MAX_TABLE_ROWS = 100
private const val PPTX_MAX_TABLE_COLUMNS = 20
private const val PPTX_MAX_CUSTOM_PATHS = 64
private const val PPTX_MAX_CUSTOM_COMMANDS_PER_PATH = 2_048
private const val PPTX_MAX_RENDERED_IMAGE_BYTES = 4L * 1024 * 1024
private const val PPTX_MAX_RENDERED_IMAGE_DIMENSION = 1_024
private const val PPTX_MAX_TEXT_CHARACTERS = 32 * 1024 * 1024
private const val PPTX_MAX_TEXT_PER_RUN = 65_536
private const val PPTX_MAX_FONT_ENTRY_BYTES = 2L * 1024 * 1024
private const val PPTX_MAX_FONT_DATA_BYTES = 1L * 1024 * 1024
private const val EOT_FLAG_COMPRESSED = 4L

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
			"readFont" -> runPresentationMethod(arguments, result) { presentation ->
				val family = arguments?.get("family") as? String
					?: throw PptxReaderException("INVALID_ARGUMENT", "A font family is required")
				presentation.readFont(family)
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

private data class PptxCoordinateTransform(
	val scaleX: Double = 1.0,
	val scaleY: Double = 1.0,
	val translateX: Double = 0.0,
	val translateY: Double = 0.0,
) {
	fun child(
		offsetX: Double,
		offsetY: Double,
		extentX: Double,
		extentY: Double,
		childOffsetX: Double,
		childOffsetY: Double,
		childExtentX: Double,
		childExtentY: Double,
	): PptxCoordinateTransform {
		val childScaleX = extentX / childExtentX.coerceAtLeast(1.0)
		val childScaleY = extentY / childExtentY.coerceAtLeast(1.0)
		return PptxCoordinateTransform(
			scaleX = scaleX * childScaleX,
			scaleY = scaleY * childScaleY,
			translateX = translateX + scaleX * (offsetX - childOffsetX * childScaleX),
			translateY = translateY + scaleY * (offsetY - childOffsetY * childScaleY),
		)
	}

	fun x(value: Long): Long = (translateX + value * scaleX).toLong()
	fun y(value: Long): Long = (translateY + value * scaleY).toLong()
	fun width(value: Long): Long = (value * scaleX).toLong()
	fun height(value: Long): Long = (value * scaleY).toLong()
}

private data class PptxStyle(
	val bold: Boolean = false,
	val italic: Boolean = false,
	val underline: Boolean = false,
	val strikethrough: Boolean = false,
	val fontSize: Double? = null,
	val color: Int? = null,
	val fontFamily: String? = null,
	val superscript: Boolean = false,
	val subscript: Boolean = false,
) {
	fun channelValue(text: String): Map<String, Any?> = mapOf(
		"text" to text,
		"bold" to bold,
		"italic" to italic,
		"underline" to underline,
		"strikethrough" to strikethrough,
		"fontSize" to fontSize,
		"color" to color,
		"fontFamily" to fontFamily,
		"superscript" to superscript,
		"subscript" to subscript,
	)
}

private data class PptxBackground(
	val color: Int? = null,
	val gradientColors: List<Int> = emptyList(),
	val gradientStops: List<Double> = emptyList(),
	val gradientAngle: Double = 0.0,
	val imagePath: String? = null,
)

private class PptxPresentation private constructor(
	private val archive: ZipFile,
	private val file: File,
	val id: String,
	val width: Double,
	val height: Double,
	private val slides: List<PptxSlideRecord>,
	private val embeddedFonts: Map<String, String>,
	private val ooxml: OoxmlPackage,
	private val theme: OoxmlTheme,
	initialInflatedBytes: Long,
	initialEntryBytes: Map<String, Long>,
) {
	private var inflatedBytes = initialInflatedBytes
	private var retainedCharacters = 0
	private var closed = false
	private val inflatedEntryBytes = initialEntryBytes.toMutableMap()
	private val slideCache = LinkedHashMap<Int, Map<String, Any?>>(4, 0.75f, true)
	private val slideCharacterCounts = mutableMapOf<Int, Int>()
	private val inheritedPartCache = LinkedHashMap<String, Map<String, Any?>>(8, 0.75f, true)
	private val notShown = OoxmlNotShownReport()
	private var activeTheme = theme
	private var parsingSlideCharacters = 0
	private var parsingSlideTruncated = false

	fun metadata(): Map<String, Any?> = mapOf(
		"id" to id,
		"width" to width,
		"height" to height,
		"slideCount" to slides.size,
		"embeddedFontFamilies" to embeddedFonts.keys.toList(),
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
		activeTheme = masterPath?.let(::themeForMaster) ?: theme
		parsingSlideCharacters = 0
		val masterRelationships = masterPath?.let { readRelationships(relationshipPath(it)) }.orEmpty()
		val masterParsed = masterPath?.let {
			parseInheritedPart(it, masterRelationships, null)
		}
		val masterBackground = (masterParsed?.get("background") as? PptxBackground)
			?: masterPath?.let(::readBackground)
		val layoutParsed = layoutPath?.let {
			parseInheritedPart(it, layoutRelationships, masterBackground)
		}
		val inheritedBackground =
			(layoutParsed?.get("background") as? PptxBackground) ?: masterBackground
		parsingSlideCharacters = 0
		val parsed = parseSlide(slide.path, index, relationships, inheritedBackground)
		val masterElements = (masterParsed?.get("elements") as? List<*>)
			.orEmpty().filterIsInstance<Map<String, Any?>>()
		val layoutElements = (layoutParsed?.get("elements") as? List<*>)
			.orEmpty().filterIsInstance<Map<String, Any?>>()
		val slideElements = (parsed["elements"] as? List<*>)
			.orEmpty().filterIsInstance<Map<String, Any?>>()
		val masterPlaceholders = masterElements
			.filter { it["placeholderType"] is String }
			.associateBy { placeholderKey(it) }
		val layoutPlaceholders = layoutElements
			.filter { it["placeholderType"] is String }
			.associateBy { placeholderKey(it) }
		val inheritedElements = (masterElements + layoutElements)
			.filter { it["placeholderType"] !is String }
		val resolvedSlideElements = slideElements.map { element ->
			if (element["placeholderType"] !is String) element
			else {
				val key = placeholderKey(element)
				mergePlaceholder(
					element,
					layoutPlaceholders[key],
					masterPlaceholders[key],
				)
			}
		}
		val showMasterShapes = parsed["showMasterShapes"] != false
		val result = parsed.toMutableMap().apply {
			put(
				"elements",
				(if (showMasterShapes) inheritedElements else layoutElements
					.filter { it["placeholderType"] !is String }) + resolvedSlideElements,
			)
			remove("background")
			remove("showMasterShapes")
		}
		retainedCharacters += parsingSlideCharacters
		synchronized(slideCache) {
			slideCache[index] = result
			slideCharacterCounts[index] = parsingSlideCharacters
		}
		return result
	}

	private fun parseInheritedPart(
		path: String,
		relationships: Map<String, String>,
		inheritedBackground: PptxBackground?,
	): Map<String, Any?> {
		val themeKey = activeTheme.colorMap.toSortedMap().entries.joinToString()
		val key = "$path:${themeKey.hashCode()}:${inheritedBackground.hashCode()}"
		inheritedPartCache[key]?.let { return it }
		val parsed = parseSlide(path, -1, relationships, inheritedBackground)
		val textSize = (parsed["elements"] as? List<*>)
			.orEmpty()
			.filterIsInstance<Map<String, Any?>>()
			.sumOf { element ->
				(element["paragraphs"] as? List<*>)
					.orEmpty()
					.filterIsInstance<Map<String, Any?>>()
					.sumOf { paragraph ->
						(paragraph["runs"] as? List<*>)
							.orEmpty()
							.filterIsInstance<Map<String, Any?>>()
							.sumOf { (it["text"] as? String)?.length ?: 0 }
					}
			}
		if (textSize <= 512 * 1024) {
			inheritedPartCache[key] = parsed
			while (inheritedPartCache.size > 4) {
				inheritedPartCache.remove(inheritedPartCache.keys.first())
			}
		}
		return parsed
	}

	private fun placeholderKey(element: Map<String, Any?>): String =
		"${element["placeholderType"]}:${element["placeholderIndex"] ?: 0}"

	private fun mergePlaceholder(
		slide: Map<String, Any?>,
		layout: Map<String, Any?>?,
		master: Map<String, Any?>?,
	): Map<String, Any?> {
		val result = slide.toMutableMap()
		if (slide["hasTransform"] != true) {
			val geometry = layout?.takeIf { it["hasTransform"] == true }
				?: master?.takeIf { it["hasTransform"] == true }
			if (geometry != null) {
				for (key in listOf(
					"x", "y", "width", "height", "rotationDegrees",
					"textVerticalAlignment", "textInsetLeft", "textInsetTop",
					"textInsetRight", "textInsetBottom",
				)) {
					result[key] = geometry[key]
				}
			}
		}
		for (key in listOf("fillColor", "lineColor", "lineWidth", "shape")) {
			if (result[key] == null) result[key] = layout?.get(key) ?: master?.get(key)
		}
		val templateParagraphs = (layout?.get("paragraphs") as? List<*>)
			?.filterIsInstance<Map<String, Any?>>().orEmpty().ifEmpty {
				(master?.get("paragraphs") as? List<*>)
					?.filterIsInstance<Map<String, Any?>>().orEmpty()
			}
		val slideParagraphs = (slide["paragraphs"] as? List<*>)
			?.filterIsInstance<Map<String, Any?>>().orEmpty()
		if (templateParagraphs.isNotEmpty() && slideParagraphs.isNotEmpty()) {
			result["paragraphs"] = slideParagraphs.mapIndexed { index, paragraph ->
				val template = templateParagraphs.getOrNull(index)
					?: templateParagraphs.last()
				val merged = template.toMutableMap().apply { putAll(paragraph) }
				val templateRuns = (template["runs"] as? List<*>)
					?.filterIsInstance<Map<String, Any?>>().orEmpty()
				val runs = (paragraph["runs"] as? List<*>)
					?.filterIsInstance<Map<String, Any?>>().orEmpty()
				merged["runs"] = runs.mapIndexed { runIndex, run ->
					val inheritedRun = templateRuns.getOrNull(runIndex)
						?: templateRuns.firstOrNull()
					if (inheritedRun == null) run else inheritedRun.toMutableMap().apply {
						putAll(run)
						for (styleKey in listOf("fontSize", "color", "fontFamily")) {
							if (run[styleKey] == null) put(styleKey, inheritedRun[styleKey])
						}
						for (styleKey in listOf(
							"bold", "italic", "underline", "strikethrough",
							"superscript", "subscript",
						)) {
							if (run[styleKey] != true && inheritedRun[styleKey] == true) {
								put(styleKey, true)
							}
						}
					}
				}
				merged
			}
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
		if (entry.size > PPTX_MAX_ENTRY_BYTES) {
			throw PptxReaderException("IMAGE_TOO_LARGE", "An embedded image exceeds the 64 MiB limit")
		}
		val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
		openEntry(path).use { BitmapFactory.decodeStream(it, null, bounds) }
		if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
			throw PptxReaderException("UNSUPPORTED_IMAGE", "This embedded image format is not supported")
		}
		var sampleSize = 1
		val largestDimension = maxOf(bounds.outWidth, bounds.outHeight)
		while (largestDimension / sampleSize > PPTX_MAX_RENDERED_IMAGE_DIMENSION) {
			sampleSize *= 2
		}
		while (true) {
			val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
			val bitmap = openEntry(path).use { BitmapFactory.decodeStream(it, null, options) }
				?: throw PptxReaderException("INVALID_IMAGE", "The embedded image could not be decoded")
			try {
				val output = ByteArrayOutputStream()
				if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
					throw PptxReaderException("INVALID_IMAGE", "The embedded image could not be rendered")
				}
				if (output.size().toLong() <= PPTX_MAX_RENDERED_IMAGE_BYTES) {
					return output.toByteArray()
				}
			} finally {
				bitmap.recycle()
			}
			if (sampleSize >= largestDimension) {
				throw PptxReaderException("IMAGE_TOO_LARGE", "The rendered image exceeds the 4 MiB limit")
			}
			sampleSize *= 2
		}
	}

	fun readFont(family: String): ByteArray {
		ensureOpen()
		val path = embeddedFonts[family]
			?: throw PptxReaderException("FONT_MISSING", "The presentation does not embed this font")
		val entry = archive.getEntry(path)
			?: throw PptxReaderException("FONT_MISSING", "The embedded font is unavailable")
		if (entry.isDirectory || entry.size <= 0 || entry.size > PPTX_MAX_FONT_ENTRY_BYTES) {
			throw PptxReaderException("FONT_TOO_LARGE", "The embedded font exceeds the 2 MiB limit")
		}
		val data = openEntry(path).use { it.readBytes() }
		if (data.size < 16) {
			throw PptxReaderException("INVALID_FONT", "The embedded font container is invalid")
		}
		val littleEndian = java.nio.ByteOrder.LITTLE_ENDIAN
		val eotSize = java.nio.ByteBuffer.wrap(data, 0, 4).order(littleEndian)
			.int.toLong() and 0xffffffffL
		if (eotSize != data.size.toLong()) {
			throw PptxReaderException("INVALID_FONT", "The embedded font container is invalid")
		}
		val flags = java.nio.ByteBuffer.wrap(data, 12, 4).order(littleEndian)
			.int.toLong() and 0xffffffffL
		if (flags and EOT_FLAG_COMPRESSED != 0L) {
			throw PptxReaderException(
				"FONT_COMPRESSION_UNSUPPORTED",
				"The embedded font uses a proprietary compression format",
			)
		}
		val fontDataSize = java.nio.ByteBuffer.wrap(data, 4, 4).order(littleEndian)
			.int.toLong() and 0xffffffffL
		if (fontDataSize < 4 || fontDataSize > PPTX_MAX_FONT_DATA_BYTES ||
			fontDataSize > data.size
		) {
			throw PptxReaderException("FONT_TOO_LARGE", "The embedded font data exceeds the 1 MiB limit")
		}
		val start = data.size - fontDataSize.toInt()
		val signature = String(data, start, 4, Charsets.ISO_8859_1)
		if (signature !in setOf("\u0000\u0001\u0000\u0000", "OTTO", "ttcf")) {
			throw PptxReaderException("INVALID_FONT", "The embedded font data is not a supported OpenType font")
		}
		return data.copyOfRange(start, data.size)
	}

	private fun parseSlide(
		path: String,
		index: Int,
		relationships: Map<String, String>,
		inheritedBackground: PptxBackground?,
	): Map<String, Any?> {
		val input = openEntry(path)
		val parser = createParser(input)
		val elements = mutableListOf<Map<String, Any?>>()
		var background = inheritedBackground
		var showMasterShapes = true
		var imageCount = 0
		var chartCount = 0
		parsingSlideTruncated = false
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG) continue
				when (parser.name) {
					"sld" -> showMasterShapes =
						parser.getAttributeValue(null, "showMasterSp") !in setOf("0", "false")
					"bg" -> background =
						parseBackgroundElement(parser, relationships) ?: background
					"grpSp" -> elements.addAll(parseGroup(parser, relationships))
					"sp" -> elements.add(parseShape(parser, relationships = relationships))
					"cxnSp" -> elements.add(parseShape(parser, relationships = relationships))
					"pic" -> {
						elements.add(parsePicture(parser, relationships))
					}
					"graphicFrame" -> {
						val frame = parseGraphicFrame(parser, relationships = relationships)
						if (frame["type"] == "chart") {
							chartCount++
							if (chartCount > PPTX_MAX_CHARTS_PER_SLIDE) {
								notShown.add("Additional charts are omitted by the 16-chart limit")
								val original = frame["chartData"] as? Map<*, *>
								elements.add(
									frame + mapOf(
										"chartData" to mapOf(
											"type" to "unsupported",
											"title" to (original?.get("title") as? String).orEmpty(),
											"series" to emptyList<Map<String, Any?>>(),
											"supported" to false,
										),
									),
								)
							} else {
								elements.add(frame)
							}
						} else {
							if (frame["type"] == "placeholder") {
								notShown.add("Charts or embedded objects")
							}
							elements.add(frame)
						}
					}
					"oleObj", "contentPart" -> {
						notShown.add("Embedded objects")
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
		val limitedElements = elements.map { element ->
			if (element["type"] != "image" || element["imagePath"] == null) {
				element
			} else {
				imageCount++
				if (imageCount <= PPTX_MAX_IMAGES_PER_SLIDE) {
					element
				} else {
					imageLimitPlaceholder(element)
				}
			}
		}
		return mapOf<String, Any?>(
			"index" to index,
			"backgroundColor" to background?.color,
			"backgroundGradientColors" to background?.gradientColors.orEmpty(),
			"backgroundGradientStops" to background?.gradientStops.orEmpty(),
			"backgroundGradientAngle" to (background?.gradientAngle ?: 0.0),
			"backgroundImagePath" to background?.imagePath,
			"background" to background,
			"showMasterShapes" to showMasterShapes,
			"elements" to limitedElements,
			"notShown" to (notShown.values() + ooxml.failures()).distinct(),
		)
	}

	private fun themeForMaster(path: String): OoxmlTheme {
		val input = try {
			openEntry(path)
		} catch (error: Exception) {
			ooxml.recordFailure("Could not read $path: ${error.message ?: "invalid part"}")
			return theme
		}
		return try {
			theme.withColorMap(OoxmlThemeParser.parseColorMap(input))
		} catch (error: Exception) {
			ooxml.recordFailure("Could not parse color map in $path: ${error.message ?: "invalid XML"}")
			theme
		} finally {
			input.close()
		}
	}

	private fun parseGroup(
		parser: XmlPullParser,
		relationships: Map<String, String>,
		parentTransform: PptxCoordinateTransform = PptxCoordinateTransform(),
	): List<Map<String, Any?>> {
		val elements = mutableListOf<Map<String, Any?>>()
		var transform = parentTransform
		var inGroupProperties = false
		var offsetX = 0.0
		var offsetY = 0.0
		var extentX = 0.0
		var extentY = 0.0
		var childOffsetX = 0.0
		var childOffsetY = 0.0
		var childExtentX = 0.0
		var childExtentY = 0.0
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when {
					parser.name == "grpSpPr" -> inGroupProperties = true
					parser.name == "xfrm" && inGroupProperties &&
						parser.namespace == DRAWING_NS -> {
						while (parser.next() != XmlPullParser.END_DOCUMENT) {
							if (parser.eventType == XmlPullParser.START_TAG) {
								when (parser.name) {
									"off" -> {
										offsetX = parser.getAttributeValue(null, "x")
											?.toDoubleOrNull() ?: offsetX
										offsetY = parser.getAttributeValue(null, "y")
											?.toDoubleOrNull() ?: offsetY
									}
									"ext" -> {
										extentX = parser.getAttributeValue(null, "cx")
											?.toDoubleOrNull() ?: extentX
										extentY = parser.getAttributeValue(null, "cy")
											?.toDoubleOrNull() ?: extentY
									}
									"chOff" -> {
										childOffsetX = parser.getAttributeValue(null, "x")
											?.toDoubleOrNull() ?: childOffsetX
										childOffsetY = parser.getAttributeValue(null, "y")
											?.toDoubleOrNull() ?: childOffsetY
									}
									"chExt" -> {
										childExtentX = parser.getAttributeValue(null, "cx")
											?.toDoubleOrNull() ?: childExtentX
										childExtentY = parser.getAttributeValue(null, "cy")
											?.toDoubleOrNull() ?: childExtentY
									}
								}
							} else if (parser.eventType == XmlPullParser.END_TAG &&
								parser.name == "xfrm" &&
								parser.namespace == DRAWING_NS
							) {
								break
							}
						}
						transform = if (extentX > 0 && extentY > 0 &&
							childExtentX > 0 && childExtentY > 0
						) {
							parentTransform.child(
								offsetX,
								offsetY,
								extentX,
								extentY,
								childOffsetX,
								childOffsetY,
								childExtentX,
								childExtentY,
							)
						} else {
							parentTransform
						}
						depth--
					}
					parser.name == "sp" || parser.name == "cxnSp" -> {
						elements.add(parseShape(parser, transform, relationships))
						depth--
					}
					parser.name == "pic" -> {
						elements.add(parsePicture(parser, relationships, transform))
						depth--
					}
					parser.name == "graphicFrame" -> {
						elements.add(
							parseGraphicFrame(parser, transform, relationships),
						)
						depth--
					}
					parser.name == "grpSp" -> {
						elements.addAll(parseGroup(parser, relationships, transform))
						depth--
					}
					parser.name == "oleObj" || parser.name == "contentPart" -> {
						elements.add(placeholderElement())
						skipElement(parser)
						depth--
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (parser.name == "grpSpPr") inGroupProperties = false
				depth--
			}
		}
		return elements
	}

	private fun parseShape(
		parser: XmlPullParser,
		transform: PptxCoordinateTransform = PptxCoordinateTransform(),
		relationships: Map<String, String> = emptyMap(),
	): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		var hasTransform = false
		var shape = "rect"
		var fill: Int? = null
		val gradientColors = mutableListOf<Int>()
		val gradientStops = mutableListOf<Double>()
		var gradientAngle = 0.0
		var line: Int? = null
		var lineWidth = 1.0
		var rotation = 0.0
		var flipHorizontal = false
		var flipVertical = false
		var textVerticalAlignment = "top"
		var textInsetLeft = 91_440L
		var textInsetTop = 45_720L
		var textInsetRight = 91_440L
		var textInsetBottom = 45_720L
		var textScale = 1.0
		var imagePath: String? = null
		var imageCropLeft = 0.0
		var imageCropTop = 0.0
		var imageCropRight = 0.0
		var imageCropBottom = 0.0
		var placeholderType: String? = null
		var placeholderIndex: Int? = null
		var customPaths = emptyList<Map<String, Any?>>()
		var lineMode = false
		var inShapeProperties = false
		var inSolidFill = false
		var inGradientFill = false
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
					"ph" -> {
						placeholderType = parser.getAttributeValue(null, "type") ?: "obj"
						placeholderIndex = parser.getAttributeValue(null, "idx")?.toIntOrNull() ?: 0
					}
					"off" -> if (parser.namespace == DRAWING_NS) {
						hasTransform = true
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> if (parser.namespace == DRAWING_NS) {
						hasTransform = true
						cx = parser.getAttributeValue(null, "cx")?.toLongOrNull() ?: cx
						cy = parser.getAttributeValue(null, "cy")?.toLongOrNull() ?: cy
					}
					"xfrm" -> if (parser.namespace == DRAWING_NS) {
						rotation = parser.getAttributeValue(null, "rot")
							?.toLongOrNull()
							?.let(OoxmlUnits::angle60000ToDegrees) ?: 0.0
						flipHorizontal = parser.getAttributeValue(null, "flipH") in setOf("1", "true")
						flipVertical = parser.getAttributeValue(null, "flipV") in setOf("1", "true")
					}
					"spPr" -> if (parser.namespace == PRESENTATION_NS) {
						inShapeProperties = true
					}
					"bodyPr" -> if (parser.namespace == DRAWING_NS) {
						textVerticalAlignment = when (
							parser.getAttributeValue(null, "anchor")
						) {
							"ctr" -> "center"
							"b" -> "bottom"
							else -> "top"
						}
						textInsetLeft = parser.getAttributeValue(null, "lIns")
							?.toLongOrNull() ?: textInsetLeft
						textInsetTop = parser.getAttributeValue(null, "tIns")
							?.toLongOrNull() ?: textInsetTop
						textInsetRight = parser.getAttributeValue(null, "rIns")
							?.toLongOrNull() ?: textInsetRight
						textInsetBottom = parser.getAttributeValue(null, "bIns")
							?.toLongOrNull() ?: textInsetBottom
						val vertical = parser.getAttributeValue(null, "vert")
						if (vertical in setOf("vert", "vert270", "eaVert")) {
							textVerticalAlignment = "vertical"
						}
					}
					"solidFill" -> if (parser.namespace == DRAWING_NS) {
						inSolidFill = true
					}
					"gradFill" -> if (parser.namespace == DRAWING_NS) {
						inGradientFill = true
						gradientColors.clear()
						gradientStops.clear()
					}
					"gs" -> if (inGradientFill) {
						gradientStops.add(
							((parser.getAttributeValue(null, "pos")?.toDoubleOrNull()
								?: gradientStops.size * 50_000.0) / 100_000.0).coerceIn(0.0, 1.0),
						)
					}
					"lin" -> if (inGradientFill) {
						gradientAngle = (parser.getAttributeValue(null, "ang")?.toDoubleOrNull()
							?: 0.0) / 60_000.0
					}
					"normAutofit" -> textScale =
						((parser.getAttributeValue(null, "fontScale")?.toDoubleOrNull()
							?: 100_000.0) / 100_000.0).coerceIn(0.5, 1.0)
					"lnSpcReduction" -> textScale = minOf(
						textScale,
						(1.0 - (parser.getAttributeValue(null, "val")?.toDoubleOrNull()
							?: 0.0) / 100_000.0).coerceIn(0.5, 1.0),
					)
					"prstGeom" -> shape = normalizedShape(parser.getAttributeValue(null, "prst"))
					"custGeom" -> {
						shape = "custom"
						customPaths = parseCustomGeometry(parser)
						depth--
					}
					"blip" -> if (inShapeProperties) {
						val relationshipId = parser.getAttributeValue(REL_NS, "embed")
						imagePath = relationships[relationshipId]
					}
					"srcRect" -> {
						imageCropLeft = (parser.getAttributeValue(null, "l")?.toDoubleOrNull()
							?: 0.0) / 100_000.0
						imageCropTop = (parser.getAttributeValue(null, "t")?.toDoubleOrNull()
							?: 0.0) / 100_000.0
						imageCropRight = (parser.getAttributeValue(null, "r")?.toDoubleOrNull()
							?: 0.0) / 100_000.0
						imageCropBottom = (parser.getAttributeValue(null, "b")?.toDoubleOrNull()
							?: 0.0) / 100_000.0
					}
					"ln" -> {
						lineMode = true
						lineWidth = (parser.getAttributeValue(null, "w")?.toDoubleOrNull()
							?.div(12_700.0) ?: 1.0).coerceIn(0.5, 24.0)
					}
					"p" -> {
						paragraph = mutableMapOf("alignment" to "left", "level" to 0)
						paragraphRuns = mutableListOf()
						paragraphDefaultStyle = PptxStyle()
					}
					"r", "fld" -> runStyle = paragraphDefaultStyle
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
						val level = parser.getAttributeValue(null, "lvl")?.toIntOrNull()
							?.coerceIn(0, 8) ?: 0
						paragraph?.set("level", level)
						val margin = parser.getAttributeValue(null, "marL")?.toDoubleOrNull()
							?.let { it / SLIDE_UNIT }
						val hanging = parser.getAttributeValue(null, "indent")?.toDoubleOrNull()
							?.let { it / SLIDE_UNIT } ?: 0.0
						if (margin != null) paragraph?.set("indent", (margin - hanging).coerceIn(-200.0, 400.0))
						parser.getAttributeValue(null, "spcBef")?.toDoubleOrNull()
							?.div(100.0)?.let { paragraph?.set("spaceBefore", it.coerceIn(0.0, 120.0)) }
						parser.getAttributeValue(null, "spcAft")?.toDoubleOrNull()
							?.div(100.0)?.let { paragraph?.set("spaceAfter", it.coerceIn(0.0, 120.0)) }
					}
					"buChar" -> paragraph?.set("bullet", parser.getAttributeValue(null, "char") ?: "•")
					"buAutoNum" -> {
						bulletCounter++
						paragraph?.set(
							"bullet",
							when (parser.getAttributeValue(null, "type")) {
								"alphaLcParenBoth" -> "(${('a'.code + (bulletCounter - 1) % 26).toChar()})"
								"alphaLcPeriod" -> "${('a'.code + (bulletCounter - 1) % 26).toChar()}."
								"romanLcPeriod" -> "$bulletCounter."
								"arabicParenBoth" -> "($bulletCounter)"
								"arabicParenR" -> "$bulletCounter)"
								else -> "$bulletCounter."
							},
						)
					}
					"rPr", "defRPr", "endParaRPr" -> {
						inRunProperties = true
						runPropertiesTag = parser.name
						runStyle = styleFromAttributes(
							parser,
							if (parser.name == "rPr") paragraphDefaultStyle
							else runStyle,
						)
						if (parser.name == "defRPr") paragraphDefaultStyle = runStyle
					}
					"lumMod", "shade", "lumOff", "tint", "satMod", "hueMod",
					"alpha", "comp", "inv" -> {
						if (parser.namespace == DRAWING_NS) {
							val amount = parser.getAttributeValue(null, "val")
								?.toIntOrNull()?.coerceIn(0, 100_000) ?: continue
							when {
								inRunProperties -> runStyle = runStyle.copy(
									color = runStyle.color?.let {
										OoxmlThemeParser.transformColor(it, listOf(parser.name to amount))
									},
								)
								inShapeProperties && (inSolidFill || inGradientFill) -> {
									if (lineMode) {
										line = line?.let {
											OoxmlThemeParser.transformColor(it, listOf(parser.name to amount))
										}
									} else {
										fill = fill?.let {
											OoxmlThemeParser.transformColor(it, listOf(parser.name to amount))
										}
									}
								}
							}
						}
					}
					"srgbClr", "schemeClr" -> {
						val color = parseColor(parser.getAttributeValue(null, "val"))
						if (inGradientFill && color != null &&
							gradientColors.size < 8
						) {
							gradientColors.add(color)
							if (gradientStops.size < gradientColors.size) {
								gradientStops.add(
									if (gradientColors.size == 1) 0.0 else 1.0,
								)
							}
						}
						if (inRunProperties) {
							runStyle = runStyle.copy(color = color)
							if (runPropertiesTag == "defRPr") {
								paragraphDefaultStyle = paragraphDefaultStyle.copy(color = color)
							}
						} else if (inShapeProperties && (inSolidFill || inGradientFill)) {
							if (lineMode) {
								line = color
							} else if (inGradientFill) {
								if (fill == null) fill = color
							} else {
								fill = color
							}
						}
					}
					"latin" -> if (inRunProperties && parser.namespace == DRAWING_NS) {
						val family = activeTheme.font(parser.getAttributeValue(null, "typeface"))
						if (family != null) {
							runStyle = runStyle.copy(fontFamily = family)
							if (runPropertiesTag == "defRPr") {
								paragraphDefaultStyle = paragraphDefaultStyle.copy(fontFamily = family)
							}
						}
					}
					"noFill" -> if (inShapeProperties && !lineMode) fill = null
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
					"rPr", "defRPr", "endParaRPr" -> {
						inRunProperties = false
						runPropertiesTag = null
					}
					"solidFill" -> if (parser.namespace == DRAWING_NS) {
						inSolidFill = false
					}
					"gradFill" -> if (parser.namespace == DRAWING_NS) {
						inGradientFill = false
					}
					"spPr" -> if (parser.namespace == PRESENTATION_NS) {
						inShapeProperties = false
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
		return element(
			if (imagePath == null) "shape" else "image",
			transform.x(x),
			transform.y(y),
			transform.width(cx),
			transform.height(cy),
			shape,
			fill,
			line,
			lineWidth,
			paragraphs,
			imagePath = imagePath,
			rotationDegrees = rotation,
			customPaths = customPaths,
			textVerticalAlignment = textVerticalAlignment,
			textInsetLeft = textInsetLeft.toDouble() / SLIDE_UNIT,
			textInsetTop = textInsetTop.toDouble() / SLIDE_UNIT,
			textInsetRight = textInsetRight.toDouble() / SLIDE_UNIT,
			textInsetBottom = textInsetBottom.toDouble() / SLIDE_UNIT,
			flipHorizontal = flipHorizontal,
			flipVertical = flipVertical,
			imageCropLeft = imageCropLeft,
			imageCropTop = imageCropTop,
			imageCropRight = imageCropRight,
			imageCropBottom = imageCropBottom,
			fillGradientColors = gradientColors,
			fillGradientStops = gradientStops,
			fillGradientAngle = gradientAngle,
			placeholderType = placeholderType,
			placeholderIndex = placeholderIndex,
			hasTransform = hasTransform,
			textScale = textScale,
		)
	}

	private fun parseCustomGeometry(parser: XmlPullParser): List<Map<String, Any?>> {
		val paths = mutableListOf<Map<String, Any?>>()
		var pathWidth = 1.0
		var pathHeight = 1.0
		var pathFill = true
		var pathStroke = true
		var commands = mutableListOf<Map<String, Any?>>()
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"path" -> {
						pathWidth = parser.getAttributeValue(null, "w")
							?.toDoubleOrNull()?.takeIf { it > 0 } ?: 1.0
						pathHeight = parser.getAttributeValue(null, "h")
							?.toDoubleOrNull()?.takeIf { it > 0 } ?: 1.0
						pathFill = parser.getAttributeValue(null, "fill") != "none"
						pathStroke = parser.getAttributeValue(null, "stroke") !in
							setOf("0", "false")
						commands = mutableListOf()
					}
					"moveTo", "lnTo", "cubicBezTo", "quadBezTo" -> {
						val command = parseCustomPathCommand(parser, pathWidth, pathHeight)
						if (commands.size < PPTX_MAX_CUSTOM_COMMANDS_PER_PATH) {
							commands.add(command)
						}
						depth--
					}
					"close" -> {
						if (commands.size < PPTX_MAX_CUSTOM_COMMANDS_PER_PATH) {
							commands.add(
								mapOf("type" to "close", "points" to emptyList<List<Double>>()),
							)
						}
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (parser.name == "path") {
					if (paths.size < PPTX_MAX_CUSTOM_PATHS) {
						paths.add(
							mapOf(
								"fill" to pathFill,
								"stroke" to pathStroke,
								"commands" to commands,
							),
						)
					}
				}
				depth--
			}
		}
		return paths
	}

	private fun parseCustomPathCommand(
		parser: XmlPullParser,
		pathWidth: Double,
		pathHeight: Double,
	): Map<String, Any?> {
		val type = parser.name
		val points = mutableListOf<List<Double>>()
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				if (parser.name == "pt") {
					val x = parser.getAttributeValue(null, "x")?.toDoubleOrNull()
					val y = parser.getAttributeValue(null, "y")?.toDoubleOrNull()
					if (x != null && y != null && points.size < 3) {
						points.add(listOf(x / pathWidth, y / pathHeight))
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		return mapOf("type" to type, "points" to points)
	}

	private fun parsePicture(
		parser: XmlPullParser,
		relationships: Map<String, String>,
		transform: PptxCoordinateTransform = PptxCoordinateTransform(),
	): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		var rotation = 0.0
		var relationId: String? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"off" -> if (parser.namespace == DRAWING_NS) {
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> if (parser.namespace == DRAWING_NS) {
						cx = parser.getAttributeValue(null, "cx")?.toLongOrNull() ?: cx
						cy = parser.getAttributeValue(null, "cy")?.toLongOrNull() ?: cy
					}
					"xfrm" -> if (parser.namespace == DRAWING_NS) {
						rotation = parser.getAttributeValue(null, "rot")
							?.toLongOrNull()
							?.let(OoxmlUnits::angle60000ToDegrees) ?: 0.0
					}
					"blip" -> relationId = parser.getAttributeValue(REL_NS, "embed")
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		val target = relationId?.let(relationships::get)
			?: return placeholderElement()
		OoxmlImageSupport.unsupportedFormat(target)?.let(notShown::add)
		return element(
			"image",
			transform.x(x),
			transform.y(y),
			transform.width(cx),
			transform.height(cy),
			imagePath = target,
			rotationDegrees = rotation,
		)
	}

	private fun parseGraphicFrame(
		parser: XmlPullParser,
		transform: PptxCoordinateTransform = PptxCoordinateTransform(),
		relationships: Map<String, String> = emptyMap(),
	): Map<String, Any?> {
		var x = 0L
		var y = 0L
		var cx = 0L
		var cy = 0L
		val rows = mutableListOf<List<String>>()
		var row: MutableList<String>? = null
		var cell: StringBuilder? = null
		var tableTruncated = false
		var chartRelationshipId: String? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"chart" -> chartRelationshipId =
						parser.getAttributeValue(REL_NS, "id")
					"off" -> if (parser.namespace == DRAWING_NS) {
						x = parser.getAttributeValue(null, "x")?.toLongOrNull() ?: x
						y = parser.getAttributeValue(null, "y")?.toLongOrNull() ?: y
					}
					"ext" -> if (parser.namespace == DRAWING_NS) {
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
		if (chartRelationshipId != null) {
			val chartPath = relationships[chartRelationshipId]
			val chartData = chartPath?.let { target ->
				runCatching {
					openEntry(target).use { OoxmlChartParser.parse(it, theme) }
				}.getOrNull()
			}
			if (chartData == null) {
				notShown.add("Chart data could not be read")
				return positionedPlaceholder(
					x,
					y,
					cx,
					cy,
					"Chart not shown",
				)
			}
			if (chartData["supported"] != true) {
				val chartTitle = chartData["title"] as? String
				notShown.add(
					if (chartTitle.isNullOrBlank()) "Unsupported chart type"
					else "Unsupported chart: $chartTitle",
				)
			}
			if (chartData["truncated"] == true) {
				notShown.add("Chart data is truncated to viewer limits")
			}
			return element(
				"chart",
				transform.x(x),
				transform.y(y),
				transform.width(cx),
				transform.height(cy),
			) + mapOf("chartData" to chartData)
		}
		if (rows.isEmpty()) return placeholderElement()
		val result = element(
			"table",
			transform.x(x),
			transform.y(y),
			transform.width(cx),
			transform.height(cy),
		).toMutableMap()
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
		rotationDegrees: Double = 0.0,
		customPaths: List<Map<String, Any?>> = emptyList(),
		textVerticalAlignment: String = "top",
		textInsetLeft: Double = 0.0,
		textInsetTop: Double = 0.0,
		textInsetRight: Double = 0.0,
		textInsetBottom: Double = 0.0,
		flipHorizontal: Boolean = false,
		flipVertical: Boolean = false,
		imageCropLeft: Double = 0.0,
		imageCropTop: Double = 0.0,
		imageCropRight: Double = 0.0,
		imageCropBottom: Double = 0.0,
		fillGradientColors: List<Int> = emptyList(),
		fillGradientStops: List<Double> = emptyList(),
		fillGradientAngle: Double = 0.0,
		placeholderType: String? = null,
		placeholderIndex: Int? = null,
		hasTransform: Boolean = true,
		textScale: Double = 1.0,
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
		"rotationDegrees" to rotationDegrees,
		"textVerticalAlignment" to textVerticalAlignment,
		"textInsetLeft" to textInsetLeft,
		"textInsetTop" to textInsetTop,
		"textInsetRight" to textInsetRight,
		"textInsetBottom" to textInsetBottom,
		"paragraphs" to paragraphs,
		"tableRows" to tableRows,
		"imagePath" to imagePath,
		"customPaths" to customPaths,
		"flipHorizontal" to flipHorizontal,
		"flipVertical" to flipVertical,
		"imageCropLeft" to imageCropLeft,
		"imageCropTop" to imageCropTop,
		"imageCropRight" to imageCropRight,
		"imageCropBottom" to imageCropBottom,
		"fillGradientColors" to fillGradientColors,
		"fillGradientStops" to fillGradientStops,
		"fillGradientAngle" to fillGradientAngle,
		"placeholderType" to placeholderType,
		"placeholderIndex" to placeholderIndex,
		"hasTransform" to hasTransform,
		"textScale" to textScale,
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

	private fun readBackground(path: String): PptxBackground? {
		if (archive.getEntry(path) == null) return null
		val input = openEntry(path)
		val parser = createParser(input)
		val relationships = readRelationships(relationshipPath(path))
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG && parser.name == "bg") {
					return parseBackgroundElement(parser, relationships)
				}
			}
		} finally {
			input.close()
		}
		return null
	}

	private fun parseBackgroundElement(
		parser: XmlPullParser,
		relationships: Map<String, String> = emptyMap(),
	): PptxBackground? {
		var depth = 1
		var color: Int? = null
		var imagePath: String? = null
		var inGradient = false
		val gradientColors = mutableListOf<Int>()
		val gradientStops = mutableListOf<Double>()
		var gradientAngle = 0.0
		var pendingStop = 0.0
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"gradFill" -> inGradient = true
					"gs" -> pendingStop =
						((parser.getAttributeValue(null, "pos")?.toDoubleOrNull() ?: 0.0) /
							100_000.0).coerceIn(0.0, 1.0)
					"lin" -> gradientAngle =
						(parser.getAttributeValue(null, "ang")?.toDoubleOrNull() ?: 0.0) /
							60_000.0
					"blip" -> imagePath = parser.getAttributeValue(REL_NS, "embed")
						?.let(relationships::get)
					"srgbClr", "schemeClr", "sysClr", "prstClr" -> {
						val raw = parser.getAttributeValue(null, "val")
							?: parser.getAttributeValue(null, "lastClr")
						val parsed = parseColor(raw) ?: color
						if (inGradient && parsed != null && gradientColors.size < 8) {
							gradientColors.add(parsed)
							gradientStops.add(pendingStop)
						} else {
							color = parsed
						}
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (parser.name == "gradFill") inGradient = false
				depth--
			}
		}
		if (imagePath == null && gradientColors.isEmpty() && color == null) return null
		return PptxBackground(
			color = color ?: gradientColors.firstOrNull(),
			gradientColors = gradientColors,
			gradientStops = gradientStops,
			gradientAngle = gradientAngle,
			imagePath = imagePath,
		)
	}

	private fun readRelationships(path: String): Map<String, String> {
		val owner = ownerPartForRelationshipsPath(path) ?: return emptyMap()
		return ooxml.relationships(owner)
			.filterValues { !it.external }
			.mapValues { it.value.target }
	}

	private fun relationshipTypeForTarget(relationshipPath: String?, target: String): String {
		if (relationshipPath == null) return ""
		val owner = ownerPartForRelationshipsPath(relationshipPath) ?: return ""
		return ooxml.relationships(owner).values
			.firstOrNull { !it.external && it.target == target }?.type.orEmpty()
	}

	private fun ownerPartForRelationshipsPath(path: String): String? {
		val marker = "/_rels/"
		val index = path.indexOf(marker)
		if (index < 0 || !path.endsWith(".rels")) return null
		return path.substring(0, index + 1) +
			path.substring(index + marker.length).removeSuffix(".rels")
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
		val strike = parser.getAttributeValue(null, "strike")
		return PptxStyle(
			bold = enabled("b", original.bold),
			italic = enabled("i", original.italic),
			underline = enabled("u", original.underline),
			strikethrough = if (strike == null) original.strikethrough else
				strike !in setOf("0", "false", "none", "noStrike"),
			fontSize = size ?: original.fontSize,
			color = original.color,
			fontFamily = original.fontFamily,
			superscript = parser.getAttributeValue(null, "baseline")?.toIntOrNull()
				?.let { it > 0 } ?: original.superscript,
			subscript = parser.getAttributeValue(null, "baseline")?.toIntOrNull()
				?.let { it < 0 } ?: original.subscript,
		)
	}

	private fun normalizedShape(value: String?): String = when (value) {
		"ellipse", "arc", "pie" -> "ellipse"
		"roundRect", "round1Rect", "round2SameRect", "round2DiagRect",
		"snipRoundRect", "snip2SameRect", "snip2DiagRect" -> "roundRect"
		"line", "lineInv" -> "line"
		"triangle", "rtTriangle", "diamond", "parallelogram", "trapezoid",
		"pentagon", "hexagon", "octagon", "leftArrow", "rightArrow",
		"upArrow", "downArrow", "leftRightArrow", "upDownArrow",
		"chevron", "star5", "star4", "star6", "star8",
		"wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout",
		"cloudCallout", "leftBrace", "rightBrace", "heart" -> value
		else -> "rect"
	}

	private fun parseColor(value: String?): Int? {
		if (value == null) return null
		return activeTheme.color(value)
			?: value.toLongOrNull(16)?.takeIf { it <= 0xffffff }?.toInt()
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
				val sharedPackage = OoxmlPackage(
					archive,
					PPTX_MAX_ENTRY_BYTES,
					PPTX_MAX_TOTAL_INFLATED_BYTES,
				)
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
				val embeddedFonts = mutableMapOf<String, String>()
				val presentationInput = openMetadataEntry("ppt/presentation.xml")
				val presentationParser = createParser(presentationInput)
				var embeddedFontFamily: String? = null
				try {
					while (presentationParser.next() != XmlPullParser.END_DOCUMENT) {
						if (presentationParser.eventType == XmlPullParser.START_TAG) {
							when (presentationParser.name) {
								"embeddedFont" -> embeddedFontFamily = null
								"font" -> if (presentationParser.namespace == P_NS) {
									embeddedFontFamily = presentationParser.getAttributeValue(null, "typeface")
								}
								"regular", "bold", "italic", "boldItalic" -> {
									val family = embeddedFontFamily
									val relationshipId = presentationParser.getAttributeValue(REL_NS, "id")
									val target = relationshipId?.let(rootRelationships::get)
									if (family != null && target != null &&
										rootTypes[relationshipId]?.endsWith("/font") == true
									) {
										embeddedFonts.putIfAbsent(family, target)
									}
								}
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
						} else if (presentationParser.eventType == XmlPullParser.END_TAG &&
							presentationParser.name == "embeddedFont"
						) {
							embeddedFontFamily = null
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
				val themePath = rootRelationships.entries.firstOrNull {
					rootTypes[it.key]?.endsWith("/theme") == true
				}?.value ?: "ppt/theme/theme1.xml"
				val theme = try {
					sharedPackage.optionalPart(themePath)?.use(OoxmlThemeParser::parse)
						?: OoxmlTheme(
							emptyMap(),
							emptyMap(),
							emptyMap(),
							emptyList(),
							emptyList(),
							emptyMap(),
						)
				} catch (error: Exception) {
					sharedPackage.recordFailure(
						"Could not parse $themePath: ${error.message ?: "invalid theme"}",
					)
					OoxmlTheme(
						emptyMap(),
						emptyMap(),
						emptyMap(),
						emptyList(),
						emptyList(),
						emptyMap(),
					)
				}
				return PptxPresentation(
					archive,
					file,
					UUID.randomUUID().toString(),
					width / SLIDE_UNIT,
					height / SLIDE_UNIT,
					records,
					embeddedFonts,
					sharedPackage,
					theme,
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
private const val PRESENTATION_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
private const val DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
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
