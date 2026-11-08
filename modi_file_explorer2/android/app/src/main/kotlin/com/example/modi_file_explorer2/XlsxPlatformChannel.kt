package com.example.modi_file_explorer2

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipFile

private const val XLSX_MAX_FILE_BYTES = 1L shl 30
private const val XLSX_MAX_ENTRY_BYTES = 64L * 1024 * 1024
private const val XLSX_MAX_TOTAL_INFLATED_BYTES = 256L * 1024 * 1024
private const val XLSX_MAX_ARCHIVE_ENTRIES = 20_000
private const val XLSX_MAX_ROWS = 200_000
private const val XLSX_MAX_COLUMNS = 256
private const val XLSX_MAX_STORED_CELLS = 2_000_000
private const val XLSX_MAX_CELL_CHARACTERS = 65_536
private const val XLSX_MAX_TOTAL_CELL_CHARACTERS = 32 * 1024 * 1024
private const val XLSX_MAX_SHARED_STRINGS = 1_000_000
private const val XLSX_BATCH_ROWS = 128

private class XlsxReaderException(
	val code: String,
	message: String,
) : Exception(message)

internal class XlsxPlatformChannel(
	messenger: BinaryMessenger,
) {
	private val methods = MethodChannel(messenger, "modi_file_explorer2/xlsx")
	private val executor = Executors.newSingleThreadExecutor()
	private val mainHandler = Handler(Looper.getMainLooper())
	private val workbooks = ConcurrentHashMap<String, XlsxWorkbook>()

	init {
		methods.setMethodCallHandler(::handle)
	}

	private fun handle(call: MethodCall, result: MethodChannel.Result) {
		val arguments = call.arguments as? Map<*, *>
		when (call.method) {
			"openWorkbook" -> {
				val path = arguments?.get("path") as? String
				if (path.isNullOrBlank()) {
					result.error("INVALID_ARGUMENT", "An XLSX file path is required", null)
					return
				}
				runWorker(result) {
					val workbook = XlsxWorkbook.open(File(path))
					workbooks[workbook.id] = workbook
					workbook.metadata()
				}
			}
			"openSheet" -> runWorkbookMethod(arguments, result) { workbook ->
				val sheetId = arguments?.get("sheetId") as? String
					?: throw XlsxReaderException("INVALID_ARGUMENT", "A worksheet is required")
				workbook.openSheet(sheetId)
			}
			"readNextRows" -> runWorkbookMethod(arguments, result) { workbook ->
				workbook.readNextRows()
			}
			"readRow" -> runWorkbookMethod(arguments, result) { workbook ->
				val index = (arguments?.get("index") as? Number)?.toInt()
					?: throw XlsxReaderException("INVALID_ARGUMENT", "A row index is required")
				workbook.readRow(index)
			}
			"closeWorkbook" -> {
				val id = arguments?.get("id") as? String
				if (id.isNullOrBlank()) {
					result.success(null)
					return
				}
				executor.execute {
					workbooks.remove(id)?.close()
					mainHandler.post { result.success(null) }
				}
			}
			else -> result.notImplemented()
		}
	}

	private fun runWorkbookMethod(
		arguments: Map<*, *>?,
		result: MethodChannel.Result,
		block: (XlsxWorkbook) -> Any?,
	) {
		val id = arguments?.get("id") as? String
		if (id.isNullOrBlank()) {
			result.error("INVALID_ARGUMENT", "A workbook identifier is required", null)
			return
		}
		runWorker(result) {
			val workbook = workbooks[id]
				?: throw XlsxReaderException("WORKBOOK_CLOSED", "The workbook is closed")
			block(workbook)
		}
	}

	private fun runWorker(result: MethodChannel.Result, block: () -> Any?) {
		executor.execute {
			try {
				val value = block()
				mainHandler.post { result.success(value) }
			} catch (error: Throwable) {
				val readerError = error as? XlsxReaderException
				mainHandler.post {
					result.error(
						readerError?.code ?: "XLSX_READ_FAILED",
						readerError?.message ?: error.message ?: "Could not read the XLSX workbook",
						null,
					)
				}
			}
		}
	}
}

private data class XlsxSheet(
	val id: String,
	val name: String,
	val path: String,
	val defaultRowHeight: Double,
)

private data class CompactXlsxRow(
	val rowNumber: Int,
	val columns: IntArray,
	val values: Array<String>,
	val height: Double?,
	val truncated: Boolean,
) {
	fun channelValue(): Map<String, Any?> = mapOf(
		"rowNumber" to rowNumber,
		"columns" to columns.toList(),
		"values" to values.toList(),
		"height" to height,
		"truncated" to truncated,
	)
}

