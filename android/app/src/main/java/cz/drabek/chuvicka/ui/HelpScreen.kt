package cz.drabek.chuvicka.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** "Nápověda": the answers to the questions a parent asks before the first night. The texts of the iOS app. */
@Composable
fun HelpScreen(back: () -> Unit) {
    Page("Jak Chůvička funguje", back) {
        Topic(Icons.Filled.ScreenLockPortrait, "Se zamčeným telefonem",
            "Zvuk běží dál i se zamčenou obrazovkou a když přepnete do jiné aplikace. Video nebo hudba v jiné aplikaci Chůvičku nepřeruší, hrají spolu. Dokud Chůvička hlídá, je v oznámeních „Chůvička hlídá“ i s tím, co se v pokojíčku děje.",
            "Android vyžaduje, aby aplikace, která hlídá se zhasnutým displejem, měla oznámení. Proto ho nejde skrýt.")
        Topic(Icons.Filled.StopCircle, "Jak hlídání vypnout",
            "V oznámení „Chůvička hlídá“ klepněte na Ukončit hlídání, nebo v aplikaci na tři tečky → Ukončit hlídání. Hlídání skončí také, když aplikaci zavřete přejetím v přehledu aplikací.",
            "Když hlídání vypnete vy, žádné upozornění nepřijde.")
        Topic(Icons.Filled.NotificationsActive, "Když se něco pokazí",
            "Když vypadne spojení s kamerou, přijde po 20 sekundách upozornění a Chůvička se sama připojí znovu.",
            "Upozornění fungují, jen když je povolíte. Aplikaci nezavírejte přejetím v přehledu aplikací, tím hlídání ukončíte.")
        Topic(Icons.Filled.GraphicEq, "Obraz, nebo jen zvuk",
            "Přepínač nahoře volí, co hlavní obrazovka ukazuje. Obraz ukazuje živé video z postýlky. Jen zvuk ukazuje jen pokojíček: kruh, který se rozvlní se zvukem, a slovy, co se děje. Obraz se nezobrazuje. Z kamery se přesto stahuje v nižším rozlišení, protože některé kamery (třeba Tapo) bez obrazu neposílají ani zvuk.",
            "Jen zvuk šetří baterii i Wi-Fi a telefon méně hřeje. Na miminko se můžete kdykoli podívat klepnutím na Fotka z postýlky. Pořídí jednu fotku, bez živého obrazu, z kamery i z druhého telefonu.")
        Topic(Icons.AutoMirrored.Filled.VolumeUp, "Hlasitost",
            "Chůvička hraje tak hlasitě, jak je nastavený telefon. Když je hlasitost telefonu pod 20 %, ukáže Chůvička upozornění a tlačítko Zesílit. Hlasitost Chůvičky můžete zvýšit v Nastavení → Hlasitost.")
        Topic(Icons.AutoMirrored.Filled.VolumeOff, "Ztlumeno",
            "Když zvuk ztlumíte tlačítkem Zvuk, Chůvička nic nepřehrává, ale dál poslouchá. Tlačítko pak svítí červeně a ukazuje Ztlumeno. Když se miminko rozpláče, přijde upozornění, i když máte aplikaci otevřenou. Hodí se, když nechcete celou noc slyšet šum pokoje.",
            "Upozornění přijde také při živém zvuku, když je hlasitost telefonu pod 20 %. Poslouchat úplně přestane jen po Ukončit hlídání.")
        Topic(Icons.Filled.Bedtime, "Noční režim",
            "Displej zůstane zapnutý, ale téměř černý a na nejnižším jasu. Telefon se sám nezamkne. Obraz se zastaví, zvuk a upozornění běží dál. Když se miminko ozve, vlnovka se rozsvítí. Klepnutím zobrazíte tlačítka Zvuk a Ukončit hlídání, dalším klepnutím noční režim ukončíte.")
        Topic(Icons.Filled.BatteryChargingFull, "Baterie a nabíjení",
            "Nejúspornější je zamčený telefon, kdy běží jen zvuk. Noční režim a zobrazení Jen zvuk spotřebují o něco víc, protože svítí displej. Nejvíc spotřebuje otevřená aplikace se živým obrazem. Na celou noc doporučujeme nabíječku.")
        Topic(Icons.Filled.PhoneAndroid, "Dva telefony místo kamery",
            "Starší telefon s Androidem nebo iPhone může být kamerou u postýlky. Nainstalujte na něj Chůvičku a v průvodci zvolte Být u miminka. Na svém telefonu pak v Nastavení → Kamera zvolte Druhý telefon a naskenujte jeho QR kód. Spolu fungují všechny kombinace Androidu a iPhonu.",
            "Android u miminka vysílá obraz i zvuk i se zhasnutým displejem. iPhone u miminka musí mít Chůvičku otevřenou a nezamčenou. Oba nechte na nabíječce.")
        Topic(Icons.Filled.Videocam, "Kamera v síti",
            "Chůvička čte kameru přímo, bez serveru. Kamera zvládne jen několik telefonů najednou: když je jich moc, Chůvička to řekne a zkusí to za chvíli znovu. Když kamera dostane novou adresu, Chůvička ji sama najde.",
            "Natočit funguje u kamer, které umí ONVIF (Tapo, Hikvision, Dahua, Reolink).")
        Topic(Icons.Filled.Public, "Mimo domov",
            "Doma se Chůvička připojuje přímo. Mimo domov jde šifrovaně přes vaši soukromou síť, kterou jednou nastavíte v Nastavení → Pro pokročilé → Mimo domov. Telefon u miminka ji musí mít také a jednou se k němu musíte připojit doma, aby si Chůvička zapamatovala jeho adresu.",
            "Kameru v síti uvidíte mimo domov jen s Tailscale i doma (sdílení domácí sítě, pro pokročilé); jinak jen doma. V Nastavení → Pro pokročilé → Stav vidíte, jestli jde spojení doma, nebo mimo domov.")
        Topic(Icons.Filled.Lock, "Soukromí",
            "Obraz i zvuk zůstávají ve vaší domácí Wi-Fi, mimo domov jdou jen šifrovaně přes vaši soukromou síť. Nic se neposílá na cizí server. Párovací kód jde po Wi-Fi nešifrovaně, proto telefony párujte jen v síti, které věříte.",
            "Chůvička není zdravotnický prostředek. Nespoléhejte na ni jako na jediný dohled.")
    }
}

/** One question: an icon, a title, the answer, and a small note under it. */
@Composable
private fun Topic(icon: ImageVector, title: String, text: String, footnote: String? = null) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.card).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = colors.accent)
            Spacer(Modifier.width(10.dp))
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
        }
        Text(text, fontSize = 15.sp, lineHeight = 21.sp, color = colors.ink)
        if (footnote != null) Text(footnote, fontSize = 13.sp, lineHeight = 18.sp, color = colors.muted)
    }
}
