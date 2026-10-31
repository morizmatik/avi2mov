// Builds test AVI files from <dir>/source.mp4 (frames carry a binary number), and next to each one
// what the conversion must produce (<name>.expect.json: the frame number in every slot, sound).
//   A mjpeg_pcm.avi      MJPEG + 16-bit PCM, all 600 frames
//   B mjpeg_nodht.avi    MJPEG without Huffman tables, frame 10 dropped (an empty chunk)
//   C h264_bframes.avi   H.264 Annex B with B-frames (decoding order) + AAC
//   D rgb24.avi          uncompressed 24-bit RGB, 320x180
//   E h264_avc1.avi      H.264 avc1 (avcC in the header, NAL lengths) + float PCM
// Usage: swift scripts/make-avi.swift <dir with source.mp4>

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let src = dir.appendingPathComponent("source.mp4")

// MARK: source frames and audio

func readFrames(limit: Int, scale: CGFloat = 1) throws -> [CGImage] {
    let asset = AVURLAsset(url: src)
    let track = asset.tracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var imgs: [CGImage] = []
    let ctx = CIContext()
    while imgs.count < limit, let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        var ci = CIImage(cvPixelBuffer: pb)
        if scale != 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        imgs.append(ctx.createCGImage(ci, from: ci.extent)!)
    }
    return imgs
}

func readPCM(seconds: Double) throws -> [Float] { // interleaved stereo 48 kHz
    let asset = AVURLAsset(url: src)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .audio)[0], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(out); reader.startReading()
    var s: [Float] = []
    while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        let n = CMSampleBufferGetNumSamples(sb)
        var tmp = [Float](repeating: 0, count: n * 2)
        tmp.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!) }
        s += tmp
        if Double(s.count / 2) >= seconds * 48000 { break }
    }
    return Array(s.prefix(Int(seconds * 48000) * 2))
}

func jpeg(_ img: CGImage) -> Data {
    let d = NSMutableData()
    let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return d as Data
}

/// Removes every DHT segment, like Motion-JPEG from some cameras.
func stripDHT(_ j: Data) -> Data {
    var b = [UInt8](j), i = 2
    while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
        let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
        if b[i + 1] == 0xC4 { b.removeSubrange(i..<(i + 2 + len)) } else { i += 2 + len }
    }
    return Data(b)
}

// MARK: AVI writer

func le32(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 4) }
func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
func cc(_ s: String) -> Data { s.data(using: .ascii)! }
func cat(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
func chunk(_ id: String, _ body: Data) -> Data { cc(id) + le32(body.count) + body + (body.count % 2 == 1 ? Data([0]) : Data()) }
func list(_ t: String, _ body: Data) -> Data { chunk("LIST", cc(t) + body) }

struct AudioSpec { let tag: Int; let ch: Int; let sr: Int; let align: Int; let bits: Int; let avg: Int; let extra: Data; let scale: Int; let rate: Int; let chunks: [Data] }

func writeAVI(_ name: String, w: Int, h: Int, fps: Int, codec: String, compression: UInt32, bitCount: Int, videoExtra: Data = Data(),
              frames: [Data], audio: AudioSpec?, topDown: Bool = false) throws {
    let strhV = cat([cc("vids"), cc(codec), le32(0), le16(0), le16(0), le32(0), le32(1), le32(fps), le32(0), le32(frames.count),
                     le32(1 << 20), le32(-1), le32(0), le16(0), le16(0), le16(w), le16(h)])
    var comp = compression.littleEndian
    let bih = cat([le32(40 + videoExtra.count), le32(w), le32(topDown ? -h : h), le16(1), le16(bitCount), Data(bytes: &comp, count: 4),
                   le32(w * h * 3), le32(0), le32(0), le32(0), le32(0), videoExtra])
    var hdrlBody = chunk("avih", cat([le32(1_000_000 / fps), le32(0), le32(0), le32(0), le32(frames.count), le32(0), le32(audio == nil ? 1 : 2),
                                      le32(1 << 20), le32(w), le32(h), Data(count: 16)]))
    hdrlBody += list("strl", chunk("strh", strhV) + chunk("strf", bih))
    var movi = Data()
    for f in frames { movi += chunk("00dc", f) }
    if let a = audio {
        let strhA = cat([cc("auds"), Data(count: 4), le32(0), le16(0), le16(0), le32(0), le32(a.scale), le32(a.rate), le32(0),
                         le32(a.chunks.count), le32(1 << 16), le32(-1), le32(a.align), Data(count: 8)])
        let wfx = cat([le16(a.tag), le16(a.ch), le32(a.sr), le32(a.avg), le16(a.align), le16(a.bits), le16(a.extra.count), a.extra])
        hdrlBody += list("strl", chunk("strh", strhA) + chunk("strf", wfx))
        for c in a.chunks { movi += chunk("01wb", c) }
    }
    let file = chunk("RIFF", cat([cc("AVI "), list("hdrl", hdrlBody), list("movi", movi)]))
    try file.write(to: dir.appendingPathComponent(name))
}

struct Expect: Encodable { let frames: [Int]; let fps: Double; let width: Int; let audio: Bool }
func expect(_ name: String, _ e: Expect) throws {
    try JSONEncoder().encode(e).write(to: dir.appendingPathComponent(name.replacingOccurrences(of: ".avi", with: ".expect.json")))
}

func fourcc(_ s: String) -> UInt32 { s.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) } }

