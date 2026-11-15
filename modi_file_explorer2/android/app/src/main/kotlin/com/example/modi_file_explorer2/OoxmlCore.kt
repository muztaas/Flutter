package com.example.modi_file_explorer2

import android.net.Uri
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.FilterInputStream
import java.io.InputStream
import java.util.LinkedHashSet
import java.util.zip.ZipFile
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal object OoxmlUnits {
	fun emuToPoints(value: Long): Double = value / 12_700.0
	fun emuToPixels(value: Long, dpi: Double = 96.0): Double = value / 914_400.0 * dpi
	fun twipsToPoints(value: Long): Double = value / 20.0
	fun halfPointsToPoints(value: Int): Double = value / 2.0
	fun pointsToPixels(value: Double, dpi: Double = 96.0): Double = value * dpi / 72.0
	fun angle60000ToDegrees(value: Long): Double = value / 60_000.0
	fun percent1000ToMultiplier(value: Int): Double = value / 100_000.0
}

internal data class OoxmlRelationship(
	val id: String,
	val type: String,
	val target: String,
	val external: Boolean,
)

internal data class OoxmlTheme(
	val colors: Map<String, Int>,
	val majorFonts: Map<String, String>,
	val minorFonts: Map<String, String>,
	val fills: List<String>,
	val lines: List<String>,
	val colorMap: Map<String, String>,
) {
	fun withColorMap(mapping: Map<String, String>): OoxmlTheme =
		copy(colorMap = colorMap + mapping)

	fun color(reference: String?, transforms: List<Pair<String, Int>> = emptyList()): Int? {
		if (reference.isNullOrBlank()) return null
		val name = colorMap[reference] ?: reference
		val base = colors[name.lowercase()] ?: OoxmlThemeParser.parsePresetColor(name)
			?: return null
		return OoxmlThemeParser.transformColor(base, transforms)
	}

	fun font(reference: String?): String? {
		if (reference.isNullOrBlank()) return null
		val key = reference.lowercase()
		return when (key) {
			"+mj-lt", "majorascii", "majorhansi" -> majorFonts["latin"]
			"+mn-lt", "minorascii", "minorhansi" -> minorFonts["latin"]
			"+mj-ea", "majoreastasia" -> majorFonts["eastAsia"] ?: majorFonts["latin"]
			"+mn-ea", "minoreastasia" -> minorFonts["eastAsia"] ?: minorFonts["latin"]
			"+mj-cs", "majorbidi" -> majorFonts["complex"] ?: majorFonts["latin"]
			"+mn-cs", "minorbidi" -> minorFonts["complex"] ?: minorFonts["latin"]
			else -> reference.takeUnless { it.startsWith("+") }
		}?.let(OoxmlSystemFonts::fallback)
	}
}

internal object OoxmlSystemFonts {
	private val monospaceNames = setOf("consolas", "courier new", "courier", "monaco", "menlo")
	private val serifNames = setOf("cambria", "times new roman", "georgia", "garamond", "palatino")

	fun fallback(name: String): String {
		val normalized = name.trim().lowercase()
		return when {
			normalized.startsWith("calibri") || normalized.startsWith("carlito") -> "Carlito"
			normalized.startsWith("cambria") || normalized.startsWith("caladea") -> "Caladea"
			normalized in monospaceNames || normalized.contains("mono") -> "monospace"
			normalized in serifNames || normalized.contains("serif") -> "serif"
			else -> "sans-serif"
		}
	}
}

internal object OoxmlImageSupport {
	fun unsupportedFormat(path: String): String? {
		val extension = path.substringAfterLast('.', "").lowercase()
		return when (extension) {
			"emf" -> "EMF images"
			"wmf" -> "WMF images"
			"tif", "tiff" -> "TIFF images"
			"svg" -> "SVG images without a PNG fallback"
			else -> null
		}
	}
}

internal class OoxmlNotShownReport(private val maxItems: Int = 24) {
	private val items = LinkedHashSet<String>()

