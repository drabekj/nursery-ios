package cz.drabek.chuvicka.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.ChildCare
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.HomeDefaults
import cz.drabek.chuvicka.PairLink
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.WizardEvents
import cz.drabek.chuvicka.baby.BabyState
import cz.drabek.chuvicka.parent.BabyFinder
import cz.drabek.chuvicka.parent.CameraFinder
import kotlinx.coroutines.delay
import java.net.URI

enum class WizardStep {
    WELCOME, ROLE,
    BABY_ROOM, BABY_PERMISSIONS, BABY_DONE,
    SOURCE, PAIR, SCAN, CAMERA_BRAND, CAMERA, SERVER, TEST,
}

/** The steps before [step] on its usual path, for the demo screens and the pairing link. */
private fun pathTo(step: WizardStep): List<WizardStep> = when (step) {
    WizardStep.WELCOME -> listOf(WizardStep.WELCOME)
    WizardStep.ROLE -> listOf(WizardStep.WELCOME, WizardStep.ROLE)
    WizardStep.SOURCE -> listOf(WizardStep.WELCOME, WizardStep.ROLE, WizardStep.SOURCE)
    WizardStep.CAMERA -> listOf(WizardStep.WELCOME, WizardStep.ROLE, WizardStep.SOURCE, WizardStep.CAMERA_BRAND, WizardStep.CAMERA)
    WizardStep.TEST -> listOf(WizardStep.WELCOME, WizardStep.ROLE, WizardStep.SOURCE, WizardStep.PAIR, WizardStep.TEST)
    else -> listOf(WizardStep.WELCOME, step)
}

/** The demo screens: "wizard", "wizard-role", "wizard-source", "wizard-camera", "wizard-test". */
fun wizardDemoStep(screen: String): WizardStep = when (screen) {
    "wizard-role" -> WizardStep.ROLE
    "wizard-source" -> WizardStep.SOURCE
    "wizard-camera" -> WizardStep.CAMERA
    "wizard-test" -> WizardStep.TEST
    else -> WizardStep.WELCOME
}

/**
 * The first-run wizard: one question per screen. The same steps as in the iOS app.
 * [cancel] is null on the first run (there is nothing to go back to).
 * [startBaby] starts the sending (it asks for the permissions if needed). [done] closes the wizard.
 */
