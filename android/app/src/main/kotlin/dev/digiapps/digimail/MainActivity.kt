package dev.digiapps.digimail

import android.content.Intent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null

    // Il link «mailto:» con cui un'altra app ha aperto DiGiMail, finché Dart non lo ritira.
    private var mailtoInAttesa: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mailtoInAttesa = leggiMailto(intent) ?: mailtoInAttesa
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.digiapps.digimail/window")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            if (call.method == "secure") {
                val on = call.arguments as? Boolean ?: false
                runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else if (call.method == "mailtoIniziale") {
                val m = mailtoInAttesa
                mailtoInAttesa = null
                result.success(m)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val m = leggiMailto(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("mailto", m) else mailtoInAttesa = m
    }

    /** Destinatari, oggetto e testo di un «mailto:» o di un invio da un'altra app (null se non lo è). */
    private fun leggiMailto(i: Intent?): Map<String, Any?>? {
        if (i == null) return null
        val uri = i.data
        val ok = i.action == Intent.ACTION_SENDTO || i.action == Intent.ACTION_VIEW
        if (!ok || uri == null || uri.scheme != "mailto") return null
        i.data = null // letto una volta sola: una rotazione non riapre Scrivi
        return mapOf(
            "uri" to uri.toString(),
            "to" to (i.getStringArrayExtra(Intent.EXTRA_EMAIL)?.toList() ?: emptyList<String>()),
            "cc" to (i.getStringArrayExtra(Intent.EXTRA_CC)?.toList() ?: emptyList<String>()),
            "bcc" to (i.getStringArrayExtra(Intent.EXTRA_BCC)?.toList() ?: emptyList<String>()),
            "subject" to i.getStringExtra(Intent.EXTRA_SUBJECT),
            "body" to i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
        )
    }
}
