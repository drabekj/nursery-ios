import SwiftUI
import UIKit

/// The screen of the phone at the baby. Before the start: the pairing code and a few choices.
/// While it sends: a dark screen that gives no light in the nursery, and a tap shows the controls.
struct BabyUnitView: View {
    @EnvironmentObject private var unit: BabyUnit
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Group {
            if unit.running {
                BabySendingView()
                    .transition(.opacity)
            } else {
                BabySetupView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: unit.running)
        .task {
            if MonitorEngine.isDemo, UserDefaults.standard.string(forKey: "demoScreen") == "baby-live" {
                await unit.start()
            }
        }
    }
}

// MARK: - Before the start

private struct BabySetupView: View {
    @EnvironmentObject private var unit: BabyUnit
    @EnvironmentObject private var settings: Settings
    @State private var confirmParent = false
    @State private var starting = false

    var body: some View {
        ZStack {
            Theme.skyTop.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    header
                    codeCard
                    optionsCard
                    tips
                    if let error = unit.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.alarm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        starting = true
                        Haptics.firm()
                        Task { await unit.start(); starting = false }
                    } label: {
                        HStack(spacing: 10) {
                            if starting { ProgressView().tint(.black) }
                            Text("Začít vysílat").fontWeight(.semibold)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.moon, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .disabled(starting)
                    Button("Tento telefon je rodičovský") { confirmParent = true }
                        .font(.subheadline)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Používat tento telefon jako rodičovský?", isPresented: $confirmParent, titleVisibility: .visible) {
            Button("Ano, bude hlídat") { settings.role = .parent }
        } message: {
            Text("Chůvička pak na tomto telefonu ukazuje obraz a zvuk z pokojíčku.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Telefon u miminka")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("Tento telefon vysílá obraz a zvuk od postýlky do telefonů rodičů.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var codeCard: some View {
        VStack(spacing: 8) {
            Text("Párovací kód").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(spaced(settings.unitCode))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel("Párovací kód \(settings.unitCode.map(String.init).joined(separator: " "))")
            Text("Na telefonu rodiče: Nastavení → Kamera → Druhý telefon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Nový kód") { settings.unitCode = Settings.newCode() }
                .font(.caption.weight(.semibold))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Název") {
                TextField("Pokojíček", text: $settings.unitName)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
            Divider()
            Picker("Vysílat", selection: $settings.unitVideo) {
                Text("Obraz i zvuk").tag(true)
                Text("Jen zvuk").tag(false)
            }
            .pickerStyle(.segmented)
            Divider()
            // Rarely needed: out of sight until asked for.
            DisclosureGroup("Další volby") {
                VStack(alignment: .leading, spacing: 14) {
                    if settings.unitVideo {
                        LabeledContent("Kamera") {
                            Picker("Kamera", selection: $settings.unitFront) {
                                Text("Zadní").tag(false)
                                Text("Přední").tag(true)
                            }
                            .labelsHidden()
                        }
                        Toggle("Otočit obraz o 180°", isOn: $settings.unitFlip)
                    }
                    Toggle(isOn: $settings.unitDirect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spojení i bez Wi-Fi")
                            Text("Pro místa bez Wi-Fi routeru. Stojí víc baterie, proto je běžně vypnuté.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(18)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 12) {
            tip("bolt.fill", "Připojte nabíječku. Vysílání obrazu přes noc spotřebuje hodně baterie a telefon se trochu zahřeje.")
            tip("iphone.landscape", "Položte telefon naležato, 1–2 metry od postýlky, nikdy ne do ní.")
            if settings.unitVideo {
                tip("lock.open.fill", "Nechte Chůvičku otevřenou a telefon nezamykejte. iOS by jinak zastavil kameru. Zvuk by běžel dál.")
            } else {
                tip("lock.fill", "Jen zvuk funguje i se zamčeným telefonem.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "482913" as "482 913".
private func spaced(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return String(code.prefix(3)) + " " + String(code.suffix(3))
}

// MARK: - While it sends

private struct BabySendingView: View {
    @EnvironmentObject private var unit: BabyUnit
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var battery: BatteryMonitor
    @State private var awake = true
    @State private var preview: UIImage?
    @State private var savedBrightness: CGFloat?
    @State private var sleepTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.moon.opacity(0.2))
                }
                Waveform(history: unit.history, dim: true)
                    .frame(height: 70)
                    .padding(.horizontal, 40)
                    .opacity(0.5)
                Label(statusText, systemImage: unit.parents > 0 ? "dot.radiowaves.left.and.right" : "hourglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(unit.cameraPaused ? Theme.warn.opacity(0.8) : Color.white.opacity(0.3))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer()
                batteryLine
                Text("Klepnutím zobrazíte ovládání")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(.bottom, 20)
            }
            .opacity(awake ? 0 : 1)          // The controls read alone, with nothing behind them.
            if awake {
                controls
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!awake)
        .persistentSystemOverlays(awake ? .automatic : .hidden)
        .contentShape(Rectangle())
        .onTapGesture { wake() }
        .onAppear { wake() }
        .onDisappear { sleepTask?.cancel(); restore() }
        // The brightness is the whole phone's. Give it back when Chůvička leaves the screen.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !awake { dim() }
        }
        .task(id: awake) {
            // While awake, a fresh preview each second helps to aim the phone at the cot.
            guard awake else { return }
            while !Task.isCancelled {
                if let image = await unit.previewFrame() { preview = image }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var statusText: String {
        if unit.cameraPaused { return "Obraz stojí, protože je telefon zamčený. Zvuk se vysílá dál." }
        switch unit.parents {
        case 0: return "\(settings.unitName) · čeká na telefon rodiče"
        case 1: return "\(settings.unitName) · vysílá do 1 telefonu"
        default: return "\(settings.unitName) · vysílá do \(unit.parents) telefonů"
        }
    }

    private var batteryLine: some View {
        HStack(spacing: 6) {
            Image(systemName: battery.charging ? "battery.100.bolt" : "battery.25")
            Text(battery.charging ? battery.summary : "\(battery.summary) · připojte nabíječku")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(battery.charging ? Color.white.opacity(0.22) : Theme.alarm.opacity(0.8))
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if settings.unitVideo {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06))
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 520)
                Text("Náhled. Namiřte telefon na postýlku.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Label(statusText, systemImage: unit.parents > 0 ? "dot.radiowaves.left.and.right" : "hourglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(unit.cameraPaused ? Theme.warn : (unit.parents > 0 ? Theme.calm : Color.white.opacity(0.7)))
                .multilineTextAlignment(.center)
            if unit.parents == 0 {
                // No parent yet: the QR code is the easiest way to pair.
                QRCodeView(text: pairLink.url.absoluteString)
                    .frame(maxWidth: 220)
                Text("Naskenujte telefonem rodiče").font(.headline).foregroundStyle(.white)
            }
            HStack(spacing: 8) {
                Text("Kód").foregroundStyle(.white.opacity(0.5))
                Text(spaced(settings.unitCode)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            }
            .font(.subheadline.weight(.semibold))
            Button {
                Haptics.firm()
                unit.stop()
            } label: {
                Text("Ukončit vysílání").fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 320, minHeight: 50)
                    .background(Theme.alarm.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScale())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { batteryLine.padding(.bottom, 20) }
    }

    private var pairLink: PairLink {
        PairLink(name: BabyUnit.serviceName(settings.unitName), code: settings.unitCode,
                 addresses: Reach.localAddresses().map { "\($0):\(BabyService.port.rawValue)" })
    }

    /// The controls show for 20 s, then the screen goes dark again. With no parent yet, they stay.
    private func wake() {
        withAnimation(.easeOut(duration: 0.3)) { awake = true }
        restore()
        sleepTask?.cancel()
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(20))
            while unit.parents == 0 && !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { awake = false }
            dim()
        }
    }

    private func dim() {
        guard !MonitorEngine.isDemo else { return }
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0.01
    }

    private func restore() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }
}
