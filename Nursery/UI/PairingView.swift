import SwiftUI

/// On the parent: find the iPhone at the baby, and pair with its code.
struct PairingView: View {
    @EnvironmentObject private var settings: Settings
    @StateObject private var browser = BabyBrowser()
    @State private var picking: String?
    @State private var code = ""

    var body: some View {
        List {
            if !settings.babyName.isEmpty {
                Section {
                    LabeledContent("Spárováno s") { Text(settings.babyName) }
                    Button("Zrušit spárování", role: .destructive) {
                        settings.babyName = ""
                        settings.babyCode = ""
                    }
                }
            }

            Section {
                ForEach(browser.names, id: \.self) { name in
                    Button {
                        code = ""
                        picking = name
                    } label: {
                        HStack {
                            Label(name, systemImage: "iphone.gen3.radiowaves.left.and.right")
                                .foregroundStyle(.primary)
                            Spacer()
                            if name == settings.babyName {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                if browser.names.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Hledám telefon u miminka…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Telefony u miminka v okolí")
            } footer: {
                if let failed = browser.failed { Text(failed).foregroundStyle(Theme.alarm) }
            }

            Section("Jak na to") {
                step(1, "Na druhém telefonu (iPhonu nebo Androidu) nainstalujte Chůvičku a otevřete Nastavení → Použít jako telefon u miminka.")
                step(2, "Položte ho k postýlce, nejlépe naležato a 1–2 metry od miminka, a připojte nabíječku.")
                step(3, "Klepněte tady na jeho název a zadejte šestimístný kód, který ukazuje.")
            }

            Section {
                Text("Obraz a zvuk jdou přímo z telefonu do telefonu, přes domácí Wi-Fi, nebo napřímo, když Wi-Fi není. Nic neodchází na internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Telefon u miminka")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .alert("Párovací kód", isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            TextField("6 číslic", text: $code)
                .keyboardType(.numberPad)
            Button("Spárovat") {
                if let name = picking {
                    settings.babyCode = code.filter(\.isNumber)
                    settings.babyName = name
                    settings.source = .phone
                }
                picking = nil
            }
            Button("Zrušit", role: .cancel) { picking = nil }
        } message: {
            Text("Zadejte kód, který ukazuje iPhone „\(picking ?? "")“.")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Theme.moon, in: Circle())
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
