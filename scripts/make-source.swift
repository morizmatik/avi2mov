// Generates the source clip for the tests in <out>/source.mp4: 20 s, 30 fps, 640x360, AAC sound.
// Every frame carries the binary code of its number (10 squares) and a white marker, so a converted
// file can be checked slot by slot.
// Usage: swift scripts/make-source.swift <out>

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W = 640, H = 360, FPS = 30, SECONDS = 20, SR = 48000
let videoURL = outDir.appendingPathComponent("source.mp4")
try? FileManager.default.removeItem(at: videoURL)

let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoMaxKeyFrameIntervalKey: 60],
])
vIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
])
aIn.expectsMediaDataInRealTime = false
writer.add(vIn); writer.add(aIn)
writer.startWriting(); writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(mSampleRate: Float64(SR), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
    mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var afd: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &afd)

func drawFrame(_ i: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // CG origin is bottom-left; the code row sits at the top of the picture.
    let hue = CGFloat(i / FPS) / CGFloat(SECONDS)
    ctx.setFillColor(CGColor(red: 0.15 + 0.5 * hue, green: 0.12, blue: 0.35 - 0.2 * hue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: H - 80, width: W, height: 80))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 10, y: H - 60, width: 40, height: 40)) // marker: always white in the source
    for b in 0..<10 where (i >> b) & 1 == 1 {
        ctx.fill(CGRect(x: 70 + b * 56, y: H - 60, width: 40, height: 40))
    }
    // progress bar = time inside the source
    ctx.fill(CGRect(x: 0, y: 40, width: W * i / (FPS * SECONDS), height: 20))
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

func audioChunk(_ start: Int, _ n: Int) -> CMSampleBuffer {
    var d = [Float](repeating: 0, count: n * 2)
    for f in 0..<n {
        let t = Double(start + f) / Double(SR)
        let freq = 220.0 + 55.0 * floor(t) // a different pitch every second
        let click = (t - floor(t)) < 0.01 ? 0.6 : 0
        let v = Float(0.3 * sin(2 * .pi * freq * t) + click)
        d[2 * f] = v; d[2 * f + 1] = v
    }
    let bytes = n * 8
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
    d.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: afd!, sampleCount: n,
                                                         presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(SR)),
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

let totalFrames = FPS * SECONDS, totalSamples = SR * SECONDS, chunk = 4800
var vf = 0, af = 0
while vf < totalFrames || af < totalSamples {
    var progressed = false
    if vf < totalFrames, vIn.isReadyForMoreMediaData, Double(vf) / Double(FPS) <= Double(af) / Double(SR) + 0.5 || af >= totalSamples {
        adaptor.append(drawFrame(vf), withPresentationTime: CMTime(value: Int64(vf), timescale: Int32(FPS)))
        vf += 1; progressed = true
    }
    if af < totalSamples, aIn.isReadyForMoreMediaData {
        let n = min(chunk, totalSamples - af)
        aIn.append(audioChunk(af, n)); af += n; progressed = true
    }
    if !progressed { Thread.sleep(forTimeInterval: 0.002) }
}
vIn.markAsFinished(); aIn.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { print("Could not write the source video: \(String(describing: writer.error))"); exit(1) }

print("Source clip: \(videoURL.path)")