private class XlsxWorkbook private constructor(
	private val archive: ZipFile,
	private val file: File,
	val id: String,
	private var sheets: List<XlsxSheet>,
	private var sharedStrings: List<String>,
	private var numberFormats: List<Int>,
	private var customFormats: Map<Int, String>,
	private var date1904: Boolean,
) {
	private var inflatedBytes = 0L
	private val inflatedEntryBytes = mutableMapOf<String, Long>()
	private var totalCellCharacters = 0
	private var storedCellCount = 0
	private var sheetReader: XlsxSheetReader? = null
	private var closed = false

	fun metadata(): Map<String, Any?> = mapOf(
		"id" to id,
		"sheets" to sheets.map {
			mapOf(
				"id" to it.id,
				"name" to it.name,
				"defaultRowHeight" to it.defaultRowHeight,
			)
		},
	)

	fun openSheet(sheetId: String): Map<String, Any?> {
		ensureOpen()
		val sheet = sheets.firstOrNull { it.id == sheetId }
			?: throw XlsxReaderException("SHEET_UNAVAILABLE", "The selected worksheet is unavailable")
		sheetReader?.close()
		totalCellCharacters = 0
		storedCellCount = 0
		sheetReader = XlsxSheetReader(
			this,
			sheet,
			archive,
			sharedStrings,
			numberFormats,
			customFormats,
			date1904,
		)
		return sheetReader!!.readNextRows()
	}

	fun readNextRows(): Map<String, Any?> {
		ensureOpen()
		return (sheetReader
			?: throw XlsxReaderException("SHEET_UNAVAILABLE", "Open a worksheet first"))
			.readNextRows()
	}

	fun readRow(index: Int): Map<String, Any?> {
		ensureOpen()
		return (sheetReader
			?: throw XlsxReaderException("SHEET_UNAVAILABLE", "Open a worksheet first"))
			.readRow(index)
	}

	internal fun openEntry(path: String): InputStream {
		val entry = archive.getEntry(path)
			?: throw XlsxReaderException("INVALID_WORKBOOK", "Required workbook data is missing")
		if (entry.isDirectory) {
			throw XlsxReaderException("INVALID_WORKBOOK", "A workbook data entry is invalid")
		}
		if (entry.size > XLSX_MAX_ENTRY_BYTES) {
			throw XlsxReaderException("ENTRY_TOO_LARGE", "A workbook section exceeds the 64 MiB limit")
		}
		var entryBytes = 0L
		return EntryLimitInputStream(archive.getInputStream(entry), entry.size) { amount ->
			entryBytes += amount
			val previouslyCounted = inflatedEntryBytes[path] ?: 0L
			if (entryBytes > previouslyCounted) {
				val additionalBytes = entryBytes - previouslyCounted
				if (inflatedBytes + additionalBytes > XLSX_MAX_TOTAL_INFLATED_BYTES) {
					throw XlsxReaderException(
						"WORKBOOK_TOO_LARGE",
						"Workbook data exceeds the 256 MiB decompressed limit",
					)
				}
				inflatedBytes += additionalBytes
				inflatedEntryBytes[path] = entryBytes
			}
		}
	}

	internal fun keepCellText(text: String): Pair<String, Boolean> {
		val available = (XLSX_MAX_TOTAL_CELL_CHARACTERS - totalCellCharacters).coerceAtLeast(0)
		val limit = minOf(XLSX_MAX_CELL_CHARACTERS, available)
		val truncated = text.length > limit
		val value = if (truncated) text.substring(0, limit) else text
		totalCellCharacters += value.length
		storedCellCount++
		if (storedCellCount > XLSX_MAX_STORED_CELLS) {
			throw XlsxReaderException("CELL_LIMIT", "Worksheet reached the 2,000,000-cell limit")
		}
		return value to truncated
	}

	private fun ensureOpen() {
		if (closed) throw XlsxReaderException("WORKBOOK_CLOSED", "The workbook is closed")
		if (!file.isFile) throw XlsxReaderException("FILE_NOT_FOUND", "The workbook file is unavailable")
	}

	fun close() {
		if (closed) return
		closed = true
		sheetReader?.close()
		archive.close()
	}

	companion object {
		fun open(file: File): XlsxWorkbook {
			if (!file.isFile || !file.canRead()) {
				throw XlsxReaderException("FILE_UNAVAILABLE", "The workbook file is unavailable")
			}
			if (file.length() <= 0L) {
				throw XlsxReaderException("INVALID_WORKBOOK", "The workbook is empty")
			}
			if (file.length() > XLSX_MAX_FILE_BYTES) {
				throw XlsxReaderException("FILE_TOO_LARGE", "XLSX files larger than 1 GiB are not supported")
			}
			val archive = try {
				ZipFile(file)
			} catch (error: Exception) {
				throw XlsxReaderException("INVALID_WORKBOOK", "This is not a readable XLSX workbook")
			}
			try {
				val entries = archive.entries()
				var entryCount = 0
				while (entries.hasMoreElements() && entryCount <= XLSX_MAX_ARCHIVE_ENTRIES) {
					entries.nextElement()
					entryCount++
				}
				if (entryCount > XLSX_MAX_ARCHIVE_ENTRIES) {
					throw XlsxReaderException("TOO_MANY_ENTRIES", "The workbook contains too many ZIP entries")
				}
				val workbook = XlsxWorkbook(
					archive = archive,
					file = file,
					id = UUID.randomUUID().toString(),
					sheets = emptyList(),
					sharedStrings = emptyList(),
					numberFormats = emptyList(),
					customFormats = emptyMap(),
					date1904 = false,
				)
				return workbook.readMetadata()
			} catch (error: Throwable) {
				archive.close()
				throw error
			}
		}
	}

	private fun readMetadata(): XlsxWorkbook {
		val contentType = readWorkbookContentType()
		if (contentType != XLSX_CONTENT_TYPE) {
			throw XlsxReaderException(
				"UNSUPPORTED_WORKBOOK",
				"Only standard .xlsx workbooks are supported; macro-enabled and template workbooks are not handled",
			)
		}
		val relationships = readRelationships()
		val workbookInfo = readWorkbook(relationships)
		val styles = readStyles()
		sheets = workbookInfo.first
		date1904 = workbookInfo.second
		sharedStrings = readSharedStrings()
		numberFormats = styles.first
		customFormats = styles.second
		return this
	}

	private fun readWorkbookContentType(): String {
		val input = openEntry("[Content_Types].xml")
		val parser = xmlParser(input)
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG &&
					parser.name == "Override" &&
					parser.getAttributeValue(null, "PartName") == "/xl/workbook.xml"
				) {
					return parser.getAttributeValue(null, "ContentType") ?: ""
				}
			}
		} finally {
			input.close()
		}
		throw XlsxReaderException("INVALID_WORKBOOK", "The XLSX workbook declaration is missing")
	}

	private fun readRelationships(): Map<String, String> {
		val result = mutableMapOf<String, String>()
		val input = openEntry("xl/_rels/workbook.xml.rels")
		val parser = xmlParser(input)
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG || parser.name != "Relationship") {
					continue
				}
				if (parser.getAttributeValue(null, "TargetMode") == "External") continue
				val id = parser.getAttributeValue(null, "Id") ?: continue
				val target = parser.getAttributeValue(null, "Target") ?: continue
				result[id] = resolveWorkbookTarget(target)
			}
		} finally {
			input.close()
		}
		return result
	}

	private fun resolveWorkbookTarget(target: String): String {
		val pieces = mutableListOf<String>()
		val normalizedTarget = target.replace('\\', '/').removePrefix("/")
		val combined = if (normalizedTarget.startsWith("xl/")) {
			normalizedTarget
		} else {
			"xl/$normalizedTarget"
		}
		for (piece in combined.split('/')) {
			when (piece) {
				"", "." -> Unit
				".." -> {
					if (pieces.isEmpty()) {
						throw XlsxReaderException("INVALID_WORKBOOK", "A workbook relationship is invalid")
					}
					pieces.removeAt(pieces.lastIndex)
				}
				else -> pieces.add(piece)
			}
		}
		val path = pieces.joinToString("/")
		if (!path.startsWith("xl/")) {
			throw XlsxReaderException("INVALID_WORKBOOK", "A workbook relationship is invalid")
		}
		return path
	}

	private fun readWorkbook(relationships: Map<String, String>): Pair<List<XlsxSheet>, Boolean> {
		val input = openEntry("xl/workbook.xml")
		val parser = xmlParser(input)
		val result = mutableListOf<XlsxSheet>()
		var date1904 = false
		var defaultHeight = 15.0
		try {
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG) continue
				when (parser.name) {
					"workbookPr" -> date1904 =
						parser.getAttributeValue(null, "date1904") == "1" ||
							parser.getAttributeValue(null, "date1904") == "true"
					"sheetFormatPr" -> {
						defaultHeight = parser.getAttributeValue(null, "defaultRowHeight")
							?.toDoubleOrNull()
							?.coerceIn(8.0, 100.0)
							?: defaultHeight
					}
					"sheet" -> {
						val state = parser.getAttributeValue(null, "state")
						if (state == "hidden" || state == "veryHidden") continue
						val name = parser.getAttributeValue(null, "name") ?: continue
						val id = parser.getAttributeValue(
							"http://schemas.openxmlformats.org/officeDocument/2006/relationships",
							"id",
						) ?: continue
						val path = relationships[id] ?: continue
						result.add(XlsxSheet(id, name, path, defaultHeight))
					}
				}
			}
		} finally {
			input.close()
		}
		return result to date1904
	}

	private fun readSharedStrings(): List<String> {
		val entry = archive.getEntry("xl/sharedStrings.xml") ?: return emptyList()
		if (entry.size > XLSX_MAX_ENTRY_BYTES) {
			throw XlsxReaderException("ENTRY_TOO_LARGE", "The shared-string table exceeds the 64 MiB limit")
		}
		val strings = ArrayList<String>()
		val input = openEntry(entry.name)
		val parser = xmlParser(input)
		try {
			var inString = false
			val value = StringBuilder()
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG && parser.name == "si") {
					inString = true
					value.setLength(0)
				} else if (parser.eventType == XmlPullParser.START_TAG &&
					parser.name == "t" &&
					inString
				) {
					value.append(readText(parser, "t"))
				} else if (parser.eventType == XmlPullParser.END_TAG &&
					parser.name == "si" &&
					inString
				) {
					if (strings.size >= XLSX_MAX_SHARED_STRINGS) {
						throw XlsxReaderException(
							"SHARED_STRING_LIMIT",
							"The shared-string table exceeds the 1,000,000-item limit",
						)
					}
					strings.add(value.toString())
					inString = false
				}
			}
		} finally {
			input.close()
		}
		return strings
	}

	private fun readStyles(): Pair<List<Int>, Map<Int, String>> {
		if (archive.getEntry("xl/styles.xml") == null) return emptyList<Int>() to emptyMap()
		val custom = mutableMapOf<Int, String>()
		val formats = mutableListOf<Int>()
		val input = openEntry("xl/styles.xml")
		val parser = xmlParser(input)
		try {
			var inCellFormats = false
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType == XmlPullParser.START_TAG) {
					when (parser.name) {
						"numFmt" -> {
							val id = parser.getAttributeValue(null, "numFmtId")?.toIntOrNull()
							val format = parser.getAttributeValue(null, "formatCode")
							if (id != null && format != null) custom[id] = format
						}
						"cellXfs" -> inCellFormats = true
						"xf" -> if (inCellFormats) {
							formats.add(
								parser.getAttributeValue(null, "numFmtId")?.toIntOrNull() ?: 0,
							)
						}
					}
				} else if (parser.eventType == XmlPullParser.END_TAG &&
					parser.name == "cellXfs"
				) {
					inCellFormats = false
				}
			}
		} finally {
			input.close()
		}
		return formats to custom
	}

	private fun xmlParser(input: InputStream): XmlPullParser {
		val factory = XmlPullParserFactory.newInstance()
		factory.isNamespaceAware = true
		factory.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		val parser = factory.newPullParser()
		parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		parser.setInput(input, null)
		return parser
	}

	private fun readText(parser: XmlPullParser, tag: String): String {
		val value = StringBuilder()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.TEXT ||
				parser.eventType == XmlPullParser.CDSECT
			) {
				value.append(parser.text)
			} else if (parser.eventType == XmlPullParser.END_TAG && parser.name == tag) {
				break
			}
		}
		return value.toString()
	}

	private fun isDateFormat(formatId: Int, format: String?): Boolean {
		if (formatId in setOf(14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47)) {
			return true
		}
		if (format.isNullOrBlank()) return false
		val stripped = format.lowercase()
			.replace(Regex("\"[^\"]*\""), "")
			.replace(Regex("\\\\."), "")
			.replace(Regex("\\[[^]]*]"), "")
		return stripped.contains('y') || stripped.contains('d') ||
			stripped.contains('h') || stripped.contains('s') ||
			(stripped.contains('m') && (stripped.contains(':') || stripped.contains('/')))
	}

	private fun formatDate(value: Double, formatId: Int, format: String?): String {
		val base = if (date1904) LocalDateTime.of(1904, 1, 1, 0, 0)
		else LocalDateTime.of(1899, 12, 30, 0, 0)
		val wholeDays = kotlin.math.floor(value).toLong().coerceIn(-2_000_000, 2_000_000)
		val fractionalNanos = ((value - kotlin.math.floor(value)) * 86_400_000_000_000.0)
			.toLong()
			.coerceIn(0, 86_399_999_999_999)
		val date = base.plusDays(wholeDays).plusNanos(fractionalNanos)
		val pattern = when (formatId) {
			14 -> "M/d/yy"
			15 -> "d-MMM-yy"
			16 -> "d-MMM"
			17 -> "MMM-yy"
			18 -> "h:mm a"
			19 -> "h:mm:ss a"
			20 -> "H:mm"
			21 -> "H:mm:ss"
			22 -> "M/d/yy H:mm"
			45 -> "m:ss"
			46 -> "[h]:mm"
			47 -> "mm:ss"
			else -> datePattern(format.orEmpty())
		}
		return try {
			date.format(DateTimeFormatter.ofPattern(pattern, Locale.US))
		} catch (_: IllegalArgumentException) {
			date.format(DateTimeFormatter.ofPattern("M/d/yy", Locale.US))
		}
	}

	private fun datePattern(source: String): String {
		val pattern = source.substringBefore(';')
			.replace(Regex("\"([^\"]*)\"")) { "'${it.groupValues[1].replace("'", "''")}'" }
			.replace(Regex("\\\\(.)")) { "'${it.groupValues[1]}'" }
			.replace(Regex("\\[[^]]*]"), "")
			.replace("AM/PM", "a", ignoreCase = true)
		val out = StringBuilder()
		var index = 0
		while (index < pattern.length) {
			val char = pattern[index]
			if (char.isLetter()) {
				var end = index + 1
				while (end < pattern.length && pattern[end].lowercaseChar() == char.lowercaseChar()) {
					end++
				}
				val lower = char.lowercaseChar()
				val token = when (lower) {
					'y' -> "y".repeat((end - index).coerceAtMost(4))
					'd' -> "d".repeat((end - index).coerceAtMost(4))
					'h' -> "H".repeat((end - index).coerceAtMost(2))
					's' -> "s".repeat((end - index).coerceAtMost(2))
					'm' -> {
						val previous = pattern.substring(0, index).lastOrNull()
						val next = pattern.substring(end).firstOrNull()
						val time = previous == ':' || next == ':'
						if (time) "m".repeat((end - index).coerceAtMost(2))
						else "M".repeat((end - index).coerceAtMost(4))
					}
					'a' -> "a"
					else -> char.toString().replace("'", "''")
				}
				out.append(token)
				index = end
			} else {
				out.append(char)
				index++
			}
		}
		return out.toString()
	}

	private fun formatNumber(value: Double, format: String?): String {
		if (format.isNullOrBlank() || format == "General") {
			return if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
		}
		val section = format.substringBefore(';')
			.replace(Regex("\\[(?!\\$)[^]]*]"), "")
			.replace(Regex("_.|\\*."), "")
		val first = section.indexOfFirst { it in "0#?" }
		if (first < 0) return value.toString()
		val last = section.indexOfLast { it in "0#?.,%" }
		if (last < first) return value.toString()
		val numericPattern = section.substring(first, last + 1)
			.replace('?', '#')
		val prefix = formatLiteral(section.substring(0, first))
		val suffix = formatLiteral(section.substring(last + 1))
		return try {
			val symbols = DecimalFormatSymbols(Locale.US)
			val formatter = DecimalFormat(numericPattern, symbols)
			formatter.isParseBigDecimal = false
			prefix + formatter.format(value) + suffix
		} catch (_: IllegalArgumentException) {
			value.toString()
		}
	}

	private fun formatLiteral(value: String): String {
		val result = StringBuilder()
		var index = 0
		while (index < value.length) {
			when (value[index]) {
				'"' -> {
					val end = value.indexOf('"', index + 1)
					if (end < 0) {
						result.append(value.substring(index + 1))
						break
					}
					result.append(value.substring(index + 1, end))
					index = end + 1
				}
				'\\' -> {
					if (index + 1 < value.length) result.append(value[index + 1])
					index += 2
				}
				'[' -> {
					val end = value.indexOf(']', index + 1)
					if (end < 0) index++ else {
						val token = value.substring(index + 1, end)
						if (token.startsWith("$")) {
							val currency = token.substring(1).substringBefore('-')
							result.append(currencySymbol(currency))
						}
						index = end + 1
					}
				}
				else -> {
					result.append(value[index])
					index++
				}
			}
		}
		return result.toString()
	}

	private fun currencySymbol(code: String): String = when (code.uppercase()) {
		"EUR" -> "€"
		"GBP" -> "£"
		"JPY", "CNY" -> "¥"
		else -> "$"
	}

}