@Composable
fun Wizard(startAt: WizardStep, cancel: (() -> Unit)?, startBaby: () -> Unit, done: () -> Unit) {
    var stack by remember { mutableStateOf(pathTo(startAt)) }
    val step = stack.last()
    fun go(next: WizardStep) { stack = stack + next }
    fun back() { if (stack.size > 1) stack = stack.dropLast(1) else cancel?.invoke() }
    fun replace(next: WizardStep) { stack = stack.dropLast(1) + next }
    BackHandler(enabled = stack.size > 1 || cancel != null) { back() }

    // The choices, kept while the parent goes back and forth.
    val rerun = cancel != null
    var parent by remember { mutableStateOf(if (rerun) Settings.role.value == Settings.Role.PARENT else true) }

    // A pairing link from the system camera: straight to the test.
    val linked by WizardEvents.linkPaired.collectAsState()
    LaunchedEffect(linked) {
        if (linked) {
            WizardEvents.linkPaired.value = false
            parent = true
            stack = pathTo(WizardStep.TEST)
        }
    }

    val parentDots = listOf(WizardStep.WELCOME, WizardStep.ROLE, WizardStep.SOURCE, WizardStep.PAIR, WizardStep.TEST)
    val babyDots = listOf(WizardStep.WELCOME, WizardStep.ROLE, WizardStep.BABY_ROOM, WizardStep.BABY_PERMISSIONS, WizardStep.BABY_DONE)
    val dotStep = when (step) { WizardStep.SCAN, WizardStep.CAMERA_BRAND, WizardStep.CAMERA, WizardStep.SERVER -> WizardStep.PAIR; else -> step }
    val dots = if (parent) parentDots else babyDots
    val frame = Frame(dots.indexOf(dotStep).coerceAtLeast(0), dots.size, showBack = stack.size > 1 || rerun, back = ::back)

    fun finishParent() {
        Settings.set(Settings.role, "role", Settings.Role.PARENT)
        Settings.set(Settings.onboarded, "onboarded", true)
        done()
    }

    when (step) {
        WizardStep.WELCOME -> WelcomeStep(frame) { go(WizardStep.ROLE) }
        WizardStep.ROLE -> RoleStep(frame, if (rerun || App.demo) parent else null) { isParent ->
            parent = isParent
            go(if (isParent) WizardStep.SOURCE else WizardStep.BABY_ROOM)
        }
        WizardStep.BABY_ROOM -> BabyRoomStep(frame) { go(WizardStep.BABY_PERMISSIONS) }
        WizardStep.BABY_PERMISSIONS -> BabyPermissionsStep(frame) { go(WizardStep.BABY_DONE) }
        WizardStep.BABY_DONE -> BabyDoneStep(frame, startBaby) {
            Settings.set(Settings.role, "role", Settings.Role.BABY)
            Settings.set(Settings.onboarded, "onboarded", true)
            done()
        }
        WizardStep.SOURCE -> SourceStep(frame,
            phone = { go(WizardStep.PAIR) },
            camera = { go(WizardStep.CAMERA_BRAND) },
            server = { go(WizardStep.SERVER) })
        WizardStep.PAIR -> PairStep(frame, scan = { go(WizardStep.SCAN) }, paired = { go(WizardStep.TEST) })
        WizardStep.SCAN -> ScanStep(frame) { link -> PairLink.apply(link); replace(WizardStep.TEST) }
        WizardStep.CAMERA_BRAND -> BrandStep(frame) { brand ->
            if (brand != Settings.rtspBrand.value) Settings.set(Settings.rtspBrand, "rtspBrand", brand)
            go(WizardStep.CAMERA)
        }
        WizardStep.CAMERA -> CameraStep(frame) { go(WizardStep.TEST) }
        WizardStep.SERVER -> ServerStep(frame) { go(WizardStep.TEST) }
        WizardStep.TEST -> TestStep(frame, fix = ::back) { finishParent() }
    }
}

/** The frame of one step: the dots, the back button, the title, the content, and one big button. */
private class Frame(val dot: Int, val dots: Int, val showBack: Boolean, val back: () -> Unit)

@Composable
private fun StepPage(
    frame: Frame,
    title: String,
    subtitle: String? = null,
    primary: String? = null,
    primaryEnabled: Boolean = true,
    onPrimary: () -> Unit = {},
    below: @Composable ColumnScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxSize().background(colors.sky).systemBarsPadding().imePadding()) {
        Box(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp)) {
            if (frame.showBack) {
                TextButton(onClick = frame.back, Modifier.align(Alignment.CenterStart)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = colors.accent)
                    Spacer(Modifier.width(6.dp))
                    Text("Zpět", color = colors.accent, fontSize = 16.sp)
                }
            }
            Dots(frame.dot, frame.dots, Modifier.align(Alignment.Center))
        }
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp)) {
            Text(title, fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            if (subtitle != null) {
                Spacer(Modifier.height(8.dp))
                Text(subtitle, fontSize = 17.sp, lineHeight = 24.sp, color = colors.muted)
            }
            Spacer(Modifier.height(24.dp))
            content()
            Spacer(Modifier.height(16.dp))
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 16.dp, top = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            if (primary != null) BigButton(primary, primaryEnabled, onPrimary)
            below()
        }
    }
}

@Composable
private fun BigButton(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().height(60.dp), shape = RoundedCornerShape(20.dp),
        colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) {
        Text(text, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
    }
}

