import SwiftUI
import UIKit

// MARK: - The zoomable picture

/// The digital zoom. It uses a UIScrollView, so the pinch, the bounce, and the momentum
/// are the same as in Photos. It changes the view on this telephone only. The camera does not move.
final class ZoomState: ObservableObject {
    @Published var scale: CGFloat = 1
    fileprivate weak var scrollView: UIScrollView?

    func reset() { scrollView?.setZoomScale(1, animated: true) }
}

struct ZoomableVideo: UIViewRepresentable {
    let videoView: VideoLayerView
    let zoom: ZoomState
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        scroll.decelerationRate = .fast
        scroll.content = videoView
        scroll.addSubview(videoView)          // This moves the one video view here.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
        zoom.scrollView = scroll
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        if videoView.superview !== scroll {
            scroll.content = videoView
            scroll.addSubview(videoView)
            scroll.setNeedsLayout()
        }
        zoom.scrollView = scroll
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let zoom: ZoomState
        var onTap: (() -> Void)?
        init(zoom: ZoomState) { self.zoom = zoom }

        @objc func singleTap(_ g: UITapGestureRecognizer) { onTap?() }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomScrollView)?.content }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let s = scrollView.zoomScale
            if abs(s - zoom.scale) > 0.05 || s == 1 { zoom.scale = s }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // Zoom to 2.5× at the finger.
                let p = g.location(in: (scroll as? ZoomScrollView)?.content)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
            Haptics.tap()
        }
    }
}

final class ZoomScrollView: UIScrollView {
    weak var content: UIView?
    private var lastBounds = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content, bounds.size != lastBounds else { return }
        // A new size (for example a rotation): start again at 1×.
        lastBounds = bounds.size
        setZoomScale(1, animated: false)
        content.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}

// MARK: - The waveform

/// The last 6 seconds of sound, as mirrored bars. The newest bar is at the right.
/// A parent sees a cry as a row of tall warm bars, also with the phone on silent.
struct Waveform: View {
    let history: [Float]
    var dim = false

    var body: some View {
        Canvas { ctx, size in
            let n = history.count
            guard n > 0 else { return }
            let step = size.width / CGFloat(n)
            let barWidth = max(2, step * 0.55)
            let mid = size.height / 2
            for (i, v) in history.enumerated() {
                let h = max(barWidth, CGFloat(v) * size.height)
                let rect = CGRect(x: CGFloat(i) * step + (step - barWidth) / 2, y: mid - h / 2, width: barWidth, height: h)
                // The older bars fade. This gives a sense of time.
                let age = Double(i) / Double(n)
                let opacity = (dim ? 0.45 : 1) * (0.35 + 0.65 * age)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(Theme.level(v).opacity(opacity)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Sound level")
        .accessibilityValue(Text(Waveform.word(for: history.last ?? 0)))
    }

    static func word(for v: Float) -> String { RoomLevel(v).title }
}

// MARK: - The repeat button

/// A button that acts on the press, and again at each interval while the finger stays.
struct RepeatButton<Label: View>: View {
    let interval: TimeInterval
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        label(pressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        fire()
                        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                            DispatchQueue.main.async { fire() }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func fire() {
        Haptics.tap()
        action()
    }
}