let frames = try readFrames(limit: 600)
let pcm = try readPCM(seconds: 20)

// A: MJPEG + PCM 16
let pcm16 = pcm.map { Int16(max(-1, min(1, $0)) * 32767) }
let audioA = AudioSpec(tag: 1, ch: 2, sr: 48000, align: 4, bits: 16, avg: 192000, extra: Data(), scale: 4, rate: 192000,
                       chunks: stride(from: 0, to: pcm16.count, by: 2 * 4800).map { i in pcm16[i..<min(pcm16.count, i + 2 * 4800)].withUnsafeBytes { Data($0) } })
try writeAVI("mjpeg_pcm.avi", w: 640, h: 360, fps: 30, codec: "MJPG", compression: fourcc("MJPG"), bitCount: 24, frames: frames.map(jpeg), audio: audioA)
try expect("mjpeg_pcm.avi", Expect(frames: Array(0..<600), fps: 30, width: 640, audio: true))
print("A mjpeg_pcm.avi")

// B: MJPEG without Huffman tables, a dropped frame
var bFrames = frames.prefix(120).map { stripDHT(jpeg($0)) }
bFrames[10] = Data()
try writeAVI("mjpeg_nodht.avi", w: 640, h: 360, fps: 30, codec: "MJPG", compression: fourcc("MJPG"), bitCount: 24, frames: bFrames, audio: nil)
try expect("mjpeg_nodht.avi", Expect(frames: (0..<120).map { $0 == 10 ? 9 : $0 }, fps: 30, width: 640, audio: false))
print("B mjpeg_nodht.avi")

// H.264 encoder with frame reordering (B-frames); returns samples in decode order.
func encodeH264(_ imgs: [CGImage], reorder: Bool) throws -> (samples: [CMSampleBuffer], fd: CMFormatDescription, bframes: Int) {
    var session: VTCompressionSession?
    VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                               imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    let s = session!
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: reorder ? kCFBooleanTrue : kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
    let lock = NSLock()
    var out: [CMSampleBuffer] = []
    let ctx = CIContext()
    for (k, img) in imgs.enumerated() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pb)
        ctx.render(CIImage(cgImage: img), to: pb!)
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(k), timescale: 30), duration: CMTime(value: 1, timescale: 30),
                                        frameProperties: nil, infoFlagsOut: nil) { _, _, sb in if let sb { lock.lock(); out.append(sb); lock.unlock() } }
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    let b = out.filter { CMSampleBufferGetDecodeTimeStamp($0).isValid && CMSampleBufferGetDecodeTimeStamp($0) != CMSampleBufferGetPresentationTimeStamp($0) }.count
    return (out, CMSampleBufferGetFormatDescription(out[0])!, b)
}

