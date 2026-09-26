import SwiftUI

/// "Nápověda" as a sheet, from the ⋯ menu.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpList()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
                }
        }
    }
}

/// "Jak Chůvička funguje": the answers to the questions a parent asks before the first night.
/// Without its own stack, so Settings can push it too.
struct HelpList: View {
    @EnvironmentObject private var battery: BatteryMonitor

    var body: some View {
        List {
            topic("lock.iphone", "Se zamčeným telefonem",
                  "Zvuk běží dál i se zamčenou obrazovkou a když přepnete do jiné aplikace. Video nebo hudba v jiné aplikaci Chůvičku nepřeruší, hrají spolu. Přeruší ji jen telefonát, po něm se hlídání obnoví samo. Na zamčené obrazovce je aktivita „Chůvička hlídá od 21:40“.",
                  footnote: "iOS nedovolí aplikacím, které na pozadí jen přehrávají zvuk, průběžně měnit aktivitu na zamčené obrazovce. Proto ukazuje hlavně to, že Chůvička hlídá a od kdy.")
            topic("stop.circle", "Jak hlídání vypnout",
                  "Na zamčené obrazovce klepněte na Ukončit hlídání, nebo v aplikaci na tři tečky → Ukončit hlídání. V nočním režimu klepněte na displej a zvolte Ukončit hlídání. Hlídání skončí také, když aplikaci zavřete přejetím nahoru v přepínači aplikací.",
                  footnote: "Když hlídání vypnete vy, žádné upozornění nepřijde. Upozornění „Chůvička přestala hlídat“ přijde jen tehdy, když aplikaci ukončí iOS.")
            topic("bell.badge", "Když se něco pokazí",
                  "Když vypadne spojení s kamerou, přijde po 20 sekundách upozornění a Chůvička se sama připojí znovu. Kdyby iOS aplikaci ukončil, do 2,5 minuty přijde upozornění „Chůvička přestala hlídat“. Stačí ji znovu otevřít.",
                  footnote: "Upozornění fungují, jen když je povolíte. Aplikaci nezavírejte přejetím nahoru v přepínači aplikací, tím hlídání ukončíte.")
            topic("waveform", "Obraz, nebo jen zvuk",
                  "Přepínač nahoře volí, co hlavní obrazovka ukazuje. Obraz ukazuje živé video z postýlky. Jen zvuk ukazuje jen pokojíček: kruh, který se rozvlní se zvukem, a slovy, co se děje. Obraz se nezobrazuje. Z kamery se přesto stahuje, protože některé kamery bez obrazu neposílají ani zvuk. Z telefonu u miminka jde jen zvuk.",
                  footnote: "Jen zvuk šetří baterii i Wi-Fi a telefon méně hřeje. Na miminko se můžete kdykoli podívat tlačítkem Fotka z postýlky. Pořídí jednu fotku z kamery, bez živého obrazu.")
            topic("speaker.wave.1", "Hlasitost",
                  "Chůvička hraje tak hlasitě, jak je nastavený telefon. Když je hlasitost telefonu pod 20 %, ukáže Chůvička upozornění a posuvník hlasitosti. Když je zvuk ztlumený, tlačítko Zvuk svítí červeně. Při pláči pak přijde upozornění, stejně jako při hlasitosti pod 20 %.",
                  footnote: "Tlačítko ztišení na boku telefonu Chůvičku neztiší. Hlasitost ale ano.")
            topic("moon.stars", "Noční režim",
                  "Displej zůstane zapnutý, ale téměř černý a na nejnižším jasu. Telefon se sám nezamkne. Obraz se zastaví, zvuk a upozornění běží dál. Když se miminko ozve, vlnovka se rozsvítí. Klepnutím zobrazíte Zvuk a Ukončit hlídání, dalším klepnutím noční režim ukončíte.")
            topic("battery.75", "Baterie a nabíjení",
                  "Nejúspornější je zamčený telefon, kdy běží jen zvuk. Noční režim a zobrazení Jen zvuk spotřebují o něco víc, protože svítí displej. Nejvíc spotřebuje otevřená aplikace se živým obrazem. Na celou noc doporučujeme nabíječku.",
                  footnote: "Spotřebu vašeho telefonu Chůvička měří sama. Teď: \(battery.summary).")
            topic("bell.badge.fill", "Ztlumeno",
                  "Když zvuk ztlumíte tlačítkem Zvuk, Chůvička nic nepřehrává, ale dál poslouchá. Když se miminko rozpláče, přijde upozornění, i když máte aplikaci otevřenou. Hodí se, když nechcete celou noc slyšet šum pokoje.",
                  footnote: "Upozornění přijde také při živém zvuku, když je hlasitost telefonu pod 20 %. Poslouchat úplně přestane jen po Ukončit hlídání.")
            topic("chart.bar.xaxis", "Přehled",
                  "Ukazuje, kdy Chůvička poslouchala a kdy se miminko ozvalo, i s fotkou z kamery. Šedá místa znamenají, že Chůvička neposlouchala. To není totéž co ticho.")
            topic("iphone.gen3.radiowaves.left.and.right", "Dva telefony místo kamery",
                  "Starší iPhone nebo telefon s Androidem může být kamerou u postýlky. Nainstalujte na něj Chůvičku a zvolte Být u miminka. Na svém telefonu pak v Nastavení → Kamera zvolte Druhý telefon a naskenujte jeho QR kód. Spolu fungují všechny kombinace iPhonu a Androidu.",
                  footnote: "iPhone u miminka musí mít Chůvičku otevřenou a nezamčenou, jinak iOS zastaví kameru. Zvuk poběží i se zamčeným telefonem. Android u miminka vysílá obraz i zvuk i se zhasnutým displejem. Oba nechte na nabíječce.")
            topic("globe", "Mimo domov",
                  "Doma se Chůvička připojuje přímo. Mimo domov jde přes vaši soukromou síť (Tailscale), která musí být v telefonu zapnutá. Nastavíte ji v Nastavení → Pro pokročilé → Mimo domov. Telefon u miminka ji musí mít také a jednou se k němu musíte připojit doma, aby si Chůvička zapamatovala jeho adresu.",
                  footnote: "Obraz jde šifrovaně, ne přes cizí server. V Nastavení → Pro pokročilé v řádku Cesta vidíte, jestli jde spojení doma, nebo mimo domov.")
            topic("hand.raised", "Soukromí",
                  "Obraz i zvuk zůstávají ve vaší domácí síti, mimo domov jdou jen šifrovaně přes vaši soukromou síť. Nic se neposílá na cizí server a kamera sama přístup k internetu nemá.",
                  footnote: "Doma jdou obraz, zvuk i párovací kód po Wi-Fi nešifrovaně. Kdo Wi-Fi odposlouchává, mohl by je vidět a slyšet. Používejte proto Wi-Fi, které důvěřujete, ne síť pro hosty. Chůvička není zdravotnický prostředek. Nespoléhejte na ni jako na jediný dohled.")
            Section {
                topicBody("calendar.badge.exclamationmark", "Platnost instalace",
                          "Aplikace nainstalovaná z Macu s bezplatným účtem Apple funguje 7 dní. Potom ji v Xcode znovu nainstalujte, nastavení a přehled zůstanou.")
            } header: {
                Text("Pro vývojáře")
            }
        }
        .navigationTitle("Jak Chůvička funguje")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topic(_ symbol: String, _ title: String, _ text: String, footnote: String? = nil) -> some View {
        Section { topicBody(symbol, title, text, footnote: footnote) }
    }

    private func topicBody(_ symbol: String, _ title: String, _ text: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}
