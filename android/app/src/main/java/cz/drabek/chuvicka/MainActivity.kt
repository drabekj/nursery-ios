package cz.drabek.chuvicka

import android.Manifest
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import cz.drabek.chuvicka.baby.BabyService
import cz.drabek.chuvicka.parent.Monitor
import cz.drabek.chuvicka.parent.ParentService
import cz.drabek.chuvicka.ui.BabyScreen
import cz.drabek.chuvicka.ui.ChuvickaTheme
import cz.drabek.chuvicka.ui.LogScreen
import cz.drabek.chuvicka.ui.PairingScreen
import cz.drabek.chuvicka.ui.ParentScreen
import cz.drabek.chuvicka.ui.SettingsScreen

class MainActivity : ComponentActivity() {
    private var pip by mutableStateOf(false)
    private var onPermissions: (() -> Unit)? = null
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val then = onPermissions ?: return@registerForActivityResult     // Only the notifications: nothing to do.
        onPermissions = null
        if (result.values.all { it }) then()
        else cz.drabek.chuvicka.baby.BabyState.error.value =
            "Chůvička potřebuje kameru a mikrofon. Povolte je v Nastavení telefonu → Aplikace → Chůvička."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // The screenshots: adb shell am start ... --ez demo true --es screen sound
        if (intent.getBooleanExtra("demo", false)) {
            App.demo = true
            App.demoScreen = intent.getStringExtra("screen") ?: ""
            Settings.role.value = if (App.demoScreen.startsWith("baby")) Settings.Role.BABY else Settings.Role.PARENT
            Settings.soundView.value = App.demoScreen == "sound" || App.demoScreen == "sound-dark"
            Settings.appearance.value = if (App.demoScreen.endsWith("dark")) Settings.Appearance.DARK else Settings.Appearance.LIGHT
            Settings.unitCode.value = "482913"
        }
        if (Build.VERSION.SDK_INT >= 33 && !App.demo &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
        }
        setContent {
            val role by Settings.role.collectAsState()
            val appearance by Settings.appearance.collectAsState()
            var page by remember { mutableStateOf(if (App.demoScreen == "settings") "settings" else "main") }
            BackHandler(page != "main") { page = if (page == "settings") "main" else "settings" }
            LaunchedEffect(role) {
                if (role == Settings.Role.PARENT) ParentService.start(this@MainActivity)
                else ParentService.stop(this@MainActivity)
            }
            LaunchedEffect(Unit) {
                if (App.demoScreen == "night") Monitor.night.value = true
                if (App.demoScreen == "baby-live") BabyService.start(this@MainActivity)
            }
            // The status bar icons follow the app's appearance, not the system's.
            val dark = appearance == Settings.Appearance.DARK ||
                (appearance == Settings.Appearance.AUTO && androidx.compose.foundation.isSystemInDarkTheme())
            LaunchedEffect(dark) {
                val style = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                            else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            ChuvickaTheme(appearance) {
                when {
                    role == Settings.Role.BABY -> BabyScreen(
                        start = ::startBaby,
                        stop = { BabyService.stop(this) },
                        becomeParent = { Settings.set(Settings.role, "role", Settings.Role.PARENT) },
                    )
                    page == "settings" -> SettingsScreen(
                        back = { page = "main" },
                        openPairing = { page = "pairing" },
                        openLog = { page = "log" },
                        becomeBaby = { page = "main"; Settings.set(Settings.role, "role", Settings.Role.BABY) },
                    )
                    page == "pairing" -> PairingScreen(back = { page = "settings" })
                    page == "log" -> LogScreen(back = { page = "settings" })
                    else -> ParentScreen(openSettings = { page = "settings" }, pip = pip, enterPip = ::enterPip)
                }
            }
        }
    }

    /** The baby phone needs the camera (for the picture) and the microphone before its service starts. */
    private fun startBaby() {
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Settings.unitVideo.value) add(Manifest.permission.CAMERA)
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) BabyService.start(this)
        else { onPermissions = { BabyService.start(this) }; permissions.launch(needed.toTypedArray()) }
    }

    private fun enterPip() {
        val (w, h) = Monitor.videoSize.value
        enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(w, maxOf(h, 1))).build())
    }

    /** Home with the picture on: the small window opens, as on the iPhone. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Settings.role.value == Settings.Role.PARENT && !Settings.soundView.value && Monitor.pictureLive.value && !Monitor.night.value) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pip = isInPictureInPictureMode
    }
}