private const val XLSX_CONTENT_TYPE =
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"

private class XlsxSheetReader(
	private val workbook: XlsxWorkbook,
	private val sheet: XlsxSheet,
	archive: ZipFile,
	private val sharedStrings: List<String>,
	private val numberFormats: List<Int>,
	private val customFormats: Map<Int, String>,
	private val date1904: Boolean,
) {
	private val sheetInput = run {
		val entry = archive.getEntry(sheet.path)
			?: throw XlsxReaderException("INVALID_WORKBOOK", "The selected worksheet is missing")
		if (entry.size > XLSX_MAX_ENTRY_BYTES) {
			throw XlsxReaderException("ENTRY_TOO_LARGE", "The worksheet exceeds the 64 MiB limit")
		}
		workbook.openEntry(sheet.path)
	}
	private val parser = run {
		val factory = XmlPullParserFactory.newInstance().apply {
			isNamespaceAware = true
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		}
		factory.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(sheetInput, null)
		}
	}
	private val rows = ArrayList<CompactXlsxRow>()
	private val widths = mutableMapOf<Int, Double>()
	private val hiddenColumns = mutableSetOf<Int>()
	private val omittedFeatures = linkedSetOf<String>()
	private var visibleColumns = emptyList<Int>()
	private var columnCount = 1
	private var defaultRowHeight = sheet.defaultRowHeight
	private var nextImplicitRow = 1
	private var ended = false
	private var truncated = false
	private var closed = false

	init {
		parseColumnsAndSheetFeatures()
	}

	fun readNextRows(): Map<String, Any?> {
		if (closed) throw XlsxReaderException("WORKBOOK_CLOSED", "The worksheet is closed")
		val start = rows.size
		var added = 0
		while (!ended && !truncated && added < XLSX_BATCH_ROWS) {
			val event = parser.next()
			if (event == XmlPullParser.END_DOCUMENT) {
				ended = true
				break
			}
			if (event == XmlPullParser.START_TAG) {
				when (parser.name) {
					"row" -> {
						val row = parseRow()
						if (row != null) {
							if (rows.size >= XLSX_MAX_ROWS) {
								truncated = true
							} else {
								rows.add(row)
								added++
							}
						}
					}
					"conditionalFormatting" -> omittedFeatures.add("conditional formatting")
					"dataValidations" -> omittedFeatures.add("data validation")
					"drawing" -> {
						omittedFeatures.add("charts, images and shapes")
					}
					"legacyDrawing" -> omittedFeatures.add("comments")
					"pivotTableDefinition" -> omittedFeatures.add("pivot tables")
				}
			}
		}
		if (rows.size >= XLSX_MAX_ROWS && !ended) truncated = true
		return progressMap(start)
	}

	fun readRow(index: Int): Map<String, Any?> {
		if (index < 0 || index >= rows.size) {
			throw XlsxReaderException("ROW_UNAVAILABLE", "The requested worksheet row is not indexed")
		}
		return rows[index].channelValue()
	}

	private fun parseColumnsAndSheetFeatures() {
		// Worksheet column definitions precede sheetData; parsing them here lets the
		// first visible batch already use file-provided widths and hidden columns.
		var event = parser.eventType
		while (event != XmlPullParser.END_DOCUMENT) {
			event = parser.next()
			if (event != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"col" -> {
					val first = (parser.getAttributeValue(null, "min")?.toIntOrNull() ?: 1) - 1
					val last = (parser.getAttributeValue(null, "max")?.toIntOrNull() ?: first + 1) - 1
					val hidden = parser.getAttributeValue(null, "hidden") == "1" ||
						parser.getAttributeValue(null, "hidden") == "true"
					val width = parser.getAttributeValue(null, "width")?.toDoubleOrNull()
					for (column in first.coerceAtLeast(0)..last.coerceAtMost(XLSX_MAX_COLUMNS - 1)) {
						if (hidden) hiddenColumns.add(column) else if (width != null) {
							widths[column] = (width * 7.0 + 5.0).coerceIn(32.0, 480.0)
						}
					}
				}
				"dimension" -> {
					val lastCell = parser.getAttributeValue(null, "ref")
						?.substringAfterLast(':')
					if (lastCell != null) {
						columnCount = maxOf(columnCount, columnIndexFromReference(lastCell) + 1)
					}
				}
				"sheetFormatPr" -> {
					defaultRowHeight = parser.getAttributeValue(null, "defaultRowHeight")
						?.toDoubleOrNull()
						?.coerceIn(8.0, 100.0)
						?: defaultRowHeight
				}
				"sheetData" -> {
					updateVisibleColumns()
					return
				}
				"conditionalFormatting" -> omittedFeatures.add("conditional formatting")
				"dataValidations" -> omittedFeatures.add("data validation")
				"drawing" -> omittedFeatures.add("charts, images and shapes")
				"legacyDrawing" -> omittedFeatures.add("comments")
				"pivotTableDefinition" -> omittedFeatures.add("pivot tables")
			}
		}
		ended = true
	}

	private fun parseRow(): CompactXlsxRow? {
		val rowNumber = parser.getAttributeValue(null, "r")?.toIntOrNull() ?: nextImplicitRow
		nextImplicitRow = rowNumber + 1
		val hidden = parser.getAttributeValue(null, "hidden") == "1" ||
			parser.getAttributeValue(null, "hidden") == "true"
		val height = parser.getAttributeValue(null, "ht")?.toDoubleOrNull()?.coerceIn(8.0, 400.0)
		val cells = java.util.TreeMap<Int, String>()
		var cellCount = 0
		var rowTruncated = false
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "row") break
			if (parser.eventType != XmlPullParser.START_TAG || parser.name != "c") continue
			val cell = parseCell()
			if (cell != null) {
				cellCount++
				if (cell.first in 0 until XLSX_MAX_COLUMNS &&
					cell.first !in hiddenColumns &&
					cell.second.isNotEmpty()
				) {
					cells[cell.first] = cell.second
					rowTruncated = rowTruncated || cell.third
					columnCount = maxOf(columnCount, cell.first + 1)
				} else if (cell.first >= XLSX_MAX_COLUMNS) {
					rowTruncated = true
				}
			}
		}
		if (hidden) return null
		val columns = IntArray(cells.size)
		val values = arrayOfNulls<String>(cells.size)
		cells.entries.forEachIndexed { index, entry ->
			columns[index] = entry.key
			values[index] = entry.value
		}
		if (cellCount > XLSX_MAX_COLUMNS) rowTruncated = true
		return CompactXlsxRow(rowNumber, columns, Array(cells.size) { values[it] ?: "" }, height, rowTruncated)
	}

	private fun parseCell(): Triple<Int, String, Boolean>? {
		val reference = parser.getAttributeValue(null, "r")
		val column = reference?.let(::columnIndexFromReference) ?: 0
		val type = parser.getAttributeValue(null, "t")
		val style = parser.getAttributeValue(null, "s")?.toIntOrNull() ?: 0
		var rawValue: String? = null
		var inlineText: String? = null
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == "c") break
			if (parser.eventType != XmlPullParser.START_TAG) continue
			when (parser.name) {
				"v" -> rawValue = readElementText("v")
				"t" -> inlineText = (inlineText ?: "") + readElementText("t")
			}
		}
		val value = when (type) {
			"s" -> rawValue?.toIntOrNull()?.let(sharedStrings::getOrNull) ?: ""
			"inlineStr" -> inlineText.orEmpty()
			else -> rawValue?.let { formatValue(it, type, style) }.orEmpty()
		}
		if (value.isEmpty()) return null
		val (bounded, wasTruncated) = workbook.keepCellText(value)
		return Triple(column, bounded, wasTruncated)
	}

	private fun updateVisibleColumns() {
		visibleColumns = (0 until columnCount.coerceAtMost(XLSX_MAX_COLUMNS))
			.filterNot(hiddenColumns::contains)
	}

	private fun readElementText(tag: String): String {
		val value = StringBuilder()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.TEXT ||
				parser.eventType == XmlPullParser.CDSECT
			) {
				value.append(parser.text)
			} else if (parser.eventType == XmlPullParser.END_TAG && parser.name == tag) {
				break
			}
		}
		return value.toString()
	}

	private fun formatValue(value: String, type: String?, style: Int): String {
		if (type == "e" || type == "str") return value
		if (type == "b") return if (value == "1") "TRUE" else "FALSE"
		val formatId = numberFormats.getOrNull(style) ?: 0
		val format = customFormats[formatId] ?: when (formatId) {
			3 -> "#,##0"
			4 -> "#,##0.00"
			5 -> "$#,##0"
			6 -> "$#,##0;($#,##0)"
			7 -> "$#,##0.00"
			8 -> "$#,##0.00;($#,##0.00)"
			9 -> "0%"
			10 -> "0.00%"
			else -> null
		}
		if (format == "@") return value
		if (isDateFormat(formatId, format)) return formatDate(value.toDoubleOrNull() ?: return value, formatId, format, date1904)
		val number = value.toDoubleOrNull() ?: return value
		return formatNumber(number, format)
	}

	private fun progressMap(start: Int): Map<String, Any?> {
		updateVisibleColumns()
		val batch = rows.subList(start.coerceAtMost(rows.size), rows.size)
		return mapOf(
			"startRowIndex" to start,
			"rows" to batch.map(CompactXlsxRow::channelValue),
			"rowCount" to rows.size,
			"complete" to ended,
			"truncated" to (truncated || columnCount > XLSX_MAX_COLUMNS),
			"columnCount" to columnCount,
			"visibleColumns" to visibleColumns,
			"columnWidths" to widths.mapKeys { it.key.toString() },
			"omittedFeatures" to omittedFeatures.toList(),
			"defaultRowHeight" to defaultRowHeight,
		)
	}

	fun close() {
		if (closed) return
		closed = true
		try {
			sheetInput.close()
		} catch (_: IOException) {
			// Closing an abandoned worksheet must not prevent the workbook from closing.
		}
	}
}

