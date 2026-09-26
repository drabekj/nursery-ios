package cz.drabek.chuvicka

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
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
import cz.drabek.chuvicka.parent.ServerMigration
import cz.drabek.chuvicka.ui.BabyScreen
import cz.drabek.chuvicka.ui.ChuvickaTheme
import cz.drabek.chuvicka.ui.HelpScreen
import cz.drabek.chuvicka.ui.LogScreen
import cz.drabek.chuvicka.ui.PairingScreen
import cz.drabek.chuvicka.ui.ParentScreen
import cz.drabek.chuvicka.ui.RemoteScreen
import cz.drabek.chuvicka.ui.ScannerPage
import cz.drabek.chuvicka.ui.SettingsScreen
import cz.drabek.chuvicka.ui.Wizard
import cz.drabek.chuvicka.ui.WizardStep
import cz.drabek.chuvicka.ui.wizardDemoStep
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private var pip by mutableStateOf(false)
    /** The first-run wizard, or the wizard again from the settings. */
    private var wizardOpen by mutableStateOf(false)
    /** Where the wizard starts: the welcome, or the source when the settings change the camera. */
    private var wizardStart by mutableStateOf(WizardStep.WELCOME)
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
            // The glance view: "sound…" and "klid". The engine sets the room state from the name.
            Settings.soundView.value = App.demoScreen.startsWith("sound") || App.demoScreen == "klid"
            // "sound-muted": Ozývá se with the muted ribbon. The monitor takes the mode at its start.
            if (App.demoScreen == "sound-muted") Settings.soundMode.value = cz.drabek.chuvicka.parent.SoundMode.OFF
            Settings.appearance.value = if (App.demoScreen.endsWith("dark")) Settings.Appearance.DARK else Settings.Appearance.LIGHT
            Settings.unitCode.value = "482913"
            if (App.demoScreen == "wizard-test") Settings.source.value = Settings.Source.PHONE
            if (App.demoScreen == "wizard-camera") Settings.rtspBrand.value = Settings.CameraBrand.TAPO
            if (App.demoScreen == "paused") Monitor.paused.value = true
        }
        // The demo shows the wizard only for its own screens. Otherwise: until it is done once.
        wizardOpen = if (App.demo) App.demoScreen.startsWith("wizard") else !Settings.onboarded.value
        handleLink(intent)
        addOnNewIntentListener { handleLink(it) }
        // The wizard asks for the notifications itself, with an explanation.
        if (Build.VERSION.SDK_INT >= 33 && !App.demo && !wizardOpen &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
        }
        setContent {
            val role by Settings.role.collectAsState()
            val appearance by Settings.appearance.collectAsState()
            var page by remember {
                mutableStateOf(when (App.demoScreen) {
                    "settings", "settings-advanced" -> "settings"
                    "help" -> "help"
                    "remote" -> "remote"
                    else -> "main"
                })
            }
            // The help opens from the monitor (the ⋯ menu) or from the settings: back goes there.
            var helpFrom by remember { mutableStateOf("settings") }
            BackHandler(!wizardOpen && page != "main") {
                page = when (page) { "settings" -> "main"; "scan" -> "pairing"; "help" -> helpFrom; else -> "settings" }
            }
            // Once per launch: a go2rtc camera moves to the direct camera (only the first time after the update).
            var migrationChecked by remember { mutableStateOf(false) }
            // The monitor waits while the wizard runs: its connection test needs the camera to itself.
            LaunchedEffect(role, wizardOpen) {
                if (!migrationChecked && !App.demo && Settings.onboarded.value && role == Settings.Role.PARENT && !wizardOpen) {
                    migrationChecked = true
                    withContext(Dispatchers.IO) { ServerMigration.run(applicationContext) }
                }
                if (role == Settings.Role.PARENT && !wizardOpen && !Monitor.paused.value) ParentService.start(this@MainActivity)
                else ParentService.stop(this@MainActivity)
            }
            LaunchedEffect(Unit) {
                if (App.demoScreen == "night" || App.demoScreen == "night-controls" || App.demoScreen == "night-cry") Monitor.night.value = true
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
                    wizardOpen -> Wizard(
                        startAt = if (App.demo) wizardDemoStep(App.demoScreen) else wizardStart,
                        cancel = if (Settings.onboarded.value) ({ wizardOpen = false }) else null,
                        startBaby = ::startBaby,
                        done = { page = "main"; wizardOpen = false },
                    )
                    role == Settings.Role.BABY -> BabyScreen(
                        start = ::startBaby,
                        stop = { BabyService.stop(this) },
                        becomeParent = { Settings.set(Settings.role, "role", Settings.Role.PARENT) },
                        openWizard = { wizardStart = WizardStep.WELCOME; wizardOpen = true },
                    )
                    page == "settings" -> SettingsScreen(
                        back = { page = "main" },
                        openLog = { page = "log" },
                        becomeBaby = { page = "main"; Settings.set(Settings.role, "role", Settings.Role.BABY) },
                        // Back out of the wizard returns to the settings; done goes to the monitor.
                        openWizard = { step -> wizardStart = step; wizardOpen = true },
                        openHelp = { helpFrom = "settings"; page = "help" },
                        openRemote = { page = "remote" },
                    )
                    page == "help" -> HelpScreen(back = { page = helpFrom })
                    page == "remote" -> RemoteScreen(back = { page = "settings" })
                    page == "pairing" -> PairingScreen(back = { page = "settings" }, openScanner = { page = "scan" })
                    page == "scan" -> ScannerPage(back = { page = "pairing" }, paired = { Monitor.reconnect("paired"); page = "pairing" })
                    page == "log" -> LogScreen(back = { page = "settings" })
                    else -> ParentScreen(openSettings = { page = "settings" }, openHelp = { helpFrom = "main"; page = "help" }, pip = pip, enterPip = ::enterPip)
                }
            }
        }
    }

    /** A pairing link (chuvicka://pair?...) from the system camera or another app. */
    private fun handleLink(intent: Intent?) {
        val link = PairLink.parse(intent?.data) ?: return
        intent?.data = null                    // Once only, also after a restart of the activity.
        PairLink.apply(link)
        if (wizardOpen) {
            WizardEvents.linkPaired.value = true
        } else {
            Settings.set(Settings.role, "role", Settings.Role.PARENT)
            Monitor.reconnect("paired by a link")
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

    /** The monitor knows whether the parent sees the app. */
    override fun onStart() {
        super.onStart()
        Monitor.foreground.value = true
    }

    override fun onStop() {
        Monitor.foreground.value = false
        super.onStop()
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