@Composable
private fun SmallButton(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, Modifier.padding(top = 4.dp).heightIn(min = 48.dp)) {
        Text(text, color = colors.accent, fontSize = 16.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Dots(current: Int, count: Int, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        for (i in 0 until count) {
            Box(Modifier.size(if (i == current) 10.dp else 7.dp).clip(CircleShape)
                .background(if (i <= current) colors.accent else colors.neutral.copy(alpha = 0.4f)))
        }
    }
}

/** A big card to tap: an icon, a title, a line of explanation. */
@Composable
private fun BigCard(icon: ImageVector, title: String, subtitle: String?, selected: Boolean = false, badge: String? = null,
                    big: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(24.dp)
    Row(Modifier.fillMaxWidth().heightIn(min = if (big) 120.dp else 88.dp).clip(shape).background(colors.card)
        .border(2.dp, if (selected) colors.accent else Color.Transparent, shape)
        .clickable(onClick = onClick).padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(if (big) 64.dp else 52.dp).clip(CircleShape).background(colors.moon.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(if (big) 34.dp else 28.dp), tint = colors.ink)
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            if (badge != null) {
                Text(badge, Modifier.clip(RoundedCornerShape(50)).background(colors.calm.copy(alpha = 0.16f)).padding(horizontal = 10.dp, vertical = 3.dp),
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = colors.calm)
                Spacer(Modifier.height(6.dp))
            }
            Text(title, fontSize = if (big) 21.sp else 19.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            if (subtitle != null) Text(subtitle, fontSize = 15.sp, lineHeight = 21.sp, color = colors.muted)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = colors.muted)
    }
}

@Composable
private fun Bullet(icon: ImageVector, text: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(colors.card), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = colors.accent)
        }
        Spacer(Modifier.width(14.dp))
        Text(text, fontSize = 17.sp, lineHeight = 23.sp, color = colors.ink)
    }
}

@Composable
private fun Numbered(n: Int, text: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(28.dp).clip(CircleShape).background(colors.moon), contentAlignment = Alignment.Center) {
            Text("$n", fontWeight = FontWeight.Bold, color = Color.Black, fontSize = 15.sp)
        }
        Spacer(Modifier.width(12.dp))
        Text(text, fontSize = 17.sp, lineHeight = 23.sp, color = colors.ink)
    }
}

@Composable
private fun Note(text: String, color: Color = colors.muted) {
    Text(text, Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(colors.card).padding(14.dp),
        fontSize = 15.sp, lineHeight = 21.sp, color = color)
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, hint: String? = null,
                  keyboard: KeyboardType = KeyboardType.Text, password: Boolean = false) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().padding(bottom = 12.dp),
        label = { Text(label) },
        supportingText = if (hint != null) ({ Text(hint) }) else null,
        singleLine = true,
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (password) KeyboardType.Password else keyboard))
}

// MARK: Welcome and the role

@Composable
private fun WelcomeStep(frame: Frame, next: () -> Unit) {
    StepPage(frame, "Vítejte v Chůvičce", "Klidný spánek pro miminko i pro vás.", primary = "Začít", onPrimary = next) {
        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(120.dp).clip(CircleShape).background(colors.moon.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Bedtime, null, Modifier.size(64.dp), tint = colors.accent)
            }
        }
        Spacer(Modifier.height(16.dp))
        Bullet(Icons.Filled.Videocam, "Živý obraz a zvuk z pokojíčku")
        Bullet(Icons.Filled.NotificationsActive, "Upozornění na pláč i na výpadek spojení")
        Bullet(Icons.Filled.Lock, "Soukromé: obraz ani zvuk nejdou přes cizí server")
    }
}

@Composable
private fun RoleStep(frame: Frame, chosen: Boolean?, choose: (Boolean) -> Unit) {
    StepPage(frame, "Co bude dělat tento telefon?") {
        BigCard(Icons.Filled.Visibility, "Hlídat miminko", "Uvidíte a uslyšíte, co se děje v pokojíčku.", selected = chosen == true, big = true) { choose(true) }
        Spacer(Modifier.height(14.dp))
        BigCard(Icons.Filled.ChildCare, "Být u miminka", "Starý telefon poslouží jako kamera.", selected = chosen == false, big = true) { choose(false) }
    }
}

// MARK: The phone at the baby