private class EntryLimitInputStream(
	input: InputStream,
	private val declaredSize: Long,
	private val onBytes: (Long) -> Unit,
) : FilterInputStream(input) {
	private var readBytes = 0L

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
		readBytes += count
		if (readBytes > XLSX_MAX_ENTRY_BYTES ||
			(declaredSize >= 0 && readBytes > declaredSize + 1_024)
		) {
			throw XlsxReaderException("ENTRY_TOO_LARGE", "A workbook section exceeds the 64 MiB limit")
		}
		onBytes(count)
	}
}

private fun columnIndexFromReference(reference: String): Int {
	var column = 0
	for (character in reference) {
		if (character !in 'A'..'Z' && character !in 'a'..'z') break
		column = column * 26 + character.uppercaseChar().code - 'A'.code + 1
		if (column > Int.MAX_VALUE / 26) return XLSX_MAX_COLUMNS
	}
	return (column - 1).coerceAtLeast(0)
}

private fun isDateFormat(formatId: Int, format: String?): Boolean {
	if (formatId in setOf(14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47)) return true
	if (format.isNullOrBlank()) return false
	val stripped = format.lowercase()
		.replace(Regex("\"[^\"]*\""), "")
		.replace(Regex("\\\\."), "")
		.replace(Regex("\\[[^]]*]"), "")
	return stripped.contains('y') || stripped.contains('d') ||
		stripped.contains('h') || stripped.contains('s') ||
		(stripped.contains('m') && (stripped.contains(':') || stripped.contains('/')))
}

