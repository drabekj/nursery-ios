import AVFoundation
import SwiftUI
import UIKit

/// The first-run guide. The benchmark: a mother with a newborn in one arm sets it up with the other.
/// So: one question per screen, one big button, everyday words, and a live check at each step.
/// Technical words (RTSP, go2rtc) appear only behind "Pokročilé".
struct OnboardingView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var unit: BabyUnit
    let finish: () -> Void

    enum Step: Hashable {
        case welcome, role
        case babySetup, babyReady
        case source, pair, cameraBrand, cameraDetails, go2rtc, test, remote, alerts
    }

    @State private var path: [Step] = []
    @State private var current: Step = .welcome

    var body: some View {
        ZStack {
            Theme.skyTop.ignoresSafeArea()
            page(current)
                .id(current)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: current)
        .onAppear(perform: applyDemo)
    }

    private func go(_ next: Step) {
        Haptics.tap()
        path.append(current)
        current = next
    }

    private func back() {
        guard let last = path.popLast() else { return }
        current = last
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage { go(.role) }
        case .role: RolePage(back: back) { baby in go(baby ? .babySetup : .source) }
        case .babySetup: BabySetupPage(back: back) { go(.babyReady) }
        case .babyReady: BabyReadyPage(back: back) {
            settings.role = .baby
            settings.onboarded = true
            Task { await unit.start() }
        }
        case .source: SourcePage(back: back) { choice in
            switch choice {
            case .phone: go(.pair)
            case .camera: go(.cameraBrand)
            case .go2rtc: go(.go2rtc)
            }
        }
        case .pair: PairPage(back: back) { go(.test) }
        case .cameraBrand: CameraBrandPage(back: back) { go(.cameraDetails) }
        case .cameraDetails: CameraDetailsPage(back: back) { go(.test) }
        case .go2rtc: Go2rtcPage(back: back) { go(.test) }
        case .test: TestPage(back: back) { go(.remote) }
        case .remote: RemotePage(back: back) { go(.alerts) }
        case .alerts: AlertsPage(back: back) {
            settings.role = .parent
            settings.onboarded = true
            finish()
        }
        }
    }

    /// `-demoScreen wizard-…` opens a step, for the screenshots.
    private func applyDemo() {
        guard MonitorEngine.isDemo else { return }
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "wizard-role": current = .role
        case "wizard-source": current = .source
        case "wizard-pair": current = .pair
        case "wizard-camera": current = .cameraDetails
        case "wizard-test": current = .test
        case "wizard-remote": current = .remote
        case "wizard-baby": current = .babyReady
        default: break
        }
    }
}

// MARK: - The frame of each page

private struct Page<Content: View>: View {
    var back: (() -> Void)?
    let title: String
    var subtitle: String?
    var primary: String?
    var primaryEnabled = true
    var primaryAction: () -> Void = {}
    var secondary: String?
    var secondaryAction: () -> Void = {}
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let back {
                    Button(action: back) {
                        Label("Zpět", systemImage: "chevron.left").font(.body.weight(.semibold))
                    }
                    .tint(Theme.accent)
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 10) {
                if let primary {
                    Button(action: primaryAction) {
                        Text(primary).font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(Theme.moon.opacity(primaryEnabled ? 1 : 0.4),
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .disabled(!primaryEnabled)
                }
                if let secondary {
                    Button(secondary, action: secondaryAction)
                        .font(.body.weight(.medium))
                        .tint(Theme.accent)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
        }
    }
}

/// A big choice card: an icon, a title, one line of help.
private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Theme.moon.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    if let badge {
                        Text(badge).font(.caption.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.moon, in: Capsule())
                    }
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(PressScale())
    }
}

/// A numbered instruction: what to do on the other phone.
private struct Steps: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(i + 1)").font(.headline).foregroundStyle(.black)
                        .frame(width: 30, height: 30).background(Theme.moon, in: Circle())
                    Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A live check: waiting, done, or a problem with what to do.
