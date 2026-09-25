@preconcurrency import AVFoundation
import CoreImage
import os
import VideoToolbox

/// The camera and the microphone of the iPhone at the baby.
///
/// - The picture: 1280×720 at 15 frames per second, encoded to H.264 by the hardware encoder.
///   It encodes only while a parent receives, so a phone that nobody watches stays cool.
/// - The sound: the microphone at 8 kHz, as G.711 A-law in 20 ms packets. That is the format
///   of the Tapo camera, so the parent app plays it with the same code.
///
/// iOS stops the camera when the phone locks or the app goes to the background.
/// The microphone continues (the app has the audio background mode).
final class BabyCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let server: BabyServer
    private let videoQueue = DispatchQueue(label: "nursery.baby.video", qos: .userInitiated)

    // The picture. All on videoQueue.
    private let session = AVCaptureSession()
    private var compression: VTCompressionSession?
    private var forceKeyframe = true
    private var encoding = false
    private var frameWaiters: [@Sendable (Data?) -> Void] = []
    private lazy var ciContext = CIContext()

    // The sound. All on the audio tap thread, after start.
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
    private var pending: [Int16] = []
    private var audioTimestamp = UInt32.random(in: 0...UInt32.max)

    /// The loudest level since the last read, 0...1. The screen reads it 10 times a second.
    let peak = OSAllocatedUnfairLock<Float>(initialState: 0)

    init(server: BabyServer) {
        self.server = server
    }

    // MARK: The picture

    func startVideo(front: Bool, flipped: Bool) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else {
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.automaticallyConfiguresApplicationAudioSession = false   // The microphone has its own engine.
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CaptureError.noCamera }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CaptureError.noCamera }
        session.addOutput(output)
        // The phone lies on its side. 180° turns the picture if the phone lies the other way round.
        if let connection = output.connection(with: .video) {
            let angle: CGFloat = flipped ? 180 : 0
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        session.commitConfiguration()

        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        // A dark nursery: the camera may use a longer exposure.
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.unlockForConfiguration()

        try makeEncoder(width: 1280, height: 720)
        videoQueue.async { self.session.startRunning() }      // It blocks. Not on the main thread.
    }

    func setEncoding(_ on: Bool) {
        videoQueue.async {
            if on && !self.encoding { self.forceKeyframe = true }
            self.encoding = on
        }
    }

    func requestKeyframe() {
        videoQueue.async { self.forceKeyframe = true }
    }

    /// The next camera frame as a JPEG. Nil after 3 s, for example when the phone is locked.
    func requestFrame(_ done: @escaping @Sendable (Data?) -> Void) {
        videoQueue.async {
            self.frameWaiters.append(done)
            self.videoQueue.asyncAfter(deadline: .now() + 3) {
                guard !self.frameWaiters.isEmpty else { return }
                let waiting = self.frameWaiters
                self.frameWaiters = []
                waiting.forEach { $0(nil) }
            }
        }
    }

    private func makeEncoder(width: Int32, height: Int32) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height,
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw CaptureError.noEncoder }
        let set = { (key: CFString, value: CFTypeRef) in VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)      // No B-frames: less delay.
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 1_500_000))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 15))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(session)
        compression = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !frameWaiters.isEmpty {
            let jpeg = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: pixels),
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
            let waiting = frameWaiters
            frameWaiters = []
            waiting.forEach { $0(jpeg) }
        }
        guard encoding, let compression else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        VTCompressionSessionEncodeFrame(compression, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.encoded(sample)
        }
    }

    private func encoded(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        var sps: [UInt8]?, pps: [UInt8]?
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            sps = Self.parameterSet(format, 0, &lengthSize)
            pps = Self.parameterSet(format, 1, &lengthSize)
        }

        // AVCC: each NAL unit has a big-endian length in front, not a start code.
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr else { return }
        var nals: [[UInt8]] = []
        var i = 0
        let n = Int(lengthSize)
        while i + n <= size {
            var length = 0
            for k in 0..<n { length = length << 8 | Int(bytes[i + k]) }
            i += n
            guard length > 0, i + length <= size else { break }
            nals.append(Array(bytes[i..<i + length]))
            i += length
        }
        guard !nals.isEmpty else { return }

        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 90_000, method: .default)
        let timestamp = UInt32(truncatingIfNeeded: pts.value)
        server.sendVideo(nals: nals, timestamp: timestamp, keyframe: keyframe,
                         sps: keyframe ? sps : nil, pps: keyframe ? pps : nil)
    }

    private static func parameterSet(_ format: CMFormatDescription, _ index: Int, _ lengthSize: inout Int32) -> [UInt8]? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &lengthSize)
        guard status == noErr, let pointer else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }

    // MARK: The sound

    func startAudio() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw CaptureError.noMicrophone
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// After a phone call or an interruption, the engine must start again.
    func restartAudio() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { Log.shared.add("baby microphone: \(error.localizedDescription)") }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))

        while pending.count >= 160 {
            let chunk = pending[0..<160]
            var sum: Float = 0
            var packet = [UInt8](repeating: 0, count: 160)
            for (k, s) in chunk.enumerated() {
                packet[k] = G711.encodeALaw(s)
                let f = Float(s) / 32768
                sum += f * f
            }
            pending.removeFirst(160)
            let level = LiveAudioPlayer.level(fromRMS: sqrtf(sum / 160))
            peak.withLock { $0 = max($0, level) }
            server.sendAudio(packet, timestamp: audioTimestamp)
            audioTimestamp &+= 160
        }
    }

    // MARK: Stop

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        videoQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            if let c = self.compression { VTCompressionSessionInvalidate(c) }
            self.compression = nil
            let waiting = self.frameWaiters
            self.frameWaiters = []
            waiting.forEach { $0(nil) }
        }
    }

    enum CaptureError: LocalizedError {
        case noCamera, noEncoder, noMicrophone
        var errorDescription: String? {
            switch self {
            case .noCamera: "Kameru se nepodařilo spustit."
            case .noEncoder: "Kódování obrazu se nepodařilo spustit."
            case .noMicrophone: "Mikrofon se nepodařilo spustit."
            }
        }
    }
}