private fun formatDate(value: Double, formatId: Int, format: String?, date1904: Boolean): String {
	val base = if (date1904) LocalDateTime.of(1904, 1, 1, 0, 0)
	else LocalDateTime.of(1899, 12, 30, 0, 0)
	val wholeDays = kotlin.math.floor(value).toLong().coerceIn(-2_000_000, 2_000_000)
	val nanos = ((value - kotlin.math.floor(value)) * 86_400_000_000_000.0)
		.toLong()
		.coerceIn(0, 86_399_999_999_999)
	val date = base.plusDays(wholeDays).plusNanos(nanos)
	val pattern = when (formatId) {
		14 -> "M/d/yy"
		15 -> "d-MMM-yy"
		16 -> "d-MMM"
		17 -> "MMM-yy"
		18 -> "h:mm a"
		19 -> "h:mm:ss a"
		20 -> "H:mm"
		21 -> "H:mm:ss"
		22 -> "M/d/yy H:mm"
		45 -> "m:ss"
		46 -> "[h]:mm"
		47 -> "mm:ss"
		else -> xlsxDatePattern(format.orEmpty())
	}
	return try {
		date.format(DateTimeFormatter.ofPattern(pattern, Locale.US))
	} catch (_: IllegalArgumentException) {
		date.format(DateTimeFormatter.ofPattern("M/d/yy", Locale.US))
	}
}

