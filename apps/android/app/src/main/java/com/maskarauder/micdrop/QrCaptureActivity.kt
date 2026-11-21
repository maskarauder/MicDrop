// SPDX-License-Identifier: MPL-2.0
package com.maskarauder.micdrop

import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowInsets
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import com.journeyapps.barcodescanner.CaptureManager
import com.journeyapps.barcodescanner.DecoratedBarcodeView

// Edge-to-edge QR scanner hosting ZXing's CaptureManager on a ComponentActivity
// so Android 12–16 render the camera preview full-bleed while keeping the scan
// prompt clear of system bars and display cutouts.
class QrCaptureActivity : ComponentActivity() {
    private lateinit var capture: CaptureManager
    private lateinit var barcodeScannerView: DecoratedBarcodeView

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContentView(com.google.zxing.client.android.R.layout.zxing_capture)
        barcodeScannerView = findViewById(com.google.zxing.client.android.R.id.zxing_barcode_scanner)
        val margin = (16 * resources.displayMetrics.density).toInt()
        barcodeScannerView.statusView?.gravity = Gravity.CENTER_HORIZONTAL
        barcodeScannerView.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            barcodeScannerView.statusView?.setPadding(
                margin + bars.left,
                margin,
                margin + bars.right,
                margin + bars.bottom,
            )
            insets
        }
        barcodeScannerView.requestApplyInsets()
        capture = CaptureManager(this, barcodeScannerView)
        capture.initializeFromIntent(intent, savedInstanceState)
        capture.decode()
    }

    override fun onResume() {
        super.onResume()
        capture.onResume()
    }

    override fun onPause() {
        super.onPause()
        capture.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        capture.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        capture.onSaveInstanceState(outState)
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        capture.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        barcodeScannerView.onKeyDown(keyCode, event) || super.onKeyDown(keyCode, event)
}