	@Synchronized
	fun add(feature: String) {
		if (items.size < maxItems && feature.isNotBlank()) items.add(feature.take(96))
	}

	@Synchronized
	fun values(): List<String> = items.toList()
}

internal class OoxmlPackage(
	private val archive: ZipFile,
	private val maxEntryBytes: Long,
	private val maxTotalInflatedBytes: Long,
	private val maxFailures: Int = 16,
) {
	private var inflatedBytes = 0L
	private val inflatedEntryBytes = mutableMapOf<String, Long>()
	private val failureItems = LinkedHashSet<String>()

	@Synchronized
	fun failures(): List<String> = failureItems.toList()

	@Synchronized
	fun recordFailure(description: String) {
		if (failureItems.size < maxFailures) failureItems.add(description.take(120))
	}

	fun openPart(path: String): InputStream {
		val normalized = normalizePath(path)
		val entry = archive.getEntry(normalized)
			?: throw OoxmlPartException("Missing OOXML part: $normalized")
		if (entry.isDirectory || entry.size > maxEntryBytes) {
			throw OoxmlPartException("OOXML part exceeds its size limit: $normalized")
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

			private fun record(amount: Long) {
				entryBytes += amount
				val previous = inflatedEntryBytes[normalized] ?: 0L
				if (entryBytes > previous) {
					val additional = entryBytes - previous
					if (inflatedBytes + additional > maxTotalInflatedBytes ||
						entryBytes > maxEntryBytes
					) {
						throw OoxmlPartException("OOXML decompressed data exceeds its size limit")
					}
					inflatedBytes += additional
					inflatedEntryBytes[normalized] = entryBytes
				}
			}
		}
	}

	fun optionalPart(path: String): InputStream? = try {
		if (archive.getEntry(normalizePath(path)) == null) {
			recordFailure("Missing part: ${normalizePath(path)}")
			null
		} else {
			openPart(path)
		}
	} catch (error: Exception) {
		recordFailure("Could not read ${normalizePath(path)}: ${error.message ?: "invalid part"}")
		null
	}

	fun relationships(ownerPart: String): Map<String, OoxmlRelationship> {
		val path = relationshipPartPath(ownerPart)
		val input = optionalPart(path) ?: return emptyMap()
		val result = LinkedHashMap<String, OoxmlRelationship>()
		try {
			val parser = parser(input)
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG || parser.name != "Relationship") continue
				val id = parser.getAttributeValue(null, "Id") ?: continue
				val target = parser.getAttributeValue(null, "Target") ?: continue
				val external = parser.getAttributeValue(null, "TargetMode") == "External"
				val resolved = if (external) target else resolveTarget(ownerPart, target)
				result[id] = OoxmlRelationship(
					id = id,
					type = parser.getAttributeValue(null, "Type") ?: "",
					target = resolved,
					external = external,
				)
			}
		} catch (error: Exception) {
			recordFailure("Could not parse $path: ${error.message ?: "invalid XML"}")
			return emptyMap()
		} finally {
			input.close()
		}
		return result
	}

	fun contentType(part: String): String? {
		val input = optionalPart("[Content_Types].xml") ?: return null
		val normalizedPart = normalizePath(part).let { "/$it" }
		var extensionType: String? = null
		try {
			val parser = parser(input)
			while (parser.next() != XmlPullParser.END_DOCUMENT) {
				if (parser.eventType != XmlPullParser.START_TAG) continue
				when (parser.name) {
					"Override" -> {
						if (parser.getAttributeValue(null, "PartName") == normalizedPart) {
							return parser.getAttributeValue(null, "ContentType")
						}
					}
					"Default" -> {
						val extension = normalizedPart.substringAfterLast('.', "")
						if (parser.getAttributeValue(null, "Extension")
								.equals(extension, ignoreCase = true)
						) {
							extensionType = parser.getAttributeValue(null, "ContentType")
						}
					}
				}
			}
		} catch (error: Exception) {
			recordFailure("Could not parse [Content_Types].xml: ${error.message ?: "invalid XML"}")
		} finally {
			input.close()
		}
		return extensionType
	}

	private fun normalizePath(path: String): String {
		val parts = mutableListOf<String>()
		for (part in path.replace('\\', '/').split('/')) {
			when (part) {
				"", "." -> Unit
				".." -> {
					if (parts.isEmpty()) throw OoxmlPartException("OOXML target escapes the package")
					parts.removeAt(parts.lastIndex)
				}
				else -> {
					val decoded = Uri.decode(part)
					if (decoded.contains('/') || decoded.contains('\\')) {
						throw OoxmlPartException("Invalid OOXML path segment")
					}
					parts.add(decoded)
				}
			}
		}
		return parts.joinToString("/")
	}

	private fun resolveTarget(ownerPart: String, target: String): String {
		val decodedTarget = target.substringBefore('#').substringBefore('?')
		val base = if (decodedTarget.startsWith("/")) "" else ownerPart.substringBeforeLast('/', "")
		return normalizePath(if (base.isEmpty()) decodedTarget else "$base/$decodedTarget")
	}

	private fun relationshipPartPath(ownerPart: String): String {
		val normalized = normalizePath(ownerPart)
		val folder = normalized.substringBeforeLast('/', "")
		val fileName = normalized.substringAfterLast('/')
		return listOf(folder, "_rels", "$fileName.rels").filter { it.isNotEmpty() }.joinToString("/")
	}

	private fun parser(input: InputStream): XmlPullParser {
		val factory = XmlPullParserFactory.newInstance().apply {
			isNamespaceAware = true
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		}
		return factory.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(input, null)
		}
	}
}

