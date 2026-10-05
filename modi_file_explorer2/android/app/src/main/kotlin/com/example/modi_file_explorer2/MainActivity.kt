package com.example.modi_file_explorer2

import android.content.pm.PackageManager
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
	private val channelName = "modi_file_explorer2/installed_apps"
	private val storageChannelName = "modi_file_explorer2/storage_volumes"
	private val openWithChannelName = "modi_file_explorer2/open_with"

	private fun categoryMimeType(category: String): String = when (category) {
		"Text" -> "text/plain"
		"Image" -> "image/*"
		"Audio" -> "audio/*"
		"Video" -> "video/*"
		else -> "*/*"
	}

	private fun queryActivities(intent: Intent) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
		packageManager.queryIntentActivities(
			intent,
			PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
		)
	} else {
		@Suppress("DEPRECATION")
		packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
	}

	private fun viewIntent(mimeType: String, uri: Uri): Intent = Intent(Intent.ACTION_VIEW).apply {
		setDataAndType(uri, mimeType)
		addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				if (call.method != "listInstalledApps") {
					result.notImplemented()
					return@setMethodCallHandler
				}

				try {
					val apps = packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
						.map { info ->
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
						.sortedBy { it["name"].toString().lowercase() }
					result.success(apps)
				} catch (error: Exception) {
					result.error("APPS_UNAVAILABLE", error.message, null)
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, openWithChannelName)
			.setMethodCallHandler { call, result ->
				try {
					when (call.method) {
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
							val appMimeType = MimeTypeMap.getSingleton()
								.getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
							val mimeTypes = linkedSetOf(categoryMimeType(category), appMimeType)
							val apps = linkedMapOf<String, Map<String, String>>()
							for (mimeType in mimeTypes) {
								val intent = viewIntent(mimeType, uri)
								for (resolveInfo in queryActivities(intent)) {
									val packageName = resolveInfo.activityInfo?.packageName ?: continue
									if (packageName == this.packageName) continue
									val label = resolveInfo.loadLabel(packageManager)?.toString()?.takeIf { it.isNotBlank() } ?: packageName
									if (!apps.containsKey(packageName)) {
										apps[packageName] = mapOf(
											"name" to label,
											"packageName" to packageName,
											"mimeType" to mimeType,
										)
									}
								}
							}
							result.success(apps.values.sortedBy { it["name"]?.lowercase() })
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
						"openWithApp" -> {
							val path = call.argument<String>("path")
							val category = call.argument<String>("category")
							val targetPackage = call.argument<String>("packageName")
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
							val intent = viewIntent(mimeType, uri).apply {
								setPackage(targetPackage)
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
	}
}