private struct CheckRow: View {
    let title: String
    let step: ConnectionTest.Step
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch step {
                case .waiting: ProgressView()
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.calm)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn)
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if case .failed(let why) = step, !why.isEmpty {
                    Text(why).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The start

private struct WelcomePage: View {
    let next: () -> Void
    var body: some View {
        Page(title: "Chůvička", subtitle: "Uslyšíte a uvidíte miminko, i když jste ve vedlejší místnosti.",
             primary: "Začít", primaryAction: next) {
            Image("Artwork").resizable().scaledToFit()
                .frame(maxWidth: 200)
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                benefit("waveform", "Živý zvuk i obraz, i se zamčeným telefonem")
                benefit("bell.badge.fill", "Upozornění, když se miminko ozve nebo když vypadne spojení")
                benefit("lock.shield.fill", "Soukromé: nic nejde přes cizí server")
            }
            Text("Nastavení zabere asi dvě minuty.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 32)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RolePage: View {
    let back: () -> Void
    let choose: (_ baby: Bool) -> Void
    var body: some View {
        Page(back: back, title: "Co bude dělat tento telefon?") {
            ChoiceCard(symbol: "figure.and.child.holdinghands", title: "Hlídat miminko",
                       subtitle: "Na tomto telefonu budete miminko slyšet a vidět.") { choose(false) }
            ChoiceCard(symbol: "iphone.gen3.radiowaves.left.and.right", title: "Být u miminka",
                       subtitle: "Tento telefon postavíte k postýlce. Poslouží jako kamera. Hodí se starší telefon.") { choose(true) }
        }
    }
}

// MARK: - The phone at the baby

private struct BabySetupPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    var body: some View {
        Page(back: back, title: "Jak se jmenuje pokojíček?", subtitle: "Tento název uvidíte na telefonu rodiče.",
             primary: "Pokračovat", primaryAction: next) {
            TextField("Pokojíček", text: $settings.unitName)
                .font(.title2)
                .padding(16)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .submitLabel(.done)
            Text("Co má telefon posílat?").font(.headline)
            Picker("Posílat", selection: $settings.unitVideo) {
                Text("Obraz i zvuk").tag(true)
                Text("Jen zvuk").tag(false)
            }
            .pickerStyle(.segmented)
            Text(settings.unitVideo ? "Chůvičku na tomto telefonu nechte otevřenou, jinak iOS kameru zastaví."
                                    : "Jen zvuk funguje i se zamčeným telefonem a šetří baterii.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct BabyReadyPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let start: () -> Void
    var body: some View {
        Page(back: back, title: "Skoro hotovo", subtitle: "Až klepnete na Začít vysílat, telefon ukáže QR kód.",
             primary: "Začít vysílat", primaryAction: start) {
            Steps(items: [
                "Položte telefon 1–2 metry od postýlky, nejlépe naležato. Nikdy ne do postýlky.",
                "Připojte nabíječku.",
                "Povolte mikrofon\(settings.unitVideo ? " a kameru" : ""), až se telefon zeptá.",
                "Na svém telefonu otevřete Chůvičku a naskenujte QR kód z tohoto telefonu.",
            ])
        }
    }
}

// MARK: - The parent: where the picture comes from

private enum SourceChoice { case phone, camera, go2rtc }

private struct SourcePage: View {
    let back: () -> Void
    let choose: (SourceChoice) -> Void
    var body: some View {
        Page(back: back, title: "Odkud bude obraz a zvuk?", secondary: "Pokročilé: server go2rtc",
             secondaryAction: { choose(.go2rtc) }) {
            ChoiceCard(symbol: "iphone.gen3", title: "Druhý telefon", subtitle: "Starý telefon postavíte k postýlce. Nejjednodušší.",
                       badge: "Doporučeno") { choose(.phone) }
            ChoiceCard(symbol: "web.camera", title: "Mám IP kameru", subtitle: "Tapo, Hikvision, Dahua a další.") { choose(.camera) }
        }
    }
}

private struct PairPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    @State private var scanning = false
    @State private var manual = false
    @State private var cameraDenied = false

    var body: some View {
        Page(back: back, title: "Naskenujte QR kód z druhého telefonu",
             primary: "Naskenovat QR kód", primaryAction: scan,
             secondary: "Zadat kód ručně", secondaryAction: { manual = true }) {
            Steps(items: [
                "Na druhém telefonu nainstalujte a otevřete Chůvičku. Může to být iPhone i Android.",
                "Zvolte Být u miminka a klepněte na Začít vysílat.",
                "Telefon ukáže QR kód. Naskenujte ho tady.",
            ])
            if cameraDenied {
                Label("Chůvička nemá přístup k fotoaparátu. Povolte ho v Nastavení iPhonu, nebo zadejte kód ručně.",
                      systemImage: "camera.fill").font(.subheadline).foregroundStyle(Theme.warn)
            }
        }
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                QRScanner { link in
                    link.apply(to: settings)
                    scanning = false
                    next()
                }
                .ignoresSafeArea()
                Text("Namiřte na QR kód na druhém telefonu")
                    .font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 40)
            }
            .overlay(alignment: .topTrailing) {
                Button("Zrušit") { scanning = false }.font(.headline).tint(.white).padding(20)
            }
            .presentationBackground(.black)
        }
        .sheet(isPresented: $manual) {
            NavigationStack {
                PairingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Hotovo") { manual = false; if !settings.babyName.isEmpty { next() } }
                        }
                    }
            }
        }
    }

    private func scan() {
        Task {
            if await AVCaptureDeviceAccess.request() { scanning = true } else { cameraDenied = true }
        }
    }
}