internal class OoxmlPartException(message: String) : Exception(message)

internal object OoxmlThemeParser {
	fun parseColorMap(input: InputStream): Map<String, String> {
		val mapping = mutableMapOf<String, String>()
		val parser = XmlPullParserFactory.newInstance().apply {
			isNamespaceAware = true
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		}.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(input, null)
		}
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType != XmlPullParser.START_TAG || parser.name != "clrMap") continue
			for (slot in listOf(
				"bg1", "tx1", "bg2", "tx2", "accent1", "accent2", "accent3",
				"accent4", "accent5", "accent6", "hlink", "folHlink",
			)) {
				parser.getAttributeValue(null, slot)?.let { mapping[slot] = it }
			}
			break
		}
		return mapping
	}

	fun parse(input: InputStream): OoxmlTheme {
		val colors = mutableMapOf<String, Int>()
		val major = mutableMapOf<String, String>()
		val minor = mutableMapOf<String, String>()
		val fills = mutableListOf<String>()
		val lines = mutableListOf<String>()
		val colorMap = defaultColorMap().toMutableMap()
		val parser = XmlPullParserFactory.newInstance().apply {
			isNamespaceAware = true
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		}.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(input, null)
		}
		var colorSlot: String? = null
		var pendingColor: Int? = null
		var fontGroup: MutableMap<String, String>? = null
		var styleGroup: String? = null
		var styleDepth = 0
		val transforms = mutableListOf<Pair<String, Int>>()
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				when (parser.name) {
					"clrScheme" -> Unit
					"dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
					"accent4", "accent5", "accent6", "hlink", "folHlink" -> colorSlot = parser.name
					"majorFont" -> fontGroup = major
					"minorFont" -> fontGroup = minor
					"latin" -> fontGroup?.set("latin", parser.getAttributeValue(null, "typeface").orEmpty())
					"ea" -> fontGroup?.set("eastAsia", parser.getAttributeValue(null, "typeface").orEmpty())
					"cs" -> fontGroup?.set("complex", parser.getAttributeValue(null, "typeface").orEmpty())
					"clrMap" -> for (slot in listOf(
						"bg1", "tx1", "bg2", "tx2", "accent1", "accent2", "accent3",
						"accent4", "accent5", "accent6", "hlink", "folHlink",
					)) {
						parser.getAttributeValue(null, slot)?.let { colorMap[slot] = it }
					}
					"fillStyleLst" -> styleGroup = "fill"
					"lnStyleLst" -> styleGroup = "line"
					"solidFill", "gradFill", "pattFill", "noFill", "ln" -> {
						if (styleGroup != null && styleDepth < 128) {
							styleDepth++
							val target = if (styleGroup == "fill") fills else lines
							if (target.size < 64) target.add(parser.name)
						}
					}
					"srgbClr", "sysClr", "schemeClr", "prstClr" -> {
						val raw = when (parser.name) {
							"sysClr" -> parser.getAttributeValue(null, "lastClr")
							else -> parser.getAttributeValue(null, "val")
						}
						pendingColor = if (parser.name == "schemeClr") {
							colors[raw?.lowercase()]
						} else parseColorValue(parser.name, raw)
						if (styleGroup != null && styleDepth > 0) {
							val target = if (styleGroup == "fill") fills else lines
							if (target.size < 64) target.add("$styleGroup:${parser.name}:${raw.orEmpty()}")
						}
						transforms.clear()
					}
						"lumMod", "lumOff", "tint", "shade", "satMod", "hueMod", "alpha",
					"comp", "inv" -> {
						val amount = parser.getAttributeValue(null, "val")?.toIntOrNull() ?: 0
						transforms.add(parser.name to amount)
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				when (parser.name) {
					"srgbClr", "sysClr", "schemeClr", "prstClr" -> {
						val base = pendingColor
						val slot = colorSlot
						if (base != null && slot != null) {
							val transformed = transformColor(base, transforms)
							colors[slot.lowercase()] = transformed
							when (slot) {
								"hlink" -> colors["hyperlink"] = transformed
								"folHlink" -> colors["followedhyperlink"] = transformed
							}
						}
						pendingColor = null
						transforms.clear()
					}
					"dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
					"accent4", "accent5", "accent6", "hlink", "folHlink" -> colorSlot = null
					"majorFont", "minorFont" -> fontGroup = null
					"fillStyleLst", "lnStyleLst" -> {
						styleGroup = null
						styleDepth = 0
					}
					"solidFill", "gradFill", "pattFill", "noFill", "ln" -> styleDepth--
				}
			}
		}
		return OoxmlTheme(colors, major, minor, fills, lines, colorMap)
	}

	fun parsePresetColor(value: String): Int? = presetColors[value.lowercase()]

	fun transformColor(color: Int, transforms: List<Pair<String, Int>>): Int {
		var red = ((color shr 16) and 0xff) / 255.0
		var green = ((color shr 8) and 0xff) / 255.0
		var blue = (color and 0xff) / 255.0
		var alpha = 1.0
		for ((kind, rawAmount) in transforms) {
			val amount = rawAmount.coerceIn(0, 100_000) / 100_000.0
			when (kind) {
				"lumMod", "lumOff", "tint", "shade", "satMod", "hueMod", "comp", "inv" -> {
					val hsl = rgbToHsl(red, green, blue)
					var hue = hsl[0]
					var saturation = hsl[1]
					var luminance = hsl[2]
					when (kind) {
						"lumMod" -> luminance *= amount
						"lumOff" -> luminance += amount
						"tint" -> luminance += (1.0 - luminance) * amount
						"shade" -> luminance *= amount
						"satMod" -> saturation *= amount
						"hueMod" -> hue = (hue * rawAmount / 100_000.0) % 360.0
						"comp" -> hue = (hue + 180.0) % 360.0
						"inv" -> {
							red = 1.0 - red
							green = 1.0 - green
							blue = 1.0 - blue
						}
					}
					if (kind != "inv") {
						val rgb = hslToRgb(hue, saturation.coerceIn(0.0, 1.0), luminance.coerceIn(0.0, 1.0))
						red = rgb[0]
						green = rgb[1]
						blue = rgb[2]
					}
				}
				"alpha" -> alpha *= amount
			}
		}
		val a = (alpha.coerceIn(0.0, 1.0) * 255).roundToInt()
		return (a shl 24) or
			(red.coerceIn(0.0, 1.0) * 255).roundToInt().shl(16) or
			(green.coerceIn(0.0, 1.0) * 255).roundToInt().shl(8) or
			(blue.coerceIn(0.0, 1.0) * 255).roundToInt()
	}

	private fun parseColorValue(kind: String, value: String?): Int? {
		if (value == null) return null
		if (kind == "sysClr") return value.toLongOrNull(16)?.toInt()?.takeIf { it <= 0xffffff }
		return value.toLongOrNull(16)?.toInt()?.takeIf { it in 0..0xffffff }
			?: parsePresetColor(value)
	}

	private fun rgbToHsl(red: Double, green: Double, blue: Double): DoubleArray {
		val maxValue = max(red, max(green, blue))
		val minValue = min(red, min(green, blue))
		val delta = maxValue - minValue
		var hue = 0.0
		val luminance = (maxValue + minValue) / 2.0
		var saturation = 0.0
		if (delta != 0.0) {
			saturation = delta / (1.0 - kotlin.math.abs(2.0 * luminance - 1.0))
			hue = when (maxValue) {
				red -> 60.0 * (((green - blue) / delta) % 6.0)
				green -> 60.0 * ((blue - red) / delta + 2.0)
				else -> 60.0 * ((red - green) / delta + 4.0)
			}
			if (hue < 0) hue += 360.0
		}
		return doubleArrayOf(hue, saturation, luminance)
	}

	private fun hslToRgb(hue: Double, saturation: Double, luminance: Double): DoubleArray {
		val chroma = (1.0 - kotlin.math.abs(2.0 * luminance - 1.0)) * saturation
		val section = hue / 60.0
		val x = chroma * (1.0 - kotlin.math.abs(section % 2.0 - 1.0))
		val base = when (section.toInt().coerceIn(0, 5)) {
			0 -> doubleArrayOf(chroma, x, 0.0)
			1 -> doubleArrayOf(x, chroma, 0.0)
			2 -> doubleArrayOf(0.0, chroma, x)
			3 -> doubleArrayOf(0.0, x, chroma)
			4 -> doubleArrayOf(x, 0.0, chroma)
			else -> doubleArrayOf(chroma, 0.0, x)
		}
		val offset = luminance - chroma / 2.0
		return DoubleArray(3) { (base[it] + offset).coerceIn(0.0, 1.0) }
	}

	private fun defaultColorMap() = mapOf(
		"bg1" to "lt1", "tx1" to "dk1", "bg2" to "lt2", "tx2" to "dk2",
		"hlink" to "hlink", "folHlink" to "folHlink",
	)

	private val presetColors = mapOf(
		"black" to 0x000000, "white" to 0xffffff, "red" to 0xff0000,
		"green" to 0x008000, "blue" to 0x0000ff, "yellow" to 0xffff00,
		"cyan" to 0x00ffff, "magenta" to 0xff00ff, "gray" to 0x808080,
		"grey" to 0x808080, "darkblue" to 0x00008b, "darkred" to 0x8b0000,
		"darkgreen" to 0x006400, "orange" to 0xffa500, "purple" to 0x800080,
		"pink" to 0xffc0cb, "brown" to 0xa52a2a, "navy" to 0x000080,
		"teal" to 0x008080, "silver" to 0xc0c0c0, "lime" to 0x00ff00,
		"maroon" to 0x800000, "olive" to 0x808000, "aqua" to 0x00ffff,
		"fuchsia" to 0xff00ff, "indigo" to 0x4b0082, "coral" to 0xff7f50,
		"gold" to 0xffd700, "salmon" to 0xfa8072, "violet" to 0xee82ee,
		"turquoise" to 0x40e0d0, "darkgray" to 0xa9a9a9, "lightgray" to 0xd3d3d3,
	)
}