private fun xlsxDatePattern(source: String): String {
	val pattern = source.substringBefore(';')
		.replace(Regex("\"([^\"]*)\"")) { "'${it.groupValues[1].replace("'", "''")}'" }
		.replace(Regex("\\\\(.)")) { "'${it.groupValues[1]}'" }
		.replace(Regex("\\[[^]]*]"), "")
		.replace("AM/PM", "a", ignoreCase = true)
	val output = StringBuilder()
	var index = 0
	while (index < pattern.length) {
		val character = pattern[index]
		if (character.isLetter()) {
			var end = index + 1
			while (end < pattern.length &&
				pattern[end].lowercaseChar() == character.lowercaseChar()
			) {
				end++
			}
			val count = (end - index).coerceAtMost(4)
			val token = when (character.lowercaseChar()) {
				'y' -> "y".repeat(count)
				'd' -> "d".repeat(count)
				'h' -> "H".repeat(count.coerceAtMost(2))
				's' -> "s".repeat(count.coerceAtMost(2))
				'm' -> {
					val isTime = pattern.substring(0, index).lastOrNull() == ':' ||
						pattern.substring(end).firstOrNull() == ':'
					(if (isTime) "m" else "M").repeat(count.coerceAtMost(2))
				}
				'a' -> "a"
				else -> character.toString().replace("'", "''")
			}
			output.append(token)
			index = end
		} else {
			output.append(character)
			index++
		}
	}
	return output.toString()
}

private fun formatNumber(value: Double, format: String?): String {
	if (format.isNullOrBlank() || format == "General") {
		return if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
	}
	val section = format.substringBefore(';')
		.replace(Regex("\\[(?!\\$)[^]]*]"), "")
		.replace(Regex("_.|\\*."), "")
	val first = section.indexOfFirst { it in "0#?" }
	if (first < 0) return value.toString()
	val last = section.indexOfLast { it in "0#?.,%" }
	if (last < first) return value.toString()
	val pattern = section.substring(first, last + 1).replace('?', '#')
	val prefix = xlsxLiteral(section.substring(0, first))
	val suffix = xlsxLiteral(section.substring(last + 1))
	return try {
		prefix + DecimalFormat(pattern, DecimalFormatSymbols(Locale.US)).format(value) + suffix
	} catch (_: IllegalArgumentException) {
		value.toString()
	}
}

private fun xlsxLiteral(value: String): String {
	val output = StringBuilder()
	var index = 0
	while (index < value.length) {
		when (value[index]) {
			'"' -> {
				val end = value.indexOf('"', index + 1)
				if (end < 0) {
					output.append(value.substring(index + 1))
					break
				}
				output.append(value.substring(index + 1, end))
				index = end + 1
			}
			'\\' -> {
				if (index + 1 < value.length) output.append(value[index + 1])
				index += 2
			}
			'[' -> {
				val end = value.indexOf(']', index + 1)
				if (end < 0) index++ else {
					val token = value.substring(index + 1, end)
					if (token.startsWith("$")) {
						val currency = token.substring(1).substringBefore('-')
						output.append(
							when (currency.uppercase()) {
								"EUR", "€" -> "€"
								"GBP", "£" -> "£"
								"JPY", "CNY", "¥" -> "¥"
								else -> "$"
							},
						)
					}
					index = end + 1
				}
			}
			else -> {
				output.append(value[index])
				index++
			}
		}
	}
	return output.toString()
}