@Composable
private fun BabyRoomStep(frame: Frame, next: () -> Unit) {
    val name by Settings.unitName.collectAsState()
    val video by Settings.unitVideo.collectAsState()
    StepPage(frame, "Jak se pokojíček jmenuje?", "Tento název uvidíte na telefonu rodiče.", primary = "Další",
        primaryEnabled = name.isNotBlank(), onPrimary = next) {
        Field(name, { Settings.set(Settings.unitName, "unitName", it.take(40)) }, "Název")
        Spacer(Modifier.height(12.dp))
        Text("Co má telefon posílat?", fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
        Spacer(Modifier.height(12.dp))
        BigCard(Icons.Filled.Videocam, "Obraz i zvuk", "Uvidíte i uslyšíte miminko.", selected = video) {
            Settings.set(Settings.unitVideo, "unitVideo", true)
        }
        Spacer(Modifier.height(12.dp))
        BigCard(Icons.Filled.GraphicEq, "Jen zvuk", "Šetří baterii, kamera zůstane vypnutá.", selected = !video) {
            Settings.set(Settings.unitVideo, "unitVideo", false)
        }
    }
}

@Composable
private fun BabyPermissionsStep(frame: Frame, next: () -> Unit) {
    val context = LocalContext.current
    val video by Settings.unitVideo.collectAsState()
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { next() }
    val needed = buildList {
        if (video) add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }.filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
    StepPage(frame, if (video) "Kamera a mikrofon" else "Mikrofon",
        "Telefon teď požádá o povolení. Klepněte na Povolit.",
        primary = if (needed.isEmpty()) "Další" else "Povolit", onPrimary = {
            if (needed.isEmpty() || App.demo) next() else ask.launch(needed.toTypedArray())
        }) {
        if (video) Bullet(Icons.Filled.Videocam, "Kamera: aby telefon posílal obraz postýlky.")
        Bullet(Icons.Filled.GraphicEq, "Mikrofon: abyste miminko slyšeli.")
        if (Build.VERSION.SDK_INT >= 33) Bullet(Icons.Filled.NotificationsActive, "Oznámení: ukazuje, že vysílání běží.")
        Spacer(Modifier.height(8.dp))
        Note("Obraz a zvuk jdou jen do telefonů, které se spárují s tímto telefonem. Nikam jinam.")
    }
}

@Composable
private fun BabyDoneStep(frame: Frame, startBaby: () -> Unit, done: () -> Unit) {
    val running by BabyState.running.collectAsState()
    val parents by BabyState.parents.collectAsState()
    val error by BabyState.error.collectAsState()
    // Start sending now, so the parent's phone can connect as soon as it scans the code.
    LaunchedEffect(Unit) { if (!BabyState.running.value) startBaby() }
    StepPage(frame,
        title = if (parents > 0) "Hotovo! Telefon rodiče je připojený." else "Skoro hotovo",
        subtitle = "Položte telefon k postýlce a připojte nabíječku. Pak na svém telefonu naskenujte tento QR kód.",
        primary = "Hotovo", onPrimary = done) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { PairQr(label = null) }
        Spacer(Modifier.height(16.dp))
        val (text, color) = when {
            error != null -> error!! to colors.alarm
            parents > 0 -> "Vysílá do telefonu rodiče." to colors.calm
            running -> "Vysílá. Čeká na telefon rodiče…" to colors.muted
            else -> "Spouštím vysílání…" to colors.muted
        }
        Text(text, Modifier.fillMaxWidth(), fontSize = 16.sp, color = color, textAlign = TextAlign.Center)
        if (error != null) SmallButton("Zkusit znovu") { BabyState.error.value = null; startBaby() }
        Spacer(Modifier.height(12.dp))
        Text("Na telefonu rodiče: otevřete Chůvičku, zvolte Hlídat miminko → Druhý telefon → Naskenovat QR kód.",
            fontSize = 15.sp, lineHeight = 21.sp, color = colors.muted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

// MARK: The parent: where the picture comes from

@Composable
private fun SourceStep(frame: Frame, phone: () -> Unit, camera: () -> Unit, server: () -> Unit) {
    StepPage(frame, "Odkud bude obraz a zvuk?", below = { SmallButton("Mám vlastní server", server) }) {
        BigCard(Icons.Filled.PhoneAndroid, "Druhý telefon", "Starý telefon postavíte k postýlce. Nejjednodušší.",
            badge = "Doporučeno", big = true, onClick = phone)
        Spacer(Modifier.height(14.dp))
        BigCard(Icons.Filled.Videocam, "Mám IP kameru", "Tapo, Hikvision, Dahua…", onClick = camera)
    }
}

@Composable
private fun PairStep(frame: Frame, scan: () -> Unit, paired: () -> Unit) {
    val context = LocalContext.current
    var manual by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf<String?>(null) }
    StepPage(frame, "Naskenujte QR kód z druhého telefonu", primary = "Naskenovat QR kód", onPrimary = scan,
        below = { if (!manual) SmallButton("Zadat kód ručně") { manual = true } }) {
        Numbered(1, "Na druhém telefonu otevřete Chůvičku.")
        Numbered(2, "Zvolte Být u miminka.")
        Numbered(3, "Ukáže QR kód. Ten naskenujte tímto telefonem.")
        Spacer(Modifier.height(8.dp))
        Text("Na druhém telefonu musí být Chůvička také nainstalovaná.", fontSize = 14.sp, color = colors.muted)
        if (manual) {
            val finder = remember { BabyFinder(context) }
            DisposableEffect(Unit) { finder.start(); onDispose { finder.stop() } }
            val names by finder.names.collectAsState()
            var slow by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) { delay(10_000); slow = true }
            Spacer(Modifier.height(24.dp))
            Text("Telefony u miminka v okolí", fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            Spacer(Modifier.height(10.dp))
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card)) {
                if (names.isEmpty()) Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = colors.accent)
                    Spacer(Modifier.width(12.dp))
                    Text("Hledám druhý telefon…", color = colors.muted, fontSize = 16.sp)
                }
                names.forEach { name ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable { picking = name }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.PhoneAndroid, null, tint = colors.accent)
                        Spacer(Modifier.width(12.dp))
                        Text(name, Modifier.weight(1f), fontSize = 17.sp, color = colors.ink)
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = colors.muted)
                    }
                }
            }
            if (names.isEmpty() && slow) {
                Spacer(Modifier.height(10.dp))
                Text("Nevidíte druhý telefon? Zkontrolujte, že jsou oba na stejné Wi-Fi a že druhý telefon ukazuje QR kód.",
                    fontSize = 15.sp, color = colors.muted)
            }
        }
    }
    picking?.let { name -> PairCodeDialog(name, dismiss = { picking = null }, paired = { picking = null; paired() }) }
}

