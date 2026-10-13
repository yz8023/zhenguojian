package com.duanju.duanju_app

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.os.Build
import android.os.Bundle
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceInfo") {
                    val mode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    val television = mode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                    val version = packageManager.getPackageInfo(packageName, 0).versionName
                    result.success(mapOf("television" to television, "version" to version))
                } else if (call.method == "systemProxy") {
                    val connection = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val proxy = connection.defaultProxy
                    val host = proxy?.host.orEmpty()
                    val address = if (host.isNotEmpty() && (proxy?.port ?: 0) > 0) {
                        "http://${if (host.contains(':')) "[$host]" else host}:${proxy!!.port}"
                    } else ""
                    result.success(mapOf("http" to address, "https" to address,
                        "bypass" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
                        "pac" to (proxy != null && proxy.pacFileUrl != Uri.EMPTY)))
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/updater")
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.success("missing")
                        return@setMethodCallHandler
                    }
                    result.success(installApk(path))
                } else if (call.method == "openInstallSettings") {
                    result.success(openInstallSettings())
                } else {
                    result.notImplemented()
                }
            }
    }

    /** 是否已被系统授予「安装未知应用」权限。 */
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    /** 打开本应用的「安装未知应用」设置页。 */
    private fun openInstallSettings(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:$packageName"))
            } else {
                Intent(android.provider.Settings.ACTION_SECURITY_SETTINGS)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 通过 FileProvider 拉起系统安装界面。 */
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists()) return "missing"
        if (!canInstallPackages()) return "no_permission"
        return try {
            val uri = FileProvider.getUriForFile(
                this, "$packageName.updateprovider", file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            "ok"
        } catch (e: Exception) {
            "failed:${e.javaClass.simpleName}"
        }
    }
}
