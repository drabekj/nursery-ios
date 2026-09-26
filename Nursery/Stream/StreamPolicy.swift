import Foundation

/// Which stream to ask for: the detail (main) stream or the everyday (sub) stream.
/// There is no setting for it. Pure, so the tests can run it.
enum StreamPolicy {
    struct Inputs: Equatable {
        /// The screen shows the picture big: zoomed in, full screen, landscape, or an iPad.
        var wantsDetail: Bool
        /// No screen shows the picture: the sound view, Night mode, the background, the lock screen.
        var soundOnly: Bool
        /// The thermal state is serious or critical.
        var thermalHot: Bool
        /// Low Power Mode is on.
        var lowPower: Bool
        var detailStream: String
        var everydayStream: String
    }

    /// True when the detail stream is worth its cost. It has many times the pixels of the
    /// everyday stream, and it keeps the Wi-Fi and the decoder busy.
    static func detail(_ i: Inputs) -> Bool {
        i.wantsDetail && !i.soundOnly && !i.thermalHot && !i.lowPower && i.detailStream != i.everydayStream
    }

    static func stream(_ i: Inputs) -> String { detail(i) ? i.detailStream : i.everydayStream }
}
