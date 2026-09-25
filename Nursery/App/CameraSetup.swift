import Foundation
import Security

/// How the parent reads a camera: through a go2rtc server, or straight from the camera (RTSP).
enum CameraKind: String { case go2rtc, rtsp }

/// The common IP cameras, with the RTSP paths of their main and small streams.
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

    /// The path of the main stream and of the small stream.
    var paths: (main: String, small: String?) {
        switch self {
        case .tapo: ("stream1", "stream2")
        case .hikvision: ("Streaming/Channels/101", "Streaming/Channels/102")
        case .dahua: ("cam/realmonitor?channel=1&subtype=0", "cam/realmonitor?channel=1&subtype=1")
        case .reolink: ("h264Preview_01_main", "h264Preview_01_sub")
        case .other: ("", nil)
        }
    }

    var hint: String? {
        switch self {
        case .tapo: "Účet kamery vytvoříte v aplikaci Tapo: Kamera → Nastavení → Pokročilé nastavení → Účet kamery."
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
