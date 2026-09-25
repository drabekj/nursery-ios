import SwiftUI
import UIKit

// Liquid Glass on iOS 26, and a material on iOS 17 and 18.
// The `#if compiler` guard lets an older Xcode (without the iOS 26 SDK) still build the app.

extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.liquidGlass(interactive: interactive, tint: tint), in: shape)
        } else {
            self.materialFallback(in: shape, tint: tint)
        }
        #else
        self.materialFallback(in: shape, tint: tint)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    fileprivate static func liquidGlass(interactive: Bool, tint: Color?) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    fileprivate func materialFallback<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.35), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Glass shapes near each other merge and move as one on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// It turns the screen. A button can then give a full-screen picture, as in Photos.
enum Orientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Log.shared.add("rotation refused: \(error.localizedDescription)")
        }
    }
}

/// The share sheet of the system, for a snapshot.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// An image for `.sheet(item:)`.
struct SharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
