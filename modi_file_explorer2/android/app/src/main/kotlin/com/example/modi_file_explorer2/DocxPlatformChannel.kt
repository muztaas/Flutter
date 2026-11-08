package com.example.modi_file_explorer2

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipFile

private const val DOCX_MAX_FILE_BYTES = 1L shl 30
private const val DOCX_MAX_ENTRY_BYTES = 64L * 1024 * 1024
private const val DOCX_MAX_TOTAL_INFLATED_BYTES = 256L * 1024 * 1024
private const val DOCX_MAX_ARCHIVE_ENTRIES = 20_000
private const val DOCX_MAX_BLOCKS = 200_000
private const val DOCX_MAX_TABLE_COLUMNS = 256
private const val DOCX_MAX_FLOATING_BACKGROUNDS = 256
private const val DOCX_MAX_CELL_TEXT = 65_536
private const val DOCX_MAX_IMAGE_BYTES = 16L * 1024 * 1024
private const val DOCX_BATCH_BLOCKS = 128

private class DocxReaderException(val code: String, message: String) : Exception(message)

private data class DocxTableCell(
	val runs: List<Map<String, Any?>>,
	val gridSpan: Int,
)

private data class DocxNumberingDefinition(
	val format: String,
	val marker: String,
	val leftIndent: Double?,
	val hangingIndent: Double?,
)

internal class DocxPlatformChannel(
	private val activity: MainActivity,
	messenger: BinaryMessenger,
) {
	private val methods = MethodChannel(messenger, "modi_file_explorer2/docx")
	private val executor = Executors.newSingleThreadExecutor()
	private val mainHandler = Handler(Looper.getMainLooper())
	private val documents = ConcurrentHashMap<String, DocxDocument>()

	init {
		methods.setMethodCallHandler(::handle)
	}

	private fun handle(call: MethodCall, result: MethodChannel.Result) {
		val arguments = call.arguments as? Map<*, *>
		when (call.method) {
			"openDocument" -> {
				val path = arguments?.get("path") as? String
				if (path.isNullOrBlank()) {
					result.error("INVALID_ARGUMENT", "A DOCX file path is required", null)
					return
				}
				runWorker(result) {
					val document = DocxDocument.open(File(path))
					documents[document.id] = document
					mapOf("id" to document.id)
				}
			}
			"readNextBlocks" -> runDocumentMethod(arguments, result) {
				it.readNextBlocks()
			}
			"readImage" -> runDocumentMethod(arguments, result) { document ->
				val path = arguments?.get("path") as? String
					?: throw DocxReaderException("INVALID_ARGUMENT", "An image path is required")
				document.readImage(path)
			}
			"openExternalLink" -> runDocumentMethod(arguments, result) { _ ->
				val raw = arguments?.get("uri") as? String
					?: throw DocxReaderException("INVALID_ARGUMENT", "A link is required")
				val uri = Uri.parse(raw)
				if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank() ||
					uri.userInfo != null
				) {
					throw DocxReaderException("INVALID_LINK", "Only standard web links can be opened")
				}
				val intent = Intent(Intent.ACTION_VIEW, uri)
				if (intent.resolveActivity(activity.packageManager) == null) {
					throw DocxReaderException("NO_LINK_HANDLER", "No app can open this link")
				}
				activity.runOnUiThread { activity.startActivity(intent) }
				null
			}
			"closeDocument" -> {
				val id = arguments?.get("id") as? String
				executor.execute {
					if (!id.isNullOrBlank()) documents.remove(id)?.close()
					mainHandler.post { result.success(null) }
				}
			}
			else -> result.notImplemented()
		}
	}

	private fun runDocumentMethod(
		arguments: Map<*, *>?,
		result: MethodChannel.Result,
		block: (DocxDocument) -> Any?,
	) {
		val id = arguments?.get("id") as? String
		if (id.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "A document identifier is required", null)
			return
		}
		runWorker(result) {
			val document = documents[id]
				?: throw DocxReaderException("DOCUMENT_CLOSED", "The document is closed")
			block(document)
		}
	}

	private fun runWorker(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (error: Throwable) {
				val readerError = error as? DocxReaderException
				mainHandler.post {
					result.error(
						readerError?.code ?: "DOCX_READ_FAILED",
						readerError?.message ?: error.message ?: "Could not read the DOCX document",
						null,
					)
				}
			}
		}
	}
}

private data class DocxTextStyle(
	val bold: Boolean = false,
	val italic: Boolean = false,
	val underline: Boolean = false,
	val strike: Boolean = false,
	val fontSize: Double? = null,
	val color: Int? = null,
	val highlight: Int? = null,
) {
	fun channelValue(text: String, hyperlink: String? = null): Map<String, Any?> = mapOf(
		"text" to text,
		"bold" to bold,
		"italic" to italic,
		"underline" to underline,
		"strike" to strike,
		"fontSize" to fontSize,
		"color" to color,
		"highlight" to highlight,
		"hyperlink" to hyperlink,
	)
}