private enum AVCaptureDeviceAccess {
    static func request() async -> Bool {
        if MonitorEngine.isDemo { return false }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}

// MARK: - The parent: an IP camera

private struct CameraBrandPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    var body: some View {
        Page(back: back, title: "Jakou máte kameru?") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(CameraBrand.allCases) { brand in
                    Button {
                        settings.rtspBrand = brand
                        next()
                    } label: {
                        Text(brand.title).font(.headline).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
                    }
                    .buttonStyle(PressScale())
                }
            }
        }
    }
}

private struct CameraDetailsPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    @State private var password = CameraSecret.password

    var body: some View {
        Page(back: back, title: settings.rtspBrand.title, subtitle: settings.rtspBrand.hint,
             primary: "Vyzkoušet", primaryEnabled: ready, primaryAction: {
                CameraSecret.password = password
                settings.cameraKind = .rtsp
                settings.source = .camera
                next()
             }) {
            VStack(spacing: 12) {
                if settings.rtspBrand == .other {
                    field("Adresa RTSP", "192.168.0.50:554/live", text: $settings.rtspCustom, keyboard: .URL)
                } else {
                    field("IP adresa kamery", "například 192.168.0.50", text: $settings.rtspHost, keyboard: .numbersAndPunctuation)
                    Text("Najdete ji v aplikaci kamery, v informacích o zařízení.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                field("Uživatel", "uživatel účtu kamery", text: $settings.rtspUser, keyboard: .default)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Heslo").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    SecureField("heslo účtu kamery", text: $password)
                        .textContentType(.password)
                        .font(.title3)
                        .padding(16)
                        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var ready: Bool {
        settings.rtspBrand == .other ? !settings.rtspCustom.isEmpty : !settings.rtspHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func field(_ title: String, _ prompt: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .font(.title3)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(16)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct Go2rtcPage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    var body: some View {
        Page(back: back, title: "Server go2rtc", subtitle: "Pro pokročilé: obraz čte počítač v síti a Chůvička ho čte z něj.",
             primary: "Vyzkoušet", primaryAction: {
                settings.cameraKind = .go2rtc
                settings.source = .camera
                next()
             }) {
            VStack(spacing: 12) {
                row("Adresa serveru", text: $settings.host)
                row("Hlavní stream", text: $settings.streamMain)
                row("Malý stream (pro zvuk a fotky)", text: $settings.streamSmall)
            }
        }
    }

    private func row(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(.title3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(16)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - The test

private struct TestPage: View {
    @EnvironmentObject private var settings: Settings
    @StateObject private var test = ConnectionTest()
    let back: () -> Void
    let next: () -> Void
    @State private var slow = false

    var body: some View {
        Page(back: back, title: test.passed ? "Hotovo, funguje to!" : (test.running ? "Zkouším spojení…" : "Něco nevyšlo"),
             subtitle: test.passed ? "\(name): obraz i zvuk k vám dorazí." : nil,
             primary: test.passed ? "Pokračovat" : (test.running ? nil : "Zkusit znovu"),
             primaryAction: { test.passed ? next() : run() },
             secondary: !test.passed && !test.running ? "Zpět a upravit" : nil, secondaryAction: back) {
            VStack(alignment: .leading, spacing: 16) {
                CheckRow(title: "Spojení", step: test.connection)
                CheckRow(title: "Obraz", step: test.picture)
                CheckRow(title: "Zvuk", step: test.sound)
            }
            .padding(18)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if slow && test.running {
                Text(settings.source == .phone
                     ? "Trvá to dlouho? Zkontrolujte, že druhý telefon vysílá a že jsou oba na stejné Wi-Fi."
                     : "Trvá to dlouho? Zkontrolujte, že je kamera zapnutá a na stejné Wi-Fi.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: run)
    }

    private var name: String { settings.source == .phone ? settings.babyName : "Kamera" }

    private func run() {
        slow = false
        test.run(settings: settings, wantsPicture: true)
        Task {
            try? await Task.sleep(for: .seconds(10))
            slow = true
        }
    }
}

// MARK: - Away from home

private struct RemotePage: View {
    @EnvironmentObject private var settings: Settings
    let back: () -> Void
    let next: () -> Void
    @State private var setUp = false
    @State private var hereOK = false
    @State private var otherOK = false

    var body: some View {
        Page(back: back, title: "Dívat se i mimo domov?", subtitle: "Třeba z práce nebo od babičky.",
             primary: setUp ? "Pokračovat" : "Ano, nastavit", primaryAction: { if setUp { next() } else { setUp = true } },
             secondary: setUp ? nil : "Teď ne", secondaryAction: next) {
            Text("Stačí bezplatná aplikace Tailscale. Bezpečně a šifrovaně propojí vaše telefony, obraz nejde přes cizí server. Nastavíte ji jednou.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            if setUp {
                VStack(alignment: .leading, spacing: 18) {
                    checklistRow("Tailscale v tomto telefonu", ok: hereOK,
                                 help: "Nainstalujte Tailscale, přihlaste se a zapněte ho.") {
                        Link("Stáhnout Tailscale", destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!)
                            .font(.subheadline.weight(.semibold)).tint(Theme.accent)
                    }
                    other
                }
                .padding(18)
                .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                Text("Doma se Chůvička připojuje přímo. Tailscale použije sama, až budete pryč.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .task(id: setUp) {
            guard setUp else { return }
            while !Task.isCancelled {
                hereOK = MonitorEngine.isDemo || Reach.localAddresses().contains(where: Reach.isTailscale)
                otherOK = await otherCheck()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var other: some View {
        switch (settings.source, settings.cameraKind) {
        case (.phone, _):
            checklistRow("Tailscale v telefonu u miminka", ok: otherOK,
                         help: "Nainstalujte Tailscale i na telefon u miminka, přihlaste se stejným účtem a jednou se k němu připojte doma.") { EmptyView() }
        case (.camera, .go2rtc):
            checklistRow("Server přes Tailscale", ok: otherOK, help: "Zadejte název nebo adresu serveru v Tailscale.") {
                TextField("například raspberrypi", text: $settings.remoteHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case (.camera, .rtsp):
            Text("Kamera sama Tailscale spustit neumí. Mimo domov ji uvidíte, jen když obraz poputuje přes druhý telefon nebo přes server go2rtc.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func otherCheck() async -> Bool {
        if MonitorEngine.isDemo { return true }
        switch (settings.source, settings.cameraKind) {
        case (.phone, _): return settings.babyAddresses.contains { Reach.split($0).map { Reach.isTailscale($0.host) } ?? false }
        case (.camera, .go2rtc):
            let host = settings.trimmedRemoteHost
            guard !host.isEmpty else { return false }
            return await Reach.canConnect(host: host, port: Go2rtc.rtspPort, timeout: 2)
        case (.camera, .rtsp): return false
        }
    }

    private func checklistRow<Extra: View>(_ title: String, ok: Bool, help: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(ok ? Theme.calm : Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                if !ok { Text(help).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
        }
    }
}

// MARK: - The alerts

private struct AlertsPage: View {
    let back: () -> Void
    let done: () -> Void
    var body: some View {
        Page(back: back, title: "Upozornění", subtitle: "Chůvička vás upozorní, když se miminko ozve nebo když vypadne spojení. I se zamčeným telefonem.",
             primary: "Povolit a dokončit", primaryAction: {
                if !MonitorEngine.isDemo { NurseryAlerts.requestPermission() }
                UserDefaults.standard.set(true, forKey: "alertOfferShown")
                done()
             }, secondary: "Dokončit bez upozornění", secondaryAction: done) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 72)).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}
