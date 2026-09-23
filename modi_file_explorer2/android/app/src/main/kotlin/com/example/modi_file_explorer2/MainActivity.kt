package com.example.modi_file_explorer2

import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
	private val channelName = "modi_file_explorer2/installed_apps"
	private val storageChannelName = "modi_file_explorer2/storage_volumes"

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
