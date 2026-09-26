import Foundation
import Security

/// How the parent reads a camera: through a go2rtc server, or straight from the camera (RTSP).
enum CameraKind: String { case go2rtc, rtsp }

/// The ports of go2rtc. These are the software's defaults, not the developer's setup,
/// so they are not in `HomeDefaults`.
enum Go2rtc {
    static let rtspPort: UInt16 = 8554
    static let apiPort: UInt16 = 1984
}

/// The default port of Home Assistant, for its webhooks.
enum HomeAssistant {
    static let port: UInt16 = 8123
}

/// The common IP cameras, with the RTSP paths of their main and sub streams.
/// A new user picks the brand and types the IP address, the user and the password.
enum CameraBrand: String, CaseIterable, Identifiable {
    case tapo, hikvision, dahua, reolink, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tapo: "Tapo (TP-Link)"
        case .hikvision: "Hikvision"
        case .dahua: "Dahua / Imou"
        case .reolink: "Reolink"
        case .other: "Jiná kamera"
        }
    }

    /// The path of the main stream and of the sub stream. `small` is the sub stream.
    var paths: (main: String, small: String?) {
        switch self {
        case .tapo: ("stream1", "stream2")
        case .hikvision: ("Streaming/Channels/101", "Streaming/Channels/102")
        case .dahua: ("cam/realmonitor?channel=1&subtype=0", "cam/realmonitor?channel=1&subtype=1")
        case .reolink: ("h264Preview_01_main", "h264Preview_01_sub")
        case .other: ("", nil)
        }
    }

    /// The port of the ONVIF service (pan and tilt). Tapo refuses port 80; it answers on 2020.
    /// "Jiná kamera" tries 80: with no answer there, the app shows no aim button.
    var onvifPort: UInt16 {
        switch self {
        case .tapo: 2020
        case .hikvision, .dahua, .other: 80
        case .reolink: 8000
        }
    }

    var hint: String? {
        switch self {
        case .tapo: "Účet kamery vytvoříte v aplikaci Tapo: Kamera → Nastavení → Pokročilé nastavení → Účet kamery. Není to váš účet Tapo."
        case .hikvision, .dahua: "Použijte účet, kterým se přihlašujete do kamery. Zvuk nastavte v kameře na G.711."
        case .reolink: "Reolink posílá zvuk ve formátu AAC, který Chůvička neumí přehrát. Obraz funguje."
        case .other: "Adresu RTSP najdete v návodu ke kameře. Chůvička umí obraz H.264 a zvuk G.711."
        }
    }
}

/// The camera password, in the iOS Keychain: it never goes to the settings file or to a backup.
enum CameraSecret {
    private static let account = "rtsp-password"

    static var password: String {
        get {
            var result: AnyObject?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                        kSecReturnData as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly   // Also at night, locked.
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

extension Settings {
    /// The RTSP address of a camera, with the user and the password in it.
    func rtspURL(small: Bool) -> String {
        let host = rtspHost.trimmingCharacters(in: .whitespaces)
        let path: String
        if rtspBrand == .other {
            // A full address: "rtsp://192.168.0.50:554/live". The user and the password are added.
            var s = rtspCustom.trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix("rtsp://") { s = String(s.dropFirst(7)) }
            return "rtsp://" + credentials + s
        } else {
            let p = rtspBrand.paths
            path = small ? (p.small ?? p.main) : p.main
        }
        return "rtsp://\(credentials)\(host):\(rtspPort)/\(path)"
    }

    private var credentials: String {
        let user = rtspUser.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return "" }
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let u = user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user
        let p = CameraSecret.password.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(u):\(p)@"
    }
}

/// What the guide can change. Settings → Kamera keeps a copy, so "Zrušit" in the guide
/// brings back the working setup exactly as it was.
struct SetupSnapshot {
    let role: Settings.Role
    let source: Settings.Source
    let cameraKind: CameraKind
    let rtspBrand: CameraBrand
    let rtspHost, rtspUser, rtspCustom, password: String
    let rtspPort: Int
    let host, streamMain, streamSmall: String
    let babyName, babyCode: String
    let babyAddresses: [String]
    let babyDirect: String?

    init(_ s: Settings) {
        role = s.role; source = s.source; cameraKind = s.cameraKind; rtspBrand = s.rtspBrand
        rtspHost = s.rtspHost; rtspUser = s.rtspUser; rtspCustom = s.rtspCustom; rtspPort = s.rtspPort
        password = CameraSecret.password
        host = s.host; streamMain = s.streamMain; streamSmall = s.streamSmall
        babyName = s.babyName; babyCode = s.babyCode; babyAddresses = s.babyAddresses; babyDirect = s.babyDirect
    }

    func restore(to s: Settings) {
        s.role = role; s.source = source; s.cameraKind = cameraKind; s.rtspBrand = rtspBrand
        s.rtspHost = rtspHost; s.rtspUser = rtspUser; s.rtspCustom = rtspCustom; s.rtspPort = rtspPort
        if CameraSecret.password != password { CameraSecret.password = password }
        s.host = host; s.streamMain = streamMain; s.streamSmall = streamSmall
        s.babyName = babyName; s.babyCode = babyCode; s.babyAddresses = babyAddresses; s.babyDirect = babyDirect
    }
}