@Composable
private fun ScanStep(frame: Frame, found: (PairLink.Info) -> Unit) {
    StepPage(frame, "Namiřte na QR kód", "Na druhém telefonu, který je u miminka.") {
        QrScanner(found)
    }
}

// MARK: The IP camera

@Composable
private fun BrandStep(frame: Frame, choose: (Settings.CameraBrand) -> Unit) {
    val brands = Settings.CameraBrand.entries
    StepPage(frame, "Jakou máte kameru?") {
        for (row in brands.chunked(2)) {
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                for (b in row) {
                    Column(Modifier.weight(1f).height(104.dp).clip(RoundedCornerShape(24.dp)).background(colors.card)
                        .clickable { choose(b) }.padding(12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Icon(Icons.Filled.Videocam, null, tint = colors.accent)
                        Spacer(Modifier.height(8.dp))
                        Text(b.title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = colors.ink, textAlign = TextAlign.Center)
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun CameraStep(frame: Frame, next: () -> Unit) {
    val brand by Settings.rtspBrand.collectAsState()
    val demo = App.demo
    val saved = remember { try { URI(Settings.rtspUrl.value) } catch (e: Exception) { null } }
    var ip by remember { mutableStateOf(if (demo) "192.168.0.50" else saved?.host ?: "") }
    var port by remember { mutableStateOf(saved?.port?.takeIf { it > 0 }?.toString() ?: "554") }
    var user by remember { mutableStateOf(if (demo) "chuvicka" else Settings.rtspUser.value) }
    var password by remember { mutableStateOf(if (demo) "heslo1234" else Settings.rtspPassword) }
    var url by remember { mutableStateOf(if (brand == Settings.CameraBrand.OTHER) Settings.rtspUrl.value else "") }
    var showPort by remember { mutableStateOf(false) }
    val other = brand == Settings.CameraBrand.OTHER
    val ready = if (other) url.isNotBlank() else ip.isNotBlank()

    StepPage(frame, if (other) "Jiná kamera" else "Kamera ${brand.title}", "Údaje najdete v aplikaci kamery.", primary = "Vyzkoušet", primaryEnabled = ready, onPrimary = {
        val host = ip.trim().removePrefix("rtsp://").trimEnd('/')
        val p = port.trim().toIntOrNull() ?: 554
        val main = if (other) url.trim().let { if (it.startsWith("rtsp://", ignoreCase = true)) it else "rtsp://$it" } else "rtsp://$host:$p/${brand.main}"
        val small = if (other) "" else "rtsp://$host:$p/${brand.small}"
        Settings.set(Settings.rtspUrl, "rtspUrl", main)
        Settings.set(Settings.rtspUrlSmall, "rtspUrlSmall", small)
        Settings.set(Settings.rtspUser, "rtspUser", user.trim())
        Settings.rtspPassword = password
        Settings.set(Settings.cameraKind, "cameraKind", Settings.KIND_RTSP)
        Settings.set(Settings.source, "source", Settings.Source.CAMERA)
        next()
    }, below = { if (!other && !showPort) SmallButton("Jiný port než 554") { showPort = true } }) {
        if (other) {
            Field(url, { url = it }, "Adresa streamu", "Začíná rtsp://, najdete ji v návodu ke kameře.", KeyboardType.Uri)
        } else {
            Field(ip, { ip = it }, "Adresa kamery", "Například 192.168.0.50", KeyboardType.Uri)
            FinderSection(554, "kameru",
                "Kameru jsme v síti nenašli. Je zapnutá a na stejné Wi-Fi? Adresu najdete také v aplikaci kamery, obvykle pod Informace o zařízení.",
                ip) { ip = it }
        }
        Field(user, { user = it }, "Uživatelské jméno")
        Field(password, { password = it }, "Heslo", password = true)
        if (!other && showPort) Field(port, { v -> port = v.filter(Char::isDigit).take(5) }, "Port", keyboard = KeyboardType.Number)
        when (brand) {
            Settings.CameraBrand.TAPO -> Note("Účet kamery vytvoříte v aplikaci Tapo: Kamera → Nastavení → Pokročilé → Účet kamery. Není to váš účet Tapo.")
            Settings.CameraBrand.REOLINK -> Note("Kamery Reolink posílají zvuk ve formátu, který Chůvička neumí přehrát. Obraz ale funguje.", colors.warn)
            else -> {}
        }
    }
}

/** "Najít kameru": it searches the home Wi-Fi; one find fills an empty address by itself. */
@Composable
private fun FinderSection(port: Int, what: String, hint: String, host: String, pick: (String) -> Unit) {
    val current by rememberUpdatedState(host)
    var round by remember { mutableIntStateOf(if (host.isBlank() && !App.demo) 1 else 0) }
    var searching by remember { mutableStateOf(false) }
    var found by remember { mutableStateOf<List<CameraFinder.Found>?>(null) }
    LaunchedEffect(round) {
        if (round == 0) return@LaunchedEffect
        searching = true
        val list = CameraFinder.scan(port)
        found = list
        searching = false
        if (list.size == 1 && current.isBlank()) pick(list[0].host)
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val list = found
        when {
            searching -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("Hledám $what v domácí síti…", color = colors.muted, fontSize = 14.sp)
            }
            list == null -> SmallButton("Najít $what v domácí síti") { round++ }
            list.isEmpty() -> {
                Note(hint)
                SmallButton("Hledat znovu") { round++ }
            }
            else -> {
                Text(if (list.size == 1) "Našli jsme:" else "Vyberte ji ze seznamu:", color = colors.muted, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                list.forEach { item ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(colors.card)
                        .clickable(onClickLabel = "Použít tuto adresu") { pick(item.host) }.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(item.label ?: "Zařízení", color = colors.ink, modifier = Modifier.weight(1f))
                        Text(item.host, color = colors.muted)
                        if (current.trim() == item.host) Text("  ✓", color = colors.calm, fontWeight = FontWeight.Bold)
                    }
                }
                SmallButton("Hledat znovu") { round++ }
            }
        }
    }
}

// MARK: The own server (go2rtc)

@Composable
private fun ServerStep(frame: Frame, next: () -> Unit) {
    var host by remember { mutableStateOf(Settings.host.value) }
    var main by remember { mutableStateOf(Settings.streamMain.value) }
    var small by remember { mutableStateOf(Settings.streamSmall.value) }
    // The test finds the streams itself: the names only by hand, on request.
    var manual by remember { mutableStateOf(false) }
    StepPage(frame, "Vlastní server", "Počítač v domácí síti, který čte kameru (go2rtc).", primary = "Vyzkoušet",
        primaryEnabled = host.isNotBlank() && (!manual || main.isNotBlank()), onPrimary = {
            Settings.set(Settings.host, "host", host.trim())
            Settings.set(Settings.streamMain, "streamMain", main.trim())
            Settings.set(Settings.streamSmall, "streamSmall", small.trim().ifEmpty { main.trim() })
            Settings.set(Settings.cameraKind, "cameraKind", Settings.KIND_GO2RTC)
            Settings.set(Settings.source, "source", Settings.Source.CAMERA)
            next()
        }, below = { if (!manual) SmallButton("Upravit streamy ručně") { manual = true } }) {
        Field(host, { host = it }, "Adresa serveru", "Například ${HomeDefaults.SERVER_HOST.ifEmpty { "192.168.0.10" }}", KeyboardType.Uri)
        FinderSection(1984, "server", "Server jsme v síti nenašli. Běží na něm go2rtc a je na stejné Wi-Fi?", host) { host = it }
        if (manual) {
            Field(main, { main = it }, "Stream pro detail", "Obraz ve vysoké kvalitě")
            Field(small, { small = it }, "Běžný stream", "Pro běžné sledování, režim Jen zvuk a fotku")
        }
        Note("Chůvička si streamy najde sama při zkoušce spojení.")
    }
}

// MARK: The test

@Composable
private fun TestStep(frame: Frame, fix: () -> Unit, finish: () -> Unit) {
    val context = LocalContext.current
    var result by remember { mutableStateOf<TestState?>(null) }
    val phone = Settings.source.collectAsState().value == Settings.Source.PHONE
    val name by Settings.babyName.collectAsState()
    // The alerts are asked for here, when it works: one screen less.
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { finish() }
    val needed = Build.VERSION.SDK_INT >= 33 && !App.demo &&
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    val offer = needed || App.demo          // The screenshot shows the question.
    val r = result
    val title = when {
        r == null -> "Zkouším spojení…"
        r.ok && phone -> "Hotovo! ${name.ifEmpty { "Pokojíček" }} je připojený."
        r.ok -> "Hotovo! Kamera je připojená."
        else -> "Zatím to nejde"
    }
    val subtitle = when {
        r == null -> "Chvilku to potrvá. Zkouším obraz i zvuk."
        r.ok && (r.video == TestCheck.FAIL || r.audio == TestCheck.FAIL) -> "Něco funguje jen napůl. Podívejte se níže."
        r.ok -> "Obraz i zvuk přicházejí."
        else -> "Podívejte se níže, co nefunguje."
    }
    StepPage(frame, title, subtitle,
        primary = when { r == null -> "Pokračovat"; r.ok && offer -> "Povolit upozornění a začít"; r.ok -> "Začít"; else -> "Zpět a opravit" },
        primaryEnabled = r != null,
        onPrimary = {
            when {
                r == null -> {}
                !r.ok -> fix()
                needed -> ask.launch(Manifest.permission.POST_NOTIFICATIONS)
                else -> finish()
            }
        },
        below = {
            if (r != null && r.ok && offer) SmallButton("Bez upozornění", finish)
            if (r != null && !r.ok) SmallButton("Přesto pokračovat", finish)
        }) {
        ConnectionTest(onResult = { result = it })
        if (r != null && r.ok) {
            Spacer(Modifier.height(12.dp))
            Bullet(Icons.Filled.NotificationsActive, "Chůvička vás upozorní, když se miminko ozve nebo když vypadne spojení. I se zhasnutým displejem.")
        }
    }
}