private class DocxDocument private constructor(
	private val archive: ZipFile,
	private val file: File,
	val id: String,
) {
	private var inflatedBytes = 0L
	private var parser: XmlPullParser
	private var documentInput: InputStream
	private val inflatedEntryBytes = mutableMapOf<String, Long>()
	private val relationships = mutableMapOf<String, String>()
	private val styles = mutableMapOf<String, Map<String, Any?>>()
	private val themeColors = mutableMapOf<String, Int>()
	private val numbering = mutableMapOf<Pair<Int, Int>, DocxNumberingDefinition>()
	private val listCounters = mutableMapOf<Pair<Int, Int>, Int>()
	private var blockCount = 0
	private var floatingBackgroundCount = 0
	private var retainedCharacters = 0
	private var truncated = false
	private var complete = false
	private var pendingPageBreak = false
	private var closed = false
	private val deferredBlocks = ArrayDeque<Map<String, Any?>>()
	private var insideTable = false
	private var nextTableId = 0
	private var nextFloatingId = 0
	private var activeTableId = 0
	private val tableColumnWidths = mutableListOf<Double>()

	init {
		validateContentType()
		readRelationships()
		readThemeColors()
		readStyles()
		readNumbering()
		documentInput = openEntry("word/document.xml")
		parser = createParser(documentInput)
	}

	private fun validateContentType() {
		val input = openEntry("[Content_Types].xml")
		val xml = createParser(input)
		var valid = false
		try {
			while (xml.next() != XmlPullParser.END_DOCUMENT) {
				if (xml.eventType == XmlPullParser.START_TAG &&
					xml.name == "Override" &&
					xml.getAttributeValue(null, "PartName") == "/word/document.xml"
				) {
					valid = xml.getAttributeValue(null, "ContentType") == CONTENT_TYPE
					break
				}
			}
		} finally {
			input.close()
		}
		if (!valid) {
			throw DocxReaderException(
				"UNSUPPORTED_DOCUMENT",
				"Only standard .docx documents are supported; macro-enabled files are not handled",
			)
		}
	}

	fun readNextBlocks(): Map<String, Any?> {
		ensureOpen()
		val start = blockCount
		val blocks = ArrayList<Map<String, Any?>>(DOCX_BATCH_BLOCKS)
		while (!complete && !truncated && blocks.size < DOCX_BATCH_BLOCKS) {
			if (deferredBlocks.isNotEmpty()) {
				blocks.add(deferredBlocks.removeFirst())
				blockCount++
				continue
			}
			val event = parser.next()
			if (event == XmlPullParser.END_DOCUMENT) {
				complete = true
				break
			}
			if (event == XmlPullParser.END_TAG && parser.name == "tbl") {
				insideTable = false
				tableColumnWidths.clear()
				continue
			}
			if (event != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"p" -> {
					val hasBreakBefore = pendingPageBreak
					pendingPageBreak = false
					val parsed = parseParagraph()
					if (parsed.isNotEmpty()) {
						if (hasBreakBefore) {
							blocks.add(pageBreakBlock())
							blockCount++
							if (blocks.size >= DOCX_BATCH_BLOCKS) {
								deferredBlocks.addAll(parsed)
								continue
							}
						}
						for (block in parsed) {
							if (blockCount >= DOCX_MAX_BLOCKS) {
								truncated = true
								break
							}
							blocks.add(block)
							blockCount++
							if (blocks.size >= DOCX_BATCH_BLOCKS) {
								deferredBlocks.addAll(parsed.dropWhile { it !== block }.drop(1))
								break
							}
						}
					}
				}
				"tbl" -> if (!insideTable) {
					insideTable = true
					activeTableId = nextTableId++
					tableColumnWidths.clear()
				}
				"gridCol" -> if (insideTable && tableColumnWidths.size < DOCX_MAX_TABLE_COLUMNS) {
					tableColumnWidths.add(
						parser.getAttributeValue(WORD_NS, "w")
							?.toDoubleOrNull()
							?.div(15.0)
							?: 0.0,
					)
				}
				"tr" -> if (insideTable) {
					val row = parseTableRow()
					if (row != null) {
						if (blockCount >= DOCX_MAX_BLOCKS) {
							truncated = true
						} else {
							blocks.add(row)
							blockCount++
						}
					}
				}
				"drawing" -> addParsedBlocks(blocks, parseDrawingBlocks())
				"pict" -> {
					val runs = parseLegacyPicture()
					if (runs.isNotEmpty()) {
						if (blockCount >= DOCX_MAX_BLOCKS) {
							truncated = true
						} else {
							blocks.add(mapOf("type" to "paragraph", "runs" to runs))
							blockCount++
						}
					}
				}
				"AlternateContent" -> {
					addParsedBlocks(blocks, parseAlternateContentBlocks())
				}
				"object", "oleObject" -> {
					if (blockCount >= DOCX_MAX_BLOCKS) {
						truncated = true
					} else {
						blocks.add(placeholderBlock("Object not shown"))
						blockCount++
					}
					skipElement()
				}
				"sectPr" -> Unit
			}
		}
		return mapOf(
			"startIndex" to start,
			"blocks" to blocks,
			"blockCount" to blockCount,
			"complete" to complete,
			"truncated" to truncated,
		)
	}

	private fun parseParagraph(): List<Map<String, Any?>> {
		val runs = mutableListOf<Map<String, Any?>>()
		val embedded = mutableListOf<Map<String, Any?>>()
		var styleName: String? = null
		var alignment: String? = null
		var rtl: Boolean? = null
		var outlineLevel: Int? = null
		var numId: Int? = null
		var listLevel = 0
		var pageBreakBefore = false
		var spaceBefore: Double? = null
		var spaceAfter: Double? = null
		var lineHeight: Double? = null
		var indentLeft: Double? = null
		var indentRight: Double? = null
		var hangingIndent: Double? = null
		var bottomBorderColor: Int? = null
		var bottomBorderWidth: Double? = null
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "p") break
			if (parser.eventType != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"pPr" -> {
					var depth = 1
					while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
						if (parser.eventType == XmlPullParser.START_TAG) {
							when (parser.name) {
								"pStyle" -> styleName = parser.getAttributeValue(WORD_NS, "val")
								"jc" -> alignment = parser.getAttributeValue(WORD_NS, "val")
								"outlineLvl" -> outlineLevel = parser.getAttributeValue(WORD_NS, "val")
									?.toIntOrNull()
									?.coerceIn(0, 8)
								"bidi" -> {
									val value = parser.getAttributeValue(WORD_NS, "val")
									rtl = value != "0" && value != "false"
								}
								"pageBreakBefore" -> pageBreakBefore = true
								"numId" -> numId = parser.getAttributeValue(WORD_NS, "val")?.toIntOrNull()
								"ilvl" -> listLevel = parser.getAttributeValue(WORD_NS, "val")?.toIntOrNull() ?: 0
								"spacing" -> {
									spaceBefore = parser.getAttributeValue(WORD_NS, "before")
										?.toDoubleOrNull()?.div(15.0)
									spaceAfter = parser.getAttributeValue(WORD_NS, "after")
										?.toDoubleOrNull()?.div(15.0)
									lineHeight = parser.getAttributeValue(WORD_NS, "line")
										?.toDoubleOrNull()?.div(240.0)?.coerceIn(0.8, 3.0)
								}
								"bottom" -> {
									val borderStyle = parser.getAttributeValue(WORD_NS, "val")
									if (borderStyle != "nil" && borderStyle != "none") {
										bottomBorderColor = parseColor(
											parser.getAttributeValue(WORD_NS, "color"),
										) ?: 0
										bottomBorderWidth = parser.getAttributeValue(WORD_NS, "sz")
											?.toDoubleOrNull()?.div(6.0)?.coerceIn(0.3, 4.0)
									}
								}
								"ind" -> {
									indentLeft = parser.getAttributeValue(WORD_NS, "left")
										?.toDoubleOrNull()?.div(15.0)
									indentRight = parser.getAttributeValue(WORD_NS, "right")
										?.toDoubleOrNull()?.div(15.0)
									hangingIndent = parser.getAttributeValue(WORD_NS, "hanging")
										?.toDoubleOrNull()?.div(15.0)
								}
							}
							if (!parser.name.endsWith("Pr") && parser.name !in setOf("numPr")) skipElement()
							else if (parser.name == "numPr") {
								val numDepth = 1
								while (parser.next() != XmlPullParser.END_DOCUMENT) {
									if (parser.eventType == XmlPullParser.START_TAG &&
										parser.name == "numId"
									) numId = parser.getAttributeValue(WORD_NS, "val")?.toIntOrNull()
									if (parser.eventType == XmlPullParser.START_TAG &&
										parser.name == "ilvl"
									) listLevel = parser.getAttributeValue(WORD_NS, "val")?.toIntOrNull() ?: 0
									if (parser.eventType == XmlPullParser.END_TAG && parser.name == "numPr") break
								}
								@Suppress("UNUSED_VARIABLE") val consumed = numDepth
							}
						} else if (parser.eventType == XmlPullParser.END_TAG && parser.name == "pPr") {
							depth--
						}
					}
				}
				"r" -> runs.addAll(parseRun(null, embedded))
				"hyperlink" -> {
					val relationId = parser.getAttributeValue(REL_NS, "id")
					val anchor = parser.getAttributeValue(WORD_NS, "anchor")
					val target = relationId?.let(relationships::get)
						?: anchor?.let { "#$it" }
					runs.addAll(parseHyperlink(target, embedded))
				}
				"drawing" -> embedded.addAll(parseDrawingBlocks())
				"pict" -> runs.addAll(parseLegacyPicture())
				"AlternateContent" -> embedded.addAll(parseAlternateContentBlocks())
				"del", "moveFrom" -> skipElement()
				"oMath", "oMathPara" -> skipElement()
				"lastRenderedPageBreak" -> pendingPageBreak = true
				"br" -> if (parser.getAttributeValue(WORD_NS, "type") == "page") {
					pendingPageBreak = true
				}
			}
		}
		val result = mutableListOf<Map<String, Any?>>()
		if (runs.isNotEmpty() || embedded.isEmpty()) {
			val style = resolvedStyle(styleName)
			val list = numId?.let { listMarker(it, listLevel) }
			result.add(
				mapOf(
					"type" to "paragraph",
					"runs" to runs,
					"styleName" to (style?.get("name") ?: styleName),
					"alignment" to (alignment ?: style?.get("alignment")),
					"rtl" to (rtl ?: (style?.get("rtl") == true)),
					"styleBold" to style?.get("bold"),
					"styleItalic" to style?.get("italic"),
					"styleUnderline" to style?.get("underline"),
					"styleStrike" to style?.get("strike"),
					"styleFontSize" to style?.get("fontSize"),
					"styleColor" to style?.get("color"),
					"styleHighlight" to style?.get("highlight"),
					"headingLevel" to (
						outlineLevel ?: (style?.get("outlineLevel") as? Int)
							?.takeIf { it < 6 }
							?.plus(1)
					),
					"listMarker" to list?.marker,
					"listLevel" to listLevel.coerceIn(0, 8),
					"listIndentLeft" to list?.leftIndent,
					"listHangingIndent" to list?.hangingIndent,
					"spaceBefore" to (spaceBefore ?: style?.get("spaceBefore")),
					"spaceAfter" to (spaceAfter ?: style?.get("spaceAfter")),
					"lineHeight" to (lineHeight ?: style?.get("lineHeight")),
					"bottomBorderColor" to bottomBorderColor,
					"bottomBorderWidth" to bottomBorderWidth,
					"indentLeft" to (
						indentLeft ?: list?.leftIndent ?: style?.get("indentLeft")
					),
					"indentRight" to (indentRight ?: style?.get("indentRight")),
					"hangingIndent" to (
						hangingIndent ?: list?.hangingIndent ?: style?.get("hangingIndent")
					),
					"pageBreakBefore" to pageBreakBefore,
				),
			)
		}
		val orderedEmbedded = if (embedded.isNotEmpty() &&
			embedded.all { it["floatingTop"] is Number && it["floatingLeft"] is Number }
		) {
			embedded.sortedWith(
				compareBy<Map<String, Any?>> {
					(it["floatingTop"] as Number).toDouble()
				}.thenBy { (it["floatingLeft"] as Number).toDouble() },
			)
		} else {
			embedded
		}
		result.addAll(orderedEmbedded)
		return result
	}

	private fun parseRun(
		hyperlink: String?,
		embedded: MutableList<Map<String, Any?>>,
	): List<Map<String, Any?>> {
		var style = DocxTextStyle()
		val result = mutableListOf<Map<String, Any?>>()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "r") break
			if (parser.eventType != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"rPr" -> style = parseRunProperties()
				"t", "delText" -> {
					val text = keepText(readTextElement(parser.name))
					if (parser.name == "t") result.add(style.channelValue(text, hyperlink))
				}
				"tab" -> result.add(style.channelValue("\t", hyperlink))
				"br" -> {
					if (parser.getAttributeValue(WORD_NS, "type") == "page") {
						pendingPageBreak = true
					} else {
						result.add(style.channelValue("\n", hyperlink))
					}
				}
				"cr" -> result.add(style.channelValue("\n", hyperlink))
				"lastRenderedPageBreak" -> pendingPageBreak = true
				"drawing" -> embedded.addAll(parseDrawingBlocks())
				"AlternateContent" -> embedded.addAll(parseAlternateContentBlocks())
				"pict" -> {
					val pictureRuns = parseLegacyPicture()
					result.addAll(pictureRuns)
					if (pictureRuns.isEmpty()) {
						embedded.add(placeholderBlock("Object not shown"))
					}
				}
				"del", "moveFrom" -> skipElement()
				"oMath", "oMathPara" -> skipElement()
				"object", "oleObject" -> {
					embedded.add(placeholderBlock("Object not shown"))
					skipElement()
				}
			}
		}
		return result
	}

	private fun parseHyperlink(
		target: String?,
		embedded: MutableList<Map<String, Any?>>,
	): List<Map<String, Any?>> {
		val result = mutableListOf<Map<String, Any?>>()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "hyperlink") break
			if (parser.eventType == XmlPullParser.START_TAG && parser.name == "r") {
				result.addAll(parseRun(target, embedded))
			}
		}
		return result
	}

	private fun parseRunProperties(): DocxTextStyle {
		var styleId: String? = null
		var bold: Boolean? = null
		var italic: Boolean? = null
		var underline: Boolean? = null
		var strike: Boolean? = null
		var boldFont = false
		var fontSize: Double? = null
		var color: Int? = null
		var highlight: Int? = null
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "rPr") break
			if (parser.eventType != XmlPullParser.START_TAG) continue
			val value = parser.getAttributeValue(WORD_NS, "val")
			when (parser.name) {
				"rStyle" -> styleId = value
				"b", "bCs" -> bold = value != "0" && value != "false"
				"i" -> italic = value != "0" && value != "false"
				"u" -> underline = value != "none"
				"strike", "dstrike" -> strike = value != "0" && value != "false"
				"sz" -> fontSize = value?.toDoubleOrNull()?.div(2.0)?.coerceIn(6.0, 96.0)
				"color" -> color = parseColor(value)
				"highlight" -> highlight = parseHighlight(value)
				"rFonts" -> boldFont = listOf("ascii", "hAnsi", "eastAsia", "cs")
					.any { attribute ->
						isBoldFontName(parser.getAttributeValue(WORD_NS, attribute))
					}
				else -> if (parser.depth > 0 && parser.name !in setOf("vertAlign")) skipElement()
			}
		}
		val style = resolvedStyle(styleId)
		return DocxTextStyle(
			bold ?: (boldFont || (style?.get("bold") as? Boolean ?: false)),
			italic ?: (style?.get("italic") as? Boolean ?: false),
			underline ?: (style?.get("underline") as? Boolean ?: false),
			strike ?: (style?.get("strike") as? Boolean ?: false),
			fontSize ?: (style?.get("fontSize") as? Double),
			color ?: (style?.get("color") as? Int),
			highlight ?: (style?.get("highlight") as? Int),
		)
	}

	private fun parseTableRow(): Map<String, Any?>? {
		val cells = mutableListOf<DocxTableCell>()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "tr") break
			if (parser.eventType == XmlPullParser.START_TAG && parser.name == "tc") {
				if (cells.size < DOCX_MAX_TABLE_COLUMNS) {
					cells.add(parseTableCell())
				} else {
					truncated = true
					skipElement()
				}
			}
		}
		if (cells.isEmpty()) return null
		return mapOf(
			"type" to "tableRow",
			"tableId" to activeTableId,
			"columnWidths" to tableColumnWidths.toList(),
			"cellSpans" to cells.map(DocxTableCell::gridSpan),
			"rows" to listOf(cells.map(DocxTableCell::runs)),
		)
	}

	private fun parseTableCell(): DocxTableCell {
		val result = mutableListOf<Map<String, Any?>>()
		var gridSpan = 1
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "tc") break
			if (parser.eventType != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"tcPr" -> while (parser.next() != XmlPullParser.END_DOCUMENT) {
					if (parser.eventType == XmlPullParser.END_TAG && parser.name == "tcPr") break
					if (parser.eventType == XmlPullParser.START_TAG && parser.name == "gridSpan") {
						gridSpan = parser.getAttributeValue(WORD_NS, "val")
							?.toIntOrNull()
							?.coerceIn(1, DOCX_MAX_TABLE_COLUMNS)
							?: 1
					}
				}
				"p" -> {
					if (result.isNotEmpty()) {
						result.add(DocxTextStyle().channelValue("\n"))
					}
					for (paragraph in parseParagraph()) {
						val marker = paragraph["listMarker"] as? String
						if (marker != null) {
							result.add(DocxTextStyle().channelValue("$marker "))
						}
						result.addAll(
							(paragraph["runs"] as? List<*>)
								?.filterIsInstance<Map<String, Any?>>()
								.orEmpty(),
						)
					}
				}
			}
		}
		return DocxTableCell(result, gridSpan)
	}

	private fun parseDrawing(): List<Map<String, Any?>>? {
		var relationId: String? = null
		var width: Double? = null
		var height: Double? = null
		val runs = mutableListOf<Map<String, Any?>>()
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"blip" -> relationId = parser.getAttributeValue(REL_NS, "embed")
					"extent" -> {
						width = parser.getAttributeValue(null, "cx")?.toDoubleOrNull()?.div(9525.0)
						height = parser.getAttributeValue(null, "cy")?.toDoubleOrNull()?.div(9525.0)
					}
					"t" -> if (parser.namespace == DRAWING_NS) {
						val text = keepText(readTextElement(parser.name))
						if (text.isNotEmpty()) runs.add(DocxTextStyle().channelValue(text))
						depth--
					}
					"p" -> if (parser.namespace == WORD_NS) {
						val paragraph = parseParagraph()
						val paragraphRuns = paragraph.flatMap {
							(it["runs"] as? List<*>)?.filterIsInstance<Map<String, Any?>>()
								.orEmpty()
						}
						if (paragraphRuns.isNotEmpty()) {
							if (runs.any { it["text"] is String }) {
								runs.add(DocxTextStyle().channelValue("\n"))
							}
							runs.addAll(paragraphRuns)
						}
						depth--
					}
					"br" -> if (parser.namespace == DRAWING_NS) {
						runs.add(DocxTextStyle().channelValue("\n"))
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		val path = relationId?.let(relationships::get)
		if (path != null && path.startsWith("word/media/")) {
			runs.add(
				0,
				mapOf(
					"imagePath" to path,
					"width" to width?.coerceIn(24.0, 1200.0),
					"height" to height?.coerceIn(24.0, 900.0),
				),
			)
		}
		return runs.takeIf { it.isNotEmpty() }
	}

	private fun parseDrawingBlocks(): List<Map<String, Any?>> {
		var relationId: String? = null
		var width: Double? = null
		var height: Double? = null
		var left = 0.0
		var top = 0.0
		var positionAxis: String? = null
		var fillColor: Int? = null
		var outlineColor: Int? = null
		var outlineWidth: Double? = null
		var rotationDegrees: Double? = null
		var shape: String? = null
		var parserPositionIsFloating = false
		var insideSolidFill = false
		var insideLine = false
		var solidFillColor: Int? = null
		var solidFillLuminanceModulation = 100_000
		var solidFillLuminanceOffset = 0
		val contentBlocks = mutableListOf<Map<String, Any?>>()
		val directRuns = mutableListOf<Map<String, Any?>>()
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when {
					parser.name == "anchor" ->
						parserPositionIsFloating = true
					parser.name == "positionH" -> positionAxis = "x"
					parser.name == "positionV" -> positionAxis = "y"
					parser.namespace == DRAWING_NS && parser.name == "ln" -> {
						insideLine = true
						outlineWidth = parser.getAttributeValue(null, "w")
							?.toDoubleOrNull()
							?.div(9525.0)
							?.coerceIn(0.1, 12.0)
					}
					parser.namespace == DRAWING_NS && parser.name == "solidFill" -> {
						insideSolidFill = true
						solidFillColor = null
						solidFillLuminanceModulation = 100_000
						solidFillLuminanceOffset = 0
					}
					parser.namespace == DRAWING_NS && insideSolidFill &&
						parser.name == "lumMod" -> {
						solidFillLuminanceModulation =
							parser.getAttributeValue(null, "val")?.toIntOrNull()
								?.coerceIn(0, 100_000) ?: 100_000
					}
					parser.namespace == DRAWING_NS && insideSolidFill &&
						parser.name == "lumOff" -> {
						solidFillLuminanceOffset =
							parser.getAttributeValue(null, "val")?.toIntOrNull()
								?.coerceIn(0, 100_000) ?: 0
					}
					parser.name == "posOffset" -> {
						val offset = parser.nextText().toDoubleOrNull()?.div(9525.0)
						if (positionAxis == "x" && offset != null) left = offset
						if (positionAxis == "y" && offset != null) top = offset
						depth--
					}
					parser.name == "extent" -> {
						width = parser.getAttributeValue(null, "cx")
							?.toDoubleOrNull()
							?.div(9525.0)
						height = parser.getAttributeValue(null, "cy")
							?.toDoubleOrNull()
							?.div(9525.0)
					}
					parser.namespace == DRAWING_NS && parser.name == "xfrm" -> {
						rotationDegrees = parser.getAttributeValue(null, "rot")
							?.toDoubleOrNull()
							?.div(60_000.0)
					}
					parser.name == "prstGeom" -> {
						shape = parser.getAttributeValue(null, "prst")
					}
					parser.name == "blip" -> {
						relationId = parser.getAttributeValue(REL_NS, "embed")
					}
					parser.namespace == DRAWING_NS && insideSolidFill &&
						parser.name == "schemeClr" -> {
						solidFillColor = parser.getAttributeValue(null, "val")
							?.let(::resolveThemeColor)
					}
					parser.namespace == DRAWING_NS && insideSolidFill &&
						parser.name == "srgbClr" -> {
						solidFillColor = parseColor(parser.getAttributeValue(null, "val"))
					}
					parser.name == "p" && parser.namespace == WORD_NS -> {
						for (paragraph in parseParagraph()) {
							contentBlocks.add(paragraph)
						}
						depth--
					}
					parser.name == "tbl" && parser.namespace == WORD_NS -> {
						contentBlocks.addAll(parseNestedTableBlocks())
						depth--
					}
					parser.name == "t" && parser.namespace == DRAWING_NS -> {
						val text = keepText(readTextElement(parser.name))
						if (text.isNotEmpty()) {
							directRuns.add(DocxTextStyle().channelValue(text))
						}
						depth--
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (parser.namespace == DRAWING_NS && parser.name == "solidFill") {
					insideSolidFill = false
					val transformedColor = solidFillColor?.let {
						applyLuminanceTransform(
							it,
							solidFillLuminanceModulation,
							solidFillLuminanceOffset,
						)
					}
					if (insideLine) {
						outlineColor = transformedColor
					} else if (fillColor == null) {
						fillColor = transformedColor
					}
				}
				if (parser.namespace == DRAWING_NS && parser.name == "ln") {
					insideLine = false
				}
				depth--
			}
		}

		val boxWidth = width ?: 0.0
		val boxHeight = height ?: 0.0
		var backgroundBlock: Map<String, Any?>? = null
		if (contentBlocks.isEmpty() && (fillColor != null || outlineColor != null) &&
			boxWidth > 0 && boxHeight > 0 &&
			floatingBackgroundCount < DOCX_MAX_FLOATING_BACKGROUNDS
		) {
			floatingBackgroundCount++
			backgroundBlock = mapOf(
				"type" to "floatingBackground",
				"floatingLeft" to left,
				"floatingTop" to top,
				"floatingWidth" to boxWidth,
				"floatingHeight" to boxHeight,
				"floatingBackground" to fillColor,
				"floatingShape" to shape,
				"floatingOutlineColor" to outlineColor,
				"floatingOutlineWidth" to outlineWidth,
				"floatingRotation" to rotationDegrees,
			)
		}
		if (contentBlocks.isNotEmpty()) {
			val floatId = nextFloatingId++
			return contentBlocks.map { block ->
				block + mapOf(
					"floatingId" to floatId,
					"floatingLeft" to left,
					"floatingTop" to top,
					"floatingWidth" to boxWidth,
					"floatingHeight" to boxHeight,
					"floatingBackground" to fillColor,
					"floatingShape" to shape,
					"floatingOutlineColor" to outlineColor,
					"floatingOutlineWidth" to outlineWidth,
					"floatingRotation" to rotationDegrees,
				)
			}
		}
		val path = relationId?.let(relationships::get)
		if (path != null && path.startsWith("word/media/")) {
			val imageBlock = mutableMapOf<String, Any?>(
				"type" to "image",
				"imagePath" to path,
				"width" to width?.coerceIn(24.0, 1200.0),
				"height" to height?.coerceIn(24.0, 900.0),
			)
			if (parserPositionIsFloating) {
				imageBlock.putAll(
					mapOf(
						"floatingId" to nextFloatingId++,
						"floatingLeft" to left,
						"floatingTop" to top,
						"floatingWidth" to boxWidth,
						"floatingHeight" to boxHeight,
						"floatingBackground" to fillColor,
						"floatingShape" to shape,
						"floatingOutlineColor" to outlineColor,
						"floatingOutlineWidth" to outlineWidth,
						"floatingRotation" to rotationDegrees,
					),
				)
			}
			return if (backgroundBlock == null) {
				listOf(imageBlock)
			} else {
				listOf(backgroundBlock!!, imageBlock)
			}
		}
		if (backgroundBlock != null) return listOf(backgroundBlock!!)
		if (directRuns.isNotEmpty()) {
			return listOf(mapOf("type" to "paragraph", "runs" to directRuns))
		}
		return emptyList()
	}

	private fun parseNestedTableBlocks(): List<Map<String, Any?>> {
		val previousInsideTable = insideTable
		val previousTableId = activeTableId
		val previousColumnWidths = tableColumnWidths.toList()
		insideTable = true
		activeTableId = nextTableId++
		tableColumnWidths.clear()
		val rows = mutableListOf<Map<String, Any?>>()
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.END_TAG && parser.name == "tbl") {
					break
				}
				if (parser.eventType != XmlPullParser.START_TAG) continue
				when {
					parser.name == "gridCol" &&
						tableColumnWidths.size < DOCX_MAX_TABLE_COLUMNS -> {
						tableColumnWidths.add(
							parser.getAttributeValue(WORD_NS, "w")
								?.toDoubleOrNull()
								?.div(15.0)
								?: 0.0,
						)
					}
					parser.name == "tr" -> parseTableRow()?.let(rows::add)
				}
			}
		} finally {
			insideTable = previousInsideTable
			activeTableId = previousTableId
			tableColumnWidths.clear()
			tableColumnWidths.addAll(previousColumnWidths)
		}
		return rows
	}

	private fun parseLegacyPicture(): List<Map<String, Any?>> {
		val runs = mutableListOf<Map<String, Any?>>()
		var relationId: String? = null
		var shapeStyle: String? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"shape" -> shapeStyle = parser.getAttributeValue(null, "style")
					"imagedata" -> {
						relationId = parser.getAttributeValue(REL_NS, "id")
							?: parser.getAttributeValue(null, "id")
					}
					"p" -> {
						val paragraph = parseParagraph()
						val paragraphRuns = paragraph.flatMap {
							(it["runs"] as? List<*>)?.filterIsInstance<Map<String, Any?>>()
								.orEmpty()
						}
						if (paragraphRuns.isNotEmpty()) {
							if (runs.any { it["text"] is String }) {
								runs.add(DocxTextStyle().channelValue("\n"))
							}
							runs.addAll(paragraphRuns)
						}
						depth--
					}
					"drawing" -> {
						runs.addAll(parseDrawing().orEmpty())
						depth--
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				depth--
			}
		}
		val path = relationId?.let(relationships::get)
		if (path != null && path.startsWith("word/media/")) {
			val dimensions = parseVmlDimensions(shapeStyle)
			runs.add(
				0,
				mapOf(
					"imagePath" to path,
					"width" to dimensions.first,
					"height" to dimensions.second,
				),
			)
		}
		return runs
	}

	private fun parseAlternateContent(): List<Map<String, Any?>> {
		val choiceContent = mutableListOf<Map<String, Any?>>()
		val fallbackContent = mutableListOf<Map<String, Any?>>()
		var fallbackDepth: Int? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"Fallback" -> fallbackDepth = depth
					"drawing" -> {
						val target = if (fallbackDepth == null) choiceContent else fallbackContent
						target.addAll(parseDrawing().orEmpty())
						depth--
					}
					"pict" -> {
						val target = if (fallbackDepth == null) choiceContent else fallbackContent
						target.addAll(parseLegacyPicture())
						depth--
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (depth == fallbackDepth) fallbackDepth = null
				depth--
			}
		}
		return choiceContent.ifEmpty { fallbackContent }
	}

	private fun parseAlternateContentBlocks(): List<Map<String, Any?>> {
		val choiceContent = mutableListOf<Map<String, Any?>>()
		val fallbackContent = mutableListOf<Map<String, Any?>>()
		var fallbackDepth: Int? = null
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				depth++
				when (parser.name) {
					"Fallback" -> fallbackDepth = depth
					"drawing" -> {
						val target = if (fallbackDepth == null) choiceContent else fallbackContent
						target.addAll(parseDrawingBlocks())
						depth--
					}
					"pict" -> {
						val target = if (fallbackDepth == null) choiceContent else fallbackContent
						val runs = parseLegacyPicture()
						if (runs.isNotEmpty()) {
							target.add(mapOf("type" to "paragraph", "runs" to runs))
						}
						depth--
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				if (depth == fallbackDepth) fallbackDepth = null
				depth--
			}
		}
		return choiceContent.ifEmpty { fallbackContent }
	}

	private fun parseVmlDimensions(style: String?): Pair<Double?, Double?> {
		fun dimension(name: String): Double? {
			val raw = Regex(
				"""(?:^|;)\s*$name\s*:\s*([0-9.]+)\s*(pt|px|in|cm|mm)?""",
				RegexOption.IGNORE_CASE,
			)
				.find(style.orEmpty()) ?: return null
			val value = raw.groupValues[1].toDoubleOrNull() ?: return null
			return when (raw.groupValues[2].lowercase()) {
				"pt" -> value * 4 / 3
				"in" -> value * 96
				"cm" -> value * 96 / 2.54
				"mm" -> value * 96 / 25.4
				else -> value
			}.coerceIn(24.0, 1200.0)
		}
		return dimension("width") to dimension("height")
	}

	private fun readStyles() {
		if (archive.getEntry("word/styles.xml") == null) return
		val input = openEntry("word/styles.xml")
		val xml = createParser(input)
		try {
			while (xml.next() != XmlPullParser.END_DOCUMENT) {
				if (xml.eventType != XmlPullParser.START_TAG || xml.name != "style") continue
				val id = xml.getAttributeValue(WORD_NS, "styleId") ?: continue
				var name: String? = null
				var basedOn: String? = null
				var alignment: String? = null
				var rtl: Boolean? = null
				var bold: Boolean? = null
				var boldFont = false
				var italic: Boolean? = null
				var underline: Boolean? = null
				var strike: Boolean? = null
				var fontSize: Double? = null
				var color: Int? = null
				var highlight: Int? = null
				var outlineLevel: Int? = null
				var spaceBefore: Double? = null
				var spaceAfter: Double? = null
				var lineHeight: Double? = null
				var indentLeft: Double? = null
				var indentRight: Double? = null
				var hangingIndent: Double? = null
				while (xml.next() != XmlPullParser.END_DOCUMENT) {
					if (xml.eventType == XmlPullParser.END_TAG && xml.name == "style") break
					if (xml.eventType != XmlPullParser.START_TAG) continue
					val value = xml.getAttributeValue(WORD_NS, "val")
					when (xml.name) {
						"name" -> name = value
						"basedOn" -> basedOn = value
						"jc" -> alignment = value
						"bidi" -> rtl = value != "0" && value != "false"
						"b", "bCs" -> bold = value != "0" && value != "false"
						"i" -> italic = value != "0" && value != "false"
						"u" -> underline = value != "none"
						"strike", "dstrike" -> strike = value != "0" && value != "false"
						"sz" -> fontSize = value?.toDoubleOrNull()?.div(2.0)?.coerceIn(6.0, 96.0)
						"color" -> color = parseColor(value)
						"highlight" -> highlight = parseHighlight(value)
						"rFonts" -> boldFont = listOf("ascii", "hAnsi", "eastAsia", "cs")
							.any { attribute ->
								isBoldFontName(xml.getAttributeValue(WORD_NS, attribute))
							}
						"outlineLvl" -> outlineLevel = value?.toIntOrNull()?.coerceIn(0, 8)
						"spacing" -> {
							spaceBefore = xml.getAttributeValue(WORD_NS, "before")
								?.toDoubleOrNull()?.div(15.0)
							spaceAfter = xml.getAttributeValue(WORD_NS, "after")
								?.toDoubleOrNull()?.div(15.0)
							lineHeight = xml.getAttributeValue(WORD_NS, "line")
								?.toDoubleOrNull()?.div(240.0)?.coerceIn(0.8, 3.0)
						}
						"ind" -> {
							indentLeft = xml.getAttributeValue(WORD_NS, "left")
								?.toDoubleOrNull()?.div(15.0)
							indentRight = xml.getAttributeValue(WORD_NS, "right")
								?.toDoubleOrNull()?.div(15.0)
							hangingIndent = xml.getAttributeValue(WORD_NS, "hanging")
								?.toDoubleOrNull()?.div(15.0)
						}
					}
				}
				styles[id] = mapOf(
					"name" to (name ?: id),
					"basedOn" to basedOn,
					"alignment" to alignment,
					"rtl" to rtl,
					"bold" to (bold ?: boldFont),
					"italic" to italic,
					"underline" to underline,
					"strike" to strike,
					"fontSize" to fontSize,
					"color" to color,
					"highlight" to highlight,
					"outlineLevel" to outlineLevel,
					"spaceBefore" to spaceBefore,
					"spaceAfter" to spaceAfter,
					"lineHeight" to lineHeight,
					"indentLeft" to indentLeft,
					"indentRight" to indentRight,
					"hangingIndent" to hangingIndent,
				)
			}
		} finally {
			input.close()
		}
	}

	private fun readThemeColors() {
		val entryName = "word/theme/theme1.xml"
		if (archive.getEntry(entryName) == null) return
		val input = openEntry(entryName)
		val xml = createParser(input)
		var currentColorName: String? = null
		try {
			while (xml.next() != XmlPullParser.END_DOCUMENT) {
				if (xml.eventType == XmlPullParser.START_TAG) {
					if (xml.namespace == DRAWING_NS &&
						xml.name in THEME_COLOR_NAMES
					) {
						currentColorName = xml.name
					} else if (currentColorName != null &&
						xml.namespace == DRAWING_NS &&
						xml.name in setOf("srgbClr", "sysClr")
					) {
						val value = xml.getAttributeValue(
							null,
							if (xml.name == "sysClr") "lastClr" else "val",
						)
						parseColor(value)?.let { themeColors[currentColorName!!] = it }
					}
				} else if (xml.eventType == XmlPullParser.END_TAG &&
					xml.namespace == DRAWING_NS &&
					xml.name == currentColorName
				) {
					currentColorName = null
				}
			}
		} finally {
			input.close()
		}
	}

	private fun resolveThemeColor(name: String): Int? = when (name) {
		"tx1" -> themeColors["dk1"]
		"tx2" -> themeColors["dk2"]
		"bg1" -> themeColors["lt1"]
		"bg2" -> themeColors["lt2"]
		else -> themeColors[name]
	}

	private fun resolvedStyle(
		id: String?,
		seen: MutableSet<String> = mutableSetOf(),
	): Map<String, Any?>? {
		if (id == null || !seen.add(id)) return null
		val style = styles[id] ?: return null
		val resolved = resolvedStyle(style["basedOn"] as? String, seen)
			?.toMutableMap() ?: mutableMapOf()
		resolved.putAll(style.filterValues { it != null })
		return resolved
	}

	private fun readRelationships() {
		if (archive.getEntry("word/_rels/document.xml.rels") == null) return
		val input = openEntry("word/_rels/document.xml.rels")
		val xml = createParser(input)
		try {
			while (xml.next() != XmlPullParser.END_DOCUMENT) {
				if (xml.eventType != XmlPullParser.START_TAG || xml.name != "Relationship") continue
				if (xml.getAttributeValue(null, "TargetMode") == "External") {
					val id = xml.getAttributeValue(null, "Id") ?: continue
					val target = xml.getAttributeValue(null, "Target") ?: continue
					if (xml.getAttributeValue(null, "Type")?.endsWith("/hyperlink") == true) {
						relationships[id] = target
					}
					continue
				}
				val id = xml.getAttributeValue(null, "Id") ?: continue
				val target = xml.getAttributeValue(null, "Target") ?: continue
				relationships[id] = resolveTarget(target)
			}
		} finally {
			input.close()
		}
	}

	private fun readNumbering() {
		if (archive.getEntry("word/numbering.xml") == null) return
		val abstracts = mutableMapOf<Int, MutableMap<Int, DocxNumberingDefinition>>()
		val assignments = mutableMapOf<Int, Int>()
		val input = openEntry("word/numbering.xml")
		val xml = createParser(input)
		try {
			var abstractId: Int? = null
			var currentNumId: Int? = null
			var level: Int? = null
			var format: String? = null
			var marker: String? = null
			var leftIndent: Double? = null
			var hangingIndent: Double? = null
			while (xml.next() != XmlPullParser.END_DOCUMENT) {
				if (xml.eventType == XmlPullParser.START_TAG) {
					when (xml.name) {
						"abstractNum" -> abstractId = xml.getAttributeValue(WORD_NS, "abstractNumId")?.toIntOrNull()
						"lvl" -> level = xml.getAttributeValue(WORD_NS, "ilvl")?.toIntOrNull()
						"numFmt" -> format = xml.getAttributeValue(WORD_NS, "val")
						"lvlText" -> marker = xml.getAttributeValue(WORD_NS, "val")
						"ind" -> {
							leftIndent = xml.getAttributeValue(WORD_NS, "left")
								?.toDoubleOrNull()?.div(15.0)
							hangingIndent = xml.getAttributeValue(WORD_NS, "hanging")
								?.toDoubleOrNull()?.div(15.0)
						}
						"num" -> currentNumId =
							xml.getAttributeValue(WORD_NS, "numId")?.toIntOrNull()
						"abstractNumId" -> {
							val id = currentNumId
							val abstract = xml.getAttributeValue(WORD_NS, "val")?.toIntOrNull()
							if (id != null && abstract != null) assignments[id] = abstract
						}
					}
				} else if (xml.eventType == XmlPullParser.END_TAG) {
					if (xml.name == "lvl" && abstractId != null && level != null) {
						val fmt = format ?: "bullet"
						val rawMarker = marker ?: "•"
						abstracts.getOrPut(abstractId!!) { mutableMapOf() }[level!!] =
							DocxNumberingDefinition(fmt, when (fmt) {
								"bullet" -> when (rawMarker) {
									"o" -> "◦"
									"▪" -> "▪"
									"", "\uF0B7" -> "•"
									else -> "•"
								}
								"decimal" -> "1."
								"lowerLetter" -> "a."
								"upperLetter" -> "A."
								"lowerRoman" -> "i."
								"upperRoman" -> "I."
								else -> rawMarker
							}, leftIndent, hangingIndent)
						level = null
						format = null
						marker = null
						leftIndent = null
						hangingIndent = null
					} else if (xml.name == "num") {
						currentNumId = null
					} else if (xml.name == "abstractNum") {
						abstractId = null
					}
				}
			}
		} finally {
			input.close()
		}
		for ((numId, abstractId) in assignments) {
			for ((level, value) in abstracts[abstractId].orEmpty()) {
				numbering[numId to level] = value
			}
		}
	}

	fun readImage(path: String): ByteArray {
		ensureOpen()
		if (!path.startsWith("word/media/")) {
			throw DocxReaderException("INVALID_IMAGE", "The embedded image path is invalid")
		}
		val entry = archive.getEntry(path)
			?: throw DocxReaderException("IMAGE_MISSING", "The embedded image is unavailable")
		if (entry.size > DOCX_MAX_IMAGE_BYTES) {
			throw DocxReaderException("IMAGE_TOO_LARGE", "Embedded images larger than 16 MiB are not supported")
		}
		val input = openEntry(path)
		try {
			return input.readBytes()
		} finally {
			input.close()
		}
	}

	private fun openEntry(path: String): InputStream {
		val entry = archive.getEntry(path)
			?: throw DocxReaderException("INVALID_DOCUMENT", "Required DOCX data is missing")
		if (entry.isDirectory || entry.size > DOCX_MAX_ENTRY_BYTES) {
			throw DocxReaderException("ENTRY_TOO_LARGE", "A document section exceeds the 64 MiB limit")
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
					if (inflatedBytes + additional > DOCX_MAX_TOTAL_INFLATED_BYTES) {
						throw DocxReaderException("DOCUMENT_TOO_LARGE", "Document data exceeds the 256 MiB decompressed limit")
					}
					inflatedBytes += additional
					inflatedEntryBytes[path] = entryBytes
				}
				if (entryBytes > DOCX_MAX_ENTRY_BYTES ||
					(entry.size >= 0 && entryBytes > entry.size + 1_024)
				) {
					throw DocxReaderException("ENTRY_TOO_LARGE", "A document section exceeds the 64 MiB limit")
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

	private fun readTextElement(tag: String): String {
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

	private fun keepText(text: String): String {
		val remaining = (32 * 1024 * 1024 - retainedCharacters).coerceAtLeast(0)
		val length = minOf(text.length, DOCX_MAX_CELL_TEXT, remaining)
		retainedCharacters += length
		if (length < text.length) truncated = true
		return text.take(length)
	}

	private fun listMarker(numId: Int, level: Int): DocxNumberingDefinition? {
		val definition = numbering[numId to level] ?: return null
		val key = numId to level
		val value = (listCounters[key] ?: 0) + 1
		listCounters[key] = value
		listCounters.keys.removeAll { it.first == numId && it.second > level }
		val marker = when (definition.format) {
			"decimal" -> "$value."
			"lowerLetter" -> "${alphabeticNumber(value, lowercase = true)}."
			"upperLetter" -> "${alphabeticNumber(value, lowercase = false)}."
			"lowerRoman" -> "${romanNumber(value).lowercase()}."
			"upperRoman" -> "${romanNumber(value)}."
			else -> definition.marker
		}
		return definition.copy(marker = marker)
	}

	private fun alphabeticNumber(value: Int, lowercase: Boolean): String {
		var number = value.coerceAtLeast(1)
		val chars = StringBuilder()
		while (number > 0) {
			number--
			val base = if (lowercase) 'a' else 'A'
			chars.append((base.code + number % 26).toChar())
			number /= 26
		}
		return chars.reverse().toString()
	}

	private fun romanNumber(value: Int): String {
		var number = value.coerceIn(1, 3999)
		val symbols = listOf(
			1000 to "M", 900 to "CM", 500 to "D", 400 to "CD",
			100 to "C", 90 to "XC", 50 to "L", 40 to "XL",
			10 to "X", 9 to "IX", 5 to "V", 4 to "IV", 1 to "I",
		)
		return buildString {
			for ((amount, symbol) in symbols) {
				while (number >= amount) {
					append(symbol)
					number -= amount
				}
			}
		}
	}

	private fun skipElement() {
		val tag = parser.name
		var depth = 1
		while (depth > 0 && parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) depth++
			else if (parser.eventType == XmlPullParser.END_TAG) depth--
		}
	}

	private fun resolveTarget(target: String): String {
		val path = mutableListOf<String>()
		val pathTarget = target.substringBefore('#').substringBefore('?').replace('\\', '/')
		val combined = if (pathTarget.startsWith("/")) pathTarget.removePrefix("/")
		else "word/$pathTarget"
		for (rawPart in combined.split('/')) {
			val part = Uri.decode(rawPart)
			when (part) {
				"", "." -> Unit
				".." -> {
					if (path.isEmpty()) {
						throw DocxReaderException("INVALID_DOCUMENT", "A document relationship is invalid")
					}
					path.removeAt(path.lastIndex)
				}
				else -> {
					if (part.contains('/') || part.contains('\\')) {
						throw DocxReaderException("INVALID_DOCUMENT", "A document relationship is invalid")
					}
					path.add(part)
				}
			}
		}
		val result = path.joinToString("/")
		if (result.isBlank()) {
			throw DocxReaderException("INVALID_DOCUMENT", "A document relationship is invalid")
		}
		return result
	}

	private fun pageBreakBlock(): Map<String, Any?> = mapOf("type" to "pageBreak")

	private fun addParsedBlocks(
		output: MutableList<Map<String, Any?>>,
		parsed: List<Map<String, Any?>>,
	) {
		for (block in parsed) {
			if (blockCount >= DOCX_MAX_BLOCKS) {
				truncated = true
				break
			}
			output.add(block)
			blockCount++
			if (output.size >= DOCX_BATCH_BLOCKS) {
				deferredBlocks.addAll(parsed.dropWhile { it !== block }.drop(1))
				break
			}
		}
	}

	private fun placeholderBlock(text: String): Map<String, Any?> =
		mapOf("type" to "placeholder", "placeholder" to text)

	private fun ensureOpen() {
		if (closed) throw DocxReaderException("DOCUMENT_CLOSED", "The document is closed")
		if (!file.isFile) throw DocxReaderException("FILE_NOT_FOUND", "The document is unavailable")
	}

	fun close() {
		if (closed) return
		closed = true
		try {
			documentInput.close()
		} finally {
			archive.close()
		}
	}

	companion object {
		private const val WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
		private const val REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
		private const val DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
		private val THEME_COLOR_NAMES = setOf(
			"dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
			"accent4", "accent5", "accent6", "hlink", "folHlink",
		)
		private const val CONTENT_TYPE =
			"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

		fun open(file: File): DocxDocument {
			if (!file.isFile || !file.canRead() || file.length() <= 0L) {
				throw DocxReaderException("FILE_UNAVAILABLE", "The DOCX file is unavailable")
			}
			if (file.length() > DOCX_MAX_FILE_BYTES) {
				throw DocxReaderException("FILE_TOO_LARGE", "DOCX files larger than 1 GiB are not supported")
			}
			val archive = try {
				ZipFile(file)
			} catch (_: Exception) {
				throw DocxReaderException("INVALID_DOCUMENT", "This is not a readable DOCX document")
			}
			try {
				val entries = archive.entries()
				var count = 0
				while (entries.hasMoreElements() && count <= DOCX_MAX_ARCHIVE_ENTRIES) {
					entries.nextElement()
					count++
				}
				if (count > DOCX_MAX_ARCHIVE_ENTRIES) {
					throw DocxReaderException("TOO_MANY_ENTRIES", "The document contains too many ZIP entries")
				}
				return DocxDocument(archive, file, UUID.randomUUID().toString())
			} catch (error: Throwable) {
				archive.close()
				throw error
			}
		}
	}
}

private fun parseColor(value: String?): Int? {
	if (value.isNullOrBlank() || value == "auto") return null
	return value.toLongOrNull(16)?.takeIf { it <= 0xffffff }?.toInt()
}

private fun isBoldFontName(value: String?): Boolean =
	value?.contains(Regex("(black|heavy|extra\\s*bold)", RegexOption.IGNORE_CASE)) == true

private fun applyLuminanceTransform(color: Int, modulation: Int, offset: Int): Int {
	fun channel(shift: Int): Int {
		val source = (color shr shift) and 0xff
		return ((source * modulation + 255 * offset + 50_000) / 100_000)
			.coerceIn(0, 255)
	}
	return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
}

private fun parseHighlight(value: String?): Int? = when (value?.lowercase()) {
	"yellow" -> 0xffff00
	"green" -> 0x00ff00
	"cyan" -> 0x00ffff
	"magenta" -> 0xff00ff
	"blue" -> 0x0000ff
	"red" -> 0xff0000
	"darkblue" -> 0x000080
	"darkcyan" -> 0x008080
	"darkgreen" -> 0x008000
	"darkmagenta" -> 0x800080
	"darkred" -> 0x800000
	"darkyellow" -> 0x808000
	"darkgray" -> 0x808080
	"lightgray" -> 0xc0c0c0
	"black" -> 0x000000
	else -> null
}
