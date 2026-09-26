import AVFoundation
import CoreMedia
import UIKit

/// The view that shows the picture. Its layer is an AVSampleBufferDisplayLayer.
/// The same layer feeds picture in picture, so the app never creates a second one.
final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// It turns H.264 access units into sample buffers, and it sends them to the layer.
/// The caller is on the RTSP queue. The renderer of the layer accepts calls from any thread.
/// All calls come from the RTSP queue, one at a time.
final class VideoRenderer: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private var format: CMVideoFormatDescription?
    private var formatVersion = -1
    private var waitingForKeyframe = true

    /// The size of the picture, from the SPS. It runs on the main thread when the size changes.
    var onSize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    /// It drops the decoder state. The next frame that shows is a keyframe.
    /// It also forgets the format: each connection has a new depacketizer, whose version count
    /// starts again at 0. Without this, a switch from the phone at the baby back to the camera
    /// kept the phone's SPS (both were version 1), and each camera frame failed: a black picture.
    func reset() {
        waitingForKeyframe = true
        format = nil
        formatVersion = -1
        renderer.flush()
    }

    func render(_ unit: H264AccessUnit, depacketizer: H264Depacketizer) {
        if depacketizer.parameterSetVersion != formatVersion {
            guard let sps = depacketizer.sps, let pps = depacketizer.pps else { return }
            format = Self.makeFormat(sps: sps, pps: pps)
            formatVersion = depacketizer.parameterSetVersion
            waitingForKeyframe = true
            if let format {
                let d = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(d.width), height: Int(d.height))
                if size != lastSize {
                    lastSize = size
                    DispatchQueue.main.async { self.onSize?(size) }
                }
            }
        }
        guard let format else { return }

        // After the app returns from the background, the decoder needs a flush.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            reset()
        }
        if waitingForKeyframe {
            guard unit.isKeyframe else { return }
            waitingForKeyframe = false
        }
        guard let sample = Self.makeSample(unit, format: format) else { return }
        renderer.enqueue(sample)
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSample(_ unit: H264AccessUnit, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // AVCC: each NAL unit has a 4-byte length in front, and no start code.
        var avcc = [UInt8]()
        avcc.reserveCapacity(unit.nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in unit.nalUnits {
            let n = UInt32(nal.count)
            avcc += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            avcc += nal
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        // Show each frame at once. This gives the lowest delay for a live picture.
        setAttachments(sample, keyframe: unit.isKeyframe)
        return sample
    }

    private static func setAttachments(_ sample: CMSampleBuffer, keyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if !keyframe {
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }

    /// It shows one still image. The demo mode uses it, for the screenshots.
    func showStill(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        let w = cg.width, h = cg.height
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        Self.setAttachments(sample, keyframe: true)
        renderer.flush()
        renderer.enqueue(sample)
        let size = CGSize(width: w, height: h)
        DispatchQueue.main.async { self.onSize?(size) }
    }
}
