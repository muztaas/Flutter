package com.example.modi_file_explorer2

import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.InputStream

private const val CHART_MAX_SERIES = 16
private const val CHART_MAX_POINTS = 256
private const val CHART_MAX_TITLE_CHARACTERS = 256

internal object OoxmlChartParser {
	fun parse(input: InputStream, theme: OoxmlTheme): Map<String, Any?> {
		val factory = XmlPullParserFactory.newInstance().apply {
			isNamespaceAware = true
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
		}
		val parser = factory.newPullParser().apply {
			setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
			setInput(input, null)
		}
		var type: String? = null
		var title = StringBuilder()
		var inTitle = false
		var dataLabels = false
		var legend = false
		val categories = mutableListOf<String>()
		val series = mutableListOf<MutableMap<String, Any?>>()
		var currentSeries: MutableMap<String, Any?>? = null
		var currentName = StringBuilder()
		var currentCategories = mutableListOf<String>()
		var currentValues = mutableListOf<Double>()
		var cacheMode: String? = null
		var cacheTarget: String? = null
		var pointIndex: Int? = null
		var color: Int? = null
		var inSeriesFill = false
		var stackDepth = 0
		var truncated = false
		val chartFamilies = linkedSetOf<String>()

		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.START_TAG) {
				when (parser.name) {
					"barChart" -> {
						type = if (parser.getAttributeValue(null, "barDir") == "bar") {
							"bar"
						} else {
							"column"
						}
						chartFamilies.add(type.substringBefore('-'))
					}
					"lineChart" -> {
						type = "line"
						chartFamilies.add("line")
					}
					"pieChart" -> {
						type = "pie"
						chartFamilies.add("pie")
					}
					"doughnutChart" -> {
						type = "doughnut"
						chartFamilies.add("doughnut")
					}
					"areaChart" -> {
						type = "area"
						chartFamilies.add("area")
					}
					"scatterChart" -> {
						type = "scatter"
						chartFamilies.add("scatter")
					}
					"ser" -> if (series.size < CHART_MAX_SERIES) {
							currentSeries = linkedMapOf()
							currentName = StringBuilder()
							currentCategories = mutableListOf()
							currentValues = mutableListOf()
							color = null
						} else {
							truncated = true
						}
					"grouping" -> {
						val grouping = parser.getAttributeValue(null, "val")
						if (grouping in setOf("stacked", "percentStacked")) {
							type = "${type ?: "column"}-$grouping"
						}
					}
					"title" -> if (currentSeries == null) inTitle = true
					"legend" -> legend = true
					"dLbls", "dLbl" -> dataLabels = true
					"strRef", "numRef", "strLit", "numLit" -> {
						if (currentSeries != null && stackDepth < 6) {
							cacheMode = parser.name
							stackDepth++
						}
					}
					"tx" -> if (currentSeries != null) cacheTarget = "name"
					"cat" -> if (currentSeries != null) cacheTarget = "categories"
					"val", "yVal" -> if (currentSeries != null) cacheTarget = "values"
					"xVal" -> if (currentSeries != null) cacheTarget = "categories"
					"f" -> if (cacheMode != null) skipText(parser, "f")
					"idx" -> {
						pointIndex = parser.getAttributeValue(null, "val")?.toIntOrNull()
						if (pointIndex != null && pointIndex!! >= CHART_MAX_POINTS) {
							truncated = true
						}
					}
					"v" -> {
						val text = parser.nextText()
						val index = pointIndex
						if (cacheMode != null && cacheTarget == "name") {
							if (currentName.isEmpty()) currentName.append(text.take(CHART_MAX_TITLE_CHARACTERS))
						} else if (cacheMode != null && index != null &&
							index in 0 until CHART_MAX_POINTS
						) {
							if (cacheTarget == "values" || cacheMode.startsWith("num") &&
								cacheTarget != "categories"
							) {
								val number = text.toDoubleOrNull()
								if (number != null) {
									while (currentValues.size <= index && currentValues.size < CHART_MAX_POINTS) {
										currentValues.add(Double.NaN)
									}
									if (index < currentValues.size) currentValues[index] = number
								}
							} else {
								while (currentCategories.size <= index &&
									currentCategories.size < CHART_MAX_POINTS
								) {
									currentCategories.add("")
								}
								if (index < currentCategories.size) currentCategories[index] = text
							}
						}
					}
					"t" -> if (inTitle || currentSeries != null) {
						val text = parser.nextText()
						if (inTitle && title.length < CHART_MAX_TITLE_CHARACTERS) {
							title.append(text.take(CHART_MAX_TITLE_CHARACTERS - title.length))
						} else if (currentSeries != null) {
							currentName.append(text.take(CHART_MAX_TITLE_CHARACTERS))
						}
					}
					"solidFill" -> if (currentSeries != null) inSeriesFill = true
					"srgbClr" -> if (inSeriesFill) {
						color = parser.getAttributeValue(null, "val")?.toLongOrNull(16)
							?.toInt()?.let { 0xFF000000.toInt() or it }
					}
					"schemeClr" -> if (inSeriesFill) {
						color = theme.color(parser.getAttributeValue(null, "val"))
					}
				}
			} else if (parser.eventType == XmlPullParser.END_TAG) {
				when (parser.name) {
					"strRef", "numRef", "strLit", "numLit" -> if (cacheMode == parser.name) {
						cacheMode = null
						stackDepth = (stackDepth - 1).coerceAtLeast(0)
					}
					"tx", "cat", "val", "xVal", "yVal" -> cacheTarget = null
					"solidFill" -> inSeriesFill = false
					"ser" -> {
						val current = currentSeries
						if (current != null) {
							current["name"] = currentName.toString().ifBlank { "Series ${series.size + 1}" }
							current["categories"] = currentCategories
							current["values"] = currentValues.filter { it.isFinite() }
							current["color"] = color
							series.add(current)
						}
						currentSeries = null
					}
					"title" -> inTitle = false
				}
			}
		}
		val firstSeriesCategories = series.firstOrNull()?.get("categories") as? List<*>
		if (firstSeriesCategories != null) {
			categories.addAll(firstSeriesCategories.filterIsInstance<String>())
		}
		series.forEach { item ->
			val values = item["values"] as? List<Double> ?: emptyList()
			if (categories.size < values.size) {
				while (categories.size < values.size) categories.add("${categories.size + 1}")
			}
		}
		val supported = chartFamilies.size <= 1 && type?.substringBefore('-') in
			setOf("column", "bar", "line", "pie", "doughnut", "area", "scatter")
		return mapOf(
			"type" to (type ?: "unsupported"),
			"title" to title.toString().trim(),
			"categories" to categories.take(CHART_MAX_POINTS),
			"series" to series.map { it.toMap() },
			"legend" to legend,
			"dataLabels" to dataLabels,
			"supported" to supported,
			"truncated" to truncated,
		)
	}

	private fun skipText(parser: XmlPullParser, tag: String) {
		while (parser.next() != XmlPullParser.END_DOCUMENT) {
			if (parser.eventType == XmlPullParser.END_TAG && parser.name == tag) return
		}
	}
}
