import SwiftUI

/// "Jak Chůvička funguje": the answers to the questions a parent asks before the first night.
struct HelpView: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                topic("lock.iphone", "Se zamčeným telefonem",
                      "Zvuk běží dál i se zamčenou obrazovkou a když přepnete do jiné aplikace. Na zamčené obrazovce je Chůvička v ovládání přehrávání a ukazuje aktuální stav, třeba „Živý zvuk“ nebo „Zvuk vypadl“. Pod ním je aktivita „Chůvička hlídá od 21:40“.",
                      footnote: "iOS nedovolí aplikacím, které na pozadí jen přehrávají zvuk, průběžně měnit aktivitu na zamčené obrazovce. Proto ukazuje hlavně to, že Chůvička hlídá a od kdy.")
                topic("bell.badge", "Když se něco pokazí",
                      "Když vypadne spojení s kamerou, přijde po 20 sekundách upozornění a Chůvička se sama připojí znovu. Kdyby iOS aplikaci ukončil, do 2,5 minuty přijde upozornění „Chůvička přestala hlídat“. Stačí ji znovu otevřít.",
                      footnote: "Upozornění fungují, jen když je povolíte. Aplikaci nezavírejte přejetím nahoru v přepínači aplikací, tím hlídání ukončíte.")
                topic("waveform", "Obraz, nebo jen zvuk",
                      "Přepínač nahoře volí, co hlavní obrazovka ukazuje. Obraz ukazuje živé video z postýlky. Jen zvuk ukazuje jen pokojíček: kruh, který se rozvlní se zvukem, a slovy, co se děje. Video se v tu chvíli vůbec nestahuje.",
                      footnote: "Jen zvuk šetří baterii i Wi-Fi a telefon méně hřeje. Na miminko se můžete kdykoli podívat tlačítkem Nahlédnout do postýlky. Pořídí jednu fotku z kamery, bez živého obrazu.")
                topic("moon.stars", "Noční režim",
                      "Displej zůstane zapnutý, ale téměř černý a na nejnižším jasu. Telefon se sám nezamkne. Obraz se zastaví, zvuk a upozornění běží dál. Když se miminko ozve, vlnovka se rozsvítí. Klepnutím displej probudíte.")
                topic("battery.75", "Baterie a nabíjení",
                      "Nejúspornější je zamčený telefon, kdy běží jen zvuk. Noční režim a zobrazení Jen zvuk spotřebují o něco víc, protože svítí displej. Nejvíc spotřebuje otevřená aplikace se živým obrazem. Na celou noc doporučujeme nabíječku.",
                      footnote: "Spotřebu vašeho telefonu Chůvička měří sama. Teď: \(battery.summary).")
                topic("bell.badge.fill", "Tichý režim",
                      "Chůvička nic nepřehrává, ale dál poslouchá. Když se miminko ozve, přijde upozornění. Hodí se, když nechcete celou noc slyšet šum pokoje. Zapnete ho podržením tlačítka Zvuk.")
                topic("chart.bar.xaxis", "Přehled",
                      "Ukazuje, kdy Chůvička poslouchala a kdy se miminko ozvalo, i s fotkou z kamery. Šedá místa znamenají, že Chůvička neposlouchala. To není totéž co ticho.")
                topic("hand.raised", "Soukromí",
                      "Obraz i zvuk zůstávají ve vaší domácí síti. Nic se neposílá na internet a kamera sama přístup k internetu nemá.")
                topic("calendar.badge.exclamationmark", "Platnost instalace",
                      "Aplikace nainstalovaná z Macu s bezplatným účtem Apple funguje 7 dní. Potom ji v Xcode znovu nainstalujte, nastavení a přehled zůstanou.")
            }
            .navigationTitle("Jak Chůvička funguje")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
        }
    }

    private func topic(_ symbol: String, _ title: String, _ text: String, footnote: String? = nil) -> some View {
        Section {
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
}