func sampleData(_ sb: CMSampleBuffer) -> Data {
    let bb = CMSampleBufferGetDataBuffer(sb)!
    var d = Data(count: CMBlockBufferGetDataLength(bb))
    d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    return d
}
func isKey(_ sb: CMSampleBuffer) -> Bool {
    guard let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let f = a.first else { return true }
    return !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

// C: H.264 Annex B with B-frames + AAC
let enc = try encodeH264(Array(frames.prefix(300)), reorder: true)
var sps: UnsafePointer<UInt8>?, spsLen = 0, pps: UnsafePointer<UInt8>?, ppsLen = 0
CMVideoFormatDescriptionGetH264ParameterSetAtIndex(enc.fd, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
CMVideoFormatDescriptionGetH264ParameterSetAtIndex(enc.fd, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
let startCode = Data([0, 0, 0, 1])
let annexB: [Data] = enc.samples.map { sb in
    let d = [UInt8](sampleData(sb))
    var out = Data()
    if isKey(sb) { out += cat([startCode, Data(bytes: sps!, count: spsLen), startCode, Data(bytes: pps!, count: ppsLen)]) }
    var o = 0
    while o + 4 <= d.count {
        let l = Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
        out += startCode + Data(d[(o + 4)..<(o + 4 + l)]); o += 4 + l
    }
    return out
}
// AAC-LC via AVAudioConverter: one AVI chunk per raw AAC packet.
let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
var aacDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                          mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
let aacFmt = AVAudioFormat(streamDescription: &aacDesc)!
let conv = AVAudioConverter(from: pcmFmt, to: aacFmt)!
let pcm10 = Array(pcm.prefix(10 * 48000 * 2))
let inBuf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(pcm10.count / 2))!
inBuf.frameLength = inBuf.frameCapacity
pcm10.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: pcm10.count) }
var aacChunks: [Data] = []
var fed = false
while true {
    let outBuf = AVAudioCompressedBuffer(format: aacFmt, packetCapacity: 64, maximumPacketSize: conv.maximumOutputPacketSize)
    var err: NSError?
    let st = conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    for i in 0..<Int(outBuf.packetCount) {
        let p = outBuf.packetDescriptions![i]
        aacChunks.append(Data(bytes: outBuf.data + Int(p.mStartOffset), count: Int(p.mDataByteSize)))
    }
    if st == .endOfStream || st == .error || outBuf.packetCount == 0 { break }
}
let asc = Data([0x11, 0x90]) // AAC-LC, 48 kHz, stereo
let audioC = AudioSpec(tag: 0xFF, ch: 2, sr: 48000, align: 1, bits: 0, avg: 16000, extra: asc, scale: 1024, rate: 48000, chunks: aacChunks)
try writeAVI("h264_bframes.avi", w: 640, h: 360, fps: 30, codec: "H264", compression: fourcc("H264"), bitCount: 24, frames: annexB, audio: audioC)
try expect("h264_bframes.avi", Expect(frames: Array(0..<300), fps: 30, width: 640, audio: true))
print("C h264_bframes.avi (B-frames: \(enc.bframes), AAC packets: \(aacChunks.count))")

// D: uncompressed RGB 24, 320×180
let small = try readFrames(limit: 60, scale: 0.5)
let rowBytes = (320 * 3 + 3) & ~3
let rgbFrames: [Data] = small.map { img in
    var px = [UInt8](repeating: 0, count: 320 * 180 * 4)
    let c = CGContext(data: &px, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: 320, height: 180))
    var out = [UInt8](repeating: 0, count: rowBytes * 180)
    for y in 0..<180 { // bottom-up BGR
        let srcRow = 179 - y
        for x in 0..<320 {
            let s = (srcRow * 320 + x) * 4, d = y * rowBytes + x * 3
            out[d] = px[s + 2]; out[d + 1] = px[s + 1]; out[d + 2] = px[s]
        }
    }
    return Data(out)
}
try writeAVI("rgb24.avi", w: 320, h: 180, fps: 30, codec: "DIB ", compression: 0, bitCount: 24, frames: rgbFrames, audio: nil)
try expect("rgb24.avi", Expect(frames: Array(0..<60), fps: 30, width: 320, audio: false))
print("D rgb24.avi")

// E: H.264 avc1 (length-prefixed, avcC in strf) + PCM float
let encE = try encodeH264(Array(frames.prefix(90)), reorder: false)
let atoms = CMFormatDescriptionGetExtension(encE.fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as! [String: Any]
let avcC = atoms["avcC"] as! Data
let pcmF = Array(pcm.prefix(3 * 48000 * 2))
let audioE = AudioSpec(tag: 3, ch: 2, sr: 48000, align: 8, bits: 32, avg: 384000, extra: Data(), scale: 8, rate: 384000,
                       chunks: stride(from: 0, to: pcmF.count, by: 2 * 4800).map { i in pcmF[i..<min(pcmF.count, i + 2 * 4800)].withUnsafeBytes { Data($0) } })
try writeAVI("h264_avc1.avi", w: 640, h: 360, fps: 30, codec: "avc1", compression: fourcc("avc1"), bitCount: 24, videoExtra: avcC,
             frames: encE.samples.map(sampleData), audio: audioE)
try expect("h264_avc1.avi", Expect(frames: Array(0..<90), fps: 30, width: 640, audio: true))
print("E h264_avc1.avi")
