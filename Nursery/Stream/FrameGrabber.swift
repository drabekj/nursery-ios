import CoreImage
import CoreMedia
import UIKit
import VideoToolbox

/// One full frame straight from an IP camera, for Fotka and for the photos of the activity.
/// A camera read directly has no "give me a JPEG" address (go2rtc has one), so this plays the
/// stream for a moment: one short RTSP session until the first keyframe, then TEARDOWN.
///
/// The camera serves only a few sessions per stream path (Tapo: 3), so the caller picks the path
/// that the live connection does not use (`MonitorEngine.liveDetail`).
enum FrameGrabber {
    private static let context = CIContext()

    static func grab(url: String, timeout: Double = 8) async -> UIImage? {
        guard let client = try? RTSPClient(url: url, directCamera: true) else { return nil }
        let found = Found()
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { client.stop() }
        }
        defer { timer.cancel() }
        let key = await withCheckedContinuation { (cont: CheckedContinuation<Keyframe?, Never>) in
            let once = Once()
            // It runs one time, for any end: the keyframe came, the time is up, or an error.
            client.onClose = { _ in
                if once.claim() { cont.resume(returning: found.value) }
            }
            Task {
                do {
                    _ = try await client.start { tracks in
                        guard let video = tracks.first(where: { $0.sdp.kind == .video && $0.sdp.codec == "H264" }) else {
                            client.stop()
                            return
                        }
                        let depacketizer = H264Depacketizer()
                        if let sets = video.sdp.h264ParameterSets {
                            depacketizer.setParameterSets(sps: sets.sps, pps: sets.pps)
                        }
                        client.onPacket = { channel, bytes in
                            guard channel == video.channel, found.value == nil,
                                  let packet = RTPPacket(bytes), let unit = depacketizer.push(packet), unit.isKeyframe,
                                  let sps = depacketizer.sps, let pps = depacketizer.pps else { return }
                            found.value = Keyframe(unit: unit, sps: sps, pps: pps)
                            client.stop()       // TEARDOWN: else the camera counts the session for 65 s.
                        }
                    }
                } catch {
                    if found.value == nil {
                        Log.shared.add("photo from the camera failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                    client.stop()
                }
            }
        }
        guard let key else { return nil }
        return decode(key)
    }

    private struct Keyframe {
        let unit: H264AccessUnit
        let sps: [UInt8]
        let pps: [UInt8]
    }

    /// One keyframe to an image, with VideoToolbox. It needs no other frame.
    private static func decode(_ key: Keyframe) -> UIImage? {
        guard let format = VideoRenderer.makeFormat(sps: key.sps, pps: key.pps),
              let sample = VideoRenderer.makeSample(key.unit, format: format) else { return nil }
        var made: VTDecompressionSession?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                           decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &made) == noErr,
              let session = made else {
            Log.shared.add("photo from the camera: no decoder")
            return nil
        }
        defer { VTDecompressionSessionInvalidate(session) }
        let decoded = Decoded()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { result, _, buffer, _, _ in
            if result == noErr, let buffer { decoded.value = buffer }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, let pixels = decoded.value else {
            Log.shared.add("photo from the camera: decode failed (\(status))")
            return nil
        }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The keyframe, from the RTSP queue.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Keyframe?
        var value: Keyframe? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// The picture, from the decoder's thread.
    private final class Decoded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CVImageBuffer?
        var value: CVImageBuffer? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
