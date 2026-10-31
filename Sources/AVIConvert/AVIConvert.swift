// AVIConvert: AVI to MOV with no external programs. macOS cannot read the AVI container, so it is
// parsed here; the frames are decoded by the system and re-encoded to H.264, and the sound is carried
// over as it is (PCM, MP3, AC-3, AAC). It also works inside an app extension sandbox.
//
// Video: MJPEG (including streams without Huffman tables), H.264 (Annex B or avcC, with B-frames),
// MPEG-4 Part 2 (Xvid/DivX, if the system decoder opens it), uncompressed RGB 24/32 bit.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

/// True for a file with the `.avi` extension.
public func isAVI(_ url: URL) -> Bool { url.pathExtension.lowercased() == "avi" }

// MARK: - Container

final class AVIFile {
    struct Stream {
        var type = ""            // "vids" / "auds"
        var handler = ""
        var scale: UInt32 = 1
        var rate: UInt32 = 1
        var format = Data()      // strf
        var chunks: [(offset: Int, size: Int)] = []
    }

    let data: Data
    private(set) var streams: [Stream] = []

    init(url: URL) throws {
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw AVIError("Cannot open file: \(url.lastPathComponent)") }
        guard data.count >= 12, fourcc(0) == "RIFF", fourcc(8) == "AVI " else { throw AVIError("Not an AVI file: \(url.lastPathComponent)") }
        // AVI 2.0 (OpenDML) continues in more RIFF 'AVIX' lists after the first.
        var o = 0
        while o + 12 <= data.count, fourcc(o) == "RIFF" {
            let size = Int(u32(o + 4))
            parseList(o + 12, end: min(data.count, o + 8 + size))
            o += 8 + size + (size & 1)
            if size == 0 { break }
        }
    }

    func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
    func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
    func fourcc(_ o: Int) -> String {
        guard o + 4 <= data.count else { return "" }
        return String(bytes: data[data.startIndex + o ..< data.startIndex + o + 4], encoding: .isoLatin1) ?? ""
    }
    func bytes(_ c: (offset: Int, size: Int)) -> Data { data.subdata(in: data.startIndex + c.offset ..< data.startIndex + c.offset + c.size) }

    private func parseList(_ start: Int, end: Int) {
        var o = start
        while o + 8 <= end {
            let id = fourcc(o), size = Int(u32(o + 4)), body = o + 8
            let bodyEnd = min(end, body + size)
            if id == "LIST", body + 4 <= end {
                let t = fourcc(body)
                if t == "strl" { streams.append(Stream()) }
                if t == "movi" || t == "rec " { scanMovi(body + 4, end: bodyEnd) } else { parseList(body + 4, end: bodyEnd) }
            } else if id == "strh", !streams.isEmpty, size >= 36 {
                streams[streams.count - 1].type = fourcc(body)
                streams[streams.count - 1].handler = fourcc(body + 4)
                streams[streams.count - 1].scale = max(1, u32(body + 20))
                streams[streams.count - 1].rate = max(1, u32(body + 24))
            } else if id == "strf", !streams.isEmpty {
                streams[streams.count - 1].format = data.subdata(in: data.startIndex + body ..< data.startIndex + bodyEnd)
            }
            o = body + size + (size & 1)
        }
    }

    private func scanMovi(_ start: Int, end: Int) {
        var o = start
        while o + 8 <= end {
            let id = fourcc(o), size = Int(u32(o + 4)), body = o + 8
            if id == "LIST" {
                if fourcc(body) == "rec " { scanMovi(body + 4, end: min(end, body + size)) }
            } else if let n = Int(id.prefix(2)), n < streams.count, !id.hasPrefix("ix") {
                let kind = id.suffix(2)
                if kind == "dc" || kind == "db" || kind == "wb" {
                    streams[n].chunks.append((body, max(0, min(size, end - body))))
                }
            }
            o = body + size + (size & 1)
        }
    }
}

// MARK: - Helpers

/// Splits an Annex B stream (00 00 01 / 00 00 00 01) into NAL units.
private func annexBUnits(_ d: Data) -> [Data] {
    var units: [Data] = []
    d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        let b = p.bindMemory(to: UInt8.self)
        let n = b.count
        var i = 0, start = -1
        while i + 3 <= n {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                if start >= 0 {
                    var e = i
                    if e > start && b[e - 1] == 0 { e -= 1 }
                    units.append(Data(b[start..<e]))
                }
                i += 3
                start = i
            } else { i += 1 }
        }
        if start >= 0 && start < n { units.append(Data(b[start..<n])) }
    }
    return units
}

private func isAnnexB(_ d: Data) -> Bool {
    d.count > 4 && d[d.startIndex] == 0 && d[d.startIndex + 1] == 0 && (d[d.startIndex + 2] == 1 || (d[d.startIndex + 2] == 0 && d[d.startIndex + 3] == 1))
}

/// Standard JPEG Huffman tables (ITU T.81, K.3): Motion-JPEG in AVI often leaves them out.
private let standardDHT: [UInt8] = {
    var t: [UInt8] = [0xFF, 0xC4, 0x01, 0xA2]
    t += [0x00, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0] + Array(0...11)
    t += [0x10, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    t += [0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
          0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
          0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
          0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
          0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
          0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
          0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
          0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
          0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
          0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
          0xF9, 0xFA]
    t += [0x01, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0] + Array(0...11)
    t += [0x11, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    t += [0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
          0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
          0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
          0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
          0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
          0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
          0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
          0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
          0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
          0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
          0xF9, 0xFA]
    return t
}()

/// Adds the standard Huffman tables to a JPEG frame that has none (before its first SOS).
private func withHuffmanTables(_ jpeg: Data) -> Data {
    var b = [UInt8](jpeg)
    var i = 2, sos = -1
    while i + 4 <= b.count, b[i] == 0xFF {
        let m = b[i + 1]
        if m == 0xC4 { return jpeg }
        if m == 0xDA { sos = i; break }
        if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
        i += 2 + Int(b[i + 2]) << 8 + Int(b[i + 3])
    }
    guard sos > 0 else { return jpeg }
    b.insert(contentsOf: standardDHT, at: sos)
    return Data(b)
}

private func descriptorLength(_ n: Int) -> [UInt8] {
    [0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
}

/// 'esds' for MPEG-4 Part 2 from the VOL header (the bytes before the first VOP).
private func mpeg4ESDS(vol: Data) -> Data {
    let dsi: [UInt8] = [0x05] + descriptorLength(vol.count) + [UInt8](vol)
    let dcd: [UInt8] = [0x04] + descriptorLength(13 + dsi.count) + [0x20, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + dsi
    let sl: [UInt8] = [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
    let es: [UInt8] = [0x03] + descriptorLength(3 + dcd.count + sl.count) + [0, 1, 0] + dcd + sl
    return Data([0, 0, 0, 0] + es)
}

// MARK: - H.264 display order

/// Exp-Golomb reader over an RBSP (emulation-prevention bytes removed).
private struct Bits {
    var b: [UInt8]
    var pos = 0
    init(nal: Data) {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for x in nal.dropFirst() { // skip the NAL header
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        b = out
    }
    mutating func u(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let byte = pos >> 3
            let bit = byte < b.count ? Int(b[byte] >> (7 - UInt8(pos & 7))) & 1 : 0
            v = v << 1 | bit; pos += 1
        }
        return v
    }
    mutating func ue() -> Int {
        var z = 0
        while u(1) == 0 && z < 32 { z += 1 }
        return z == 0 ? 0 : (1 << z) - 1 + u(z)
    }
    mutating func se() -> Int { let k = ue(); return k & 1 == 1 ? (k + 1) / 2 : -(k / 2) }
}

private struct SPSInfo { var frameNumBits = 4, pocType = 0, pocLsbBits = 4, frameMbsOnly = true, separatePlanes = false }

private func parseSPS(_ nal: Data) -> SPSInfo {
    var r = Bits(nal: nal), s = SPSInfo()
    let profile = r.u(8); _ = r.u(16); _ = r.ue()
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
        let chroma = r.ue()
        if chroma == 3 { s.separatePlanes = r.u(1) == 1 }
        _ = r.ue(); _ = r.ue(); _ = r.u(1)
        if r.u(1) == 1 {
            for i in 0..<(chroma == 3 ? 12 : 8) where r.u(1) == 1 {
                var last = 8, next = 8
                for _ in 0..<(i < 6 ? 16 : 64) where next != 0 { next = (last + r.se() + 256) % 256; last = next == 0 ? last : next }
            }
        }
    }
    s.frameNumBits = r.ue() + 4
    s.pocType = r.ue()
    if s.pocType == 0 { s.pocLsbBits = r.ue() + 4 }
    else if s.pocType == 1 { _ = r.u(1); _ = r.se(); _ = r.se(); let n = r.ue(); for _ in 0..<n { _ = r.se() } }
    _ = r.ue(); _ = r.u(1); _ = r.ue(); _ = r.ue()
    s.frameMbsOnly = r.u(1) == 1
    return s
}

/// Display rank of every non-empty frame, from picture order counts (POC type 0).
/// Streams with POC type 1/2 (no B-frames in practice) keep decode order.
private func h264DisplayRanks(_ frames: [[Data]], sps: Data) -> [Int] {
    let info = parseSPS(sps)
    guard info.pocType == 0 else { return Array(frames.indices) }
    let maxLsb = 1 << info.pocLsbBits
    var keys: [(gop: Int, poc: Int, i: Int)] = []
    var gop = 0, prevMsb = 0, prevLsb = 0
    for (i, nals) in frames.enumerated() {
        guard let slice = nals.first else { keys.append((gop, Int.max / 2, i)); continue }
        let header = slice[slice.startIndex]
        let idr = header & 0x1F == 5, ref = header >> 5 & 3 != 0
        var r = Bits(nal: slice)
        _ = r.ue(); _ = r.ue(); _ = r.ue()
        if info.separatePlanes { _ = r.u(2) }
        _ = r.u(info.frameNumBits)
        if !info.frameMbsOnly && r.u(1) == 1 { _ = r.u(1) }
        if idr { _ = r.ue(); gop += 1; prevMsb = 0; prevLsb = 0 }
        let lsb = r.u(info.pocLsbBits)
        var msb = prevMsb
        if lsb < prevLsb && prevLsb - lsb >= maxLsb / 2 { msb = prevMsb + maxLsb }
        else if lsb > prevLsb && lsb - prevLsb > maxLsb / 2 { msb = prevMsb - maxLsb }
        if ref { prevMsb = msb; prevLsb = lsb }
        keys.append((gop, msb + lsb, i))
    }
    let order = keys.sorted { $0.gop != $1.gop ? $0.gop < $1.gop : $0.poc != $1.poc ? $0.poc < $1.poc : $0.i < $1.i }
    var rank = [Int](repeating: 0, count: frames.count)
    for (r, k) in order.enumerated() { rank[k.i] = r }
    return rank
}

// MARK: - Conversion

/// What was found in the AVI and converted.
public struct AVIReport {
    public let video: String
    public let audio: String
    public let frames: Int
    public let fps: Double
}

/// The error thrown for an unreadable or unsupported file; `description` is meant for users.
public struct AVIError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}

/// Converts `src` (AVI) into `out` (MOV). `progress` gets 0…1.
@discardableResult
public func convertAVI(_ src: URL, to out: URL, progress: ((Double) -> Void)? = nil) async throws -> AVIReport {
    let avi = try AVIFile(url: src)
    guard let vi = avi.streams.firstIndex(where: { $0.type == "vids" && !$0.chunks.isEmpty }) else { throw AVIError("The AVI has no video stream") }
    let vs = avi.streams[vi]
    guard vs.format.count >= 40 else { throw AVIError("The AVI video header is damaged") }
    let f = vs.format
    func fu32(_ o: Int) -> UInt32 { f.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    func fu16(_ o: Int) -> UInt16 { f.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
    let width = Int(Int32(bitPattern: fu32(4))), rawHeight = Int(Int32(bitPattern: fu32(8)))
    let height = abs(rawHeight), bitCount = Int(fu16(14))
    let compression = fu32(16)
    let codec = compression == 0 ? "RGB" : String(bytes: withUnsafeBytes(of: compression.littleEndian) { Array($0) }, encoding: .isoLatin1)?.uppercased() ?? "?"
    guard width > 0, height > 0 else { throw AVIError("The AVI has an invalid frame size") }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("avi2mov-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Video → H.264, one output frame per AVI frame slot at the stream's exact rate.
    let videoURL = tmp.appendingPathComponent("video.mov")
    let ow = width & ~1, oh = height & ~1
    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
    let fps = Double(vs.rate) / Double(vs.scale)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, Int(Double(ow * oh) * fps * 0.25)),
                                          AVVideoExpectedSourceFrameRateKey: fps.rounded()],
    ])
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = CMTimeScale(min(UInt32(Int32.max), vs.rate))
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let total = vs.chunks.count
    var slot = 0
    var last: CVPixelBuffer?
    func append(_ pb: CVPixelBuffer) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
        guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(slot) * Int64(vs.scale), timescale: CMTimeScale(vs.rate))) else {
            throw AVIError("Could not write frame \(slot): \(writer.error?.localizedDescription ?? "?")")
        }
        last = pb
        slot += 1
        if slot % 30 == 0 { progress?(Double(slot) / Double(max(1, total))) }
    }
    func newBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pb else { throw AVIError("Out of memory for a frame") }
        return pb
    }
    func draw(_ img: CGImage) throws -> CVPixelBuffer {
        let pb = try newBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        return pb
    }
    /// An empty chunk is a dropped frame: the previous picture stays.
    func repeatLast() async throws { if let last { try await append(last) } }

    let mjpeg: Set<String> = ["MJPG", "AVRN", "DMB1", "JPEG", "MJLS", "AVDJ"]
    let h264: Set<String> = ["H264", "X264", "AVC1", "DAVC", "VSSH"]
    let mpeg4: Set<String> = ["XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2", "3IV2", "DIV3"]
    var videoNote = codec

    if mjpeg.contains(codec) {
        videoNote = "Motion-JPEG"
        for c in vs.chunks {
            if c.size == 0 { try await repeatLast(); continue }
            let jpeg = withHuffmanTables(avi.bytes(c))
            guard let srcImg = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(srcImg, 0, nil) else {
                try await repeatLast(); continue
            }
            try await append(try draw(img))
        }
    } else if codec == "RGB" && (bitCount == 24 || bitCount == 32) {
        videoNote = "uncompressed RGB \(bitCount)-bit"
        let rowBytes = ((width * bitCount / 8) + 3) & ~3
        for c in vs.chunks {
            if c.size < rowBytes * height { try await repeatLast(); continue }
            var raw = [UInt8](avi.bytes(c))
            if rawHeight > 0 { // bottom-up rows
                var flipped = [UInt8](repeating: 0, count: raw.count)
                for y in 0..<height { flipped.replaceSubrange(y * rowBytes ..< (y + 1) * rowBytes, with: raw[(height - 1 - y) * rowBytes ..< (height - y) * rowBytes]) }
                raw = flipped
            }
            let info: CGBitmapInfo = bitCount == 32 ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue), .byteOrder32Little]
                                                    : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            // 24-bit AVI is BGR; CoreGraphics reads RGB, so swap the channels.
            if bitCount == 24 { for y in 0..<height { var i = y * rowBytes; for _ in 0..<width { raw.swapAt(i, i + 2); i += 3 } } }
            guard let provider = CGDataProvider(data: Data(raw) as CFData),
                  let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitCount, bytesPerRow: rowBytes,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { try await repeatLast(); continue }
            try await append(try draw(img))
        }
    } else if h264.contains(codec) || mpeg4.contains(codec) {
        let isH264 = h264.contains(codec)
        videoNote = isH264 ? "H.264" : "MPEG-4 Part 2 (\(codec))"
        var fd: CMFormatDescription?
        var lengthSize = 4
        var annexB = true
        if isH264 {
            var sps: Data?, pps: Data?
            // avcC in the strf tail (avc1 streams), else SPS/PPS from the first frames.
            if f.count > 40 + 7, f[f.startIndex + 40] == 1 {
                let x = [UInt8](f[(f.startIndex + 40)...])
                lengthSize = Int(x[4] & 3) + 1
                var o = 6
                let nSPS = Int(x[5] & 0x1F)
                for _ in 0..<nSPS where o + 2 <= x.count {
                    let l = Int(x[o]) << 8 | Int(x[o + 1]); if sps == nil { sps = Data(x[(o + 2)..<min(x.count, o + 2 + l)]) }; o += 2 + l
                }
                if o < x.count {
                    let nPPS = Int(x[o]); o += 1
                    for _ in 0..<nPPS where o + 2 <= x.count {
                        let l = Int(x[o]) << 8 | Int(x[o + 1]); if pps == nil { pps = Data(x[(o + 2)..<min(x.count, o + 2 + l)]) }; o += 2 + l
                    }
                }
            }
            if let first = vs.chunks.first(where: { $0.size > 0 }) { annexB = isAnnexB(avi.bytes(first)) }
            if sps == nil || pps == nil {
                for c in vs.chunks.prefix(300) where c.size > 0 {
                    for u in annexBUnits(avi.bytes(c)) where !u.isEmpty {
                        let t = u[u.startIndex] & 0x1F
                        if t == 7 && sps == nil { sps = u }
                        if t == 8 && pps == nil { pps = u }
                    }
                    if sps != nil && pps != nil { break }
                }
            }
            guard let sps, let pps else { throw AVIError("No stream parameters (SPS/PPS) found in the AVI's H.264") }
            let st = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            } }
            guard st == noErr else { throw AVIError("H.264 parameters rejected (code \(st))") }
        } else {
            // VOL header: the start of the first frame up to the first VOP (00 00 01 B6), or the strf tail.
            var vol = f.count > 40 ? Data(f[(f.startIndex + 40)...]) : Data()
            if vol.isEmpty, let first = vs.chunks.first(where: { $0.size > 0 }) {
                let d = [UInt8](avi.bytes(first))
                var i = 0
                while i + 4 <= d.count && !(d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && d[i + 3] == 0xB6) { i += 1 }
                vol = Data(d[0..<i])
            }
            let ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["esds": mpeg4ESDS(vol: vol)]]
            let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_MPEG4Video, width: Int32(width), height: Int32(height),
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &fd)
            guard st == noErr else { throw AVIError("Format \(codec) rejected (code \(st))") }
            annexB = false
        }
        guard let fd else { throw AVIError("No video format description") }
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard st == noErr, let session else {
            throw AVIError(isH264 ? "The H.264 decoder did not start (code \(st))" : "The macOS decoder does not support \(codec) (Xvid/DivX). Re-encode the file to MP4 or MJPEG AVI.")
        }
        defer { VTDecompressionSessionInvalidate(session) }

        // AVI keeps frames in decode order without display times. Each frame gets its display
        // rank (from the H.264 POC) as its timestamp; decoded pictures are emitted in rank order.
        func nalUnits(_ raw: Data) -> [Data] {
            if !isH264 { return [raw] }
            if annexB { return annexBUnits(raw) }
            var units: [Data] = []
            let b = [UInt8](raw); var o = 0
            while o + lengthSize <= b.count {
                var l = 0; for i in 0..<lengthSize { l = l << 8 | Int(b[o + i]) }
                o += lengthSize
                guard o + l <= b.count else { break }
                units.append(Data(b[o..<(o + l)])); o += l
            }
            return units
        }
        let filled = vs.chunks.filter { $0.size > 0 }
        var ranks = Array(filled.indices)
        if isH264 {
            var sp: UnsafePointer<UInt8>?, sl = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: &sp, parameterSetSizeOut: &sl,
                                                               parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let sp {
                // Only slice headers are needed: the first VCL NAL of each frame.
                let heads: [[Data]] = filled.map { c in
                    nalUnits(avi.bytes(c)).filter { !$0.isEmpty && [1, 5].contains($0[$0.startIndex] & 0x1F) }.prefix(1).map { Data($0.prefix(64)) }
                }
                ranks = h264DisplayRanks(heads, sps: Data(bytes: sp, count: sl))
            }
        }
        var pending: [Int: CVPixelBuffer] = [:]
        var nextRank = 0
        var decodeErrors = 0
        func feed(_ payload: Data, index: Int) {
            var bb: CMBlockBuffer?
            let len = payload.count
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &bb)
            guard let bb else { return }
            payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: len) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: Int64(vs.scale), timescale: CMTimeScale(vs.rate)),
                                            presentationTimeStamp: CMTime(value: Int64(index) * Int64(vs.scale), timescale: CMTimeScale(vs.rate)), decodeTimeStamp: .invalid)
            var size = len
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
            guard let sb else { return }
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
                if status == noErr, let image { pending[Int(pts.value / Int64(vs.scale))] = image } else { decodeErrors += 1 }
            }
        }
        func flush(all: Bool) async throws {
            while let pb = pending.removeValue(forKey: nextRank) { try await append(pb); nextRank += 1 }
            if all {
                for r in pending.keys.sorted() { try await append(pending[r]!) }
                pending.removeAll()
            }
        }
        for (k, c) in filled.enumerated() {
            var payload = Data()
            for u in nalUnits(avi.bytes(c)) where !u.isEmpty {
                if isH264 {
                    let t = u[u.startIndex] & 0x1F
                    if t == 7 || t == 8 || t == 9 { continue }
                    var l = UInt32(u.count).bigEndian
                    payload.append(Data(bytes: &l, count: 4))
                }
                payload.append(u)
            }
            if payload.isEmpty { decodeErrors += 1; continue }
            feed(payload, index: ranks[k])
            try await flush(all: false)
            // A broken stream must not hold everything back: skip a rank that never decodes.
            if pending.count > 64, let m = pending.keys.min() { nextRank = m; try await flush(all: false) }
        }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        try await flush(all: true)
        if slot == 0 {
            throw AVIError(isH264 ? "Could not decode a single H.264 frame" : "The macOS decoder could not open \(codec) (Xvid/DivX). Re-encode the file to MP4 or MJPEG AVI.")
        }
        // Dropped frames (empty chunks): keep the timeline as long as the AVI.
        while slot < total { try await repeatLast() }
        if decodeErrors > 0 { videoNote += ", corrupt frames skipped: \(decodeErrors)" }
    } else {
        throw AVIError("Video codec \"\(codec)\" in AVI is not supported. Supported: MJPEG, H.264, Xvid/DivX and uncompressed RGB.")
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw AVIError("Could not write the video: \(writer.error?.localizedDescription ?? "?")") }

    // Audio: as a file macOS can read, then muxed next to the video.
    var audioURL: URL?
    var audioNote = "none"
    if let ai = avi.streams.firstIndex(where: { $0.type == "auds" && !$0.chunks.isEmpty }), avi.streams[ai].format.count >= 16 {
        let a = avi.streams[ai], af = a.format
        func au16(_ o: Int) -> Int { Int(af.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }) }
        func au32(_ o: Int) -> Int { Int(af.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }) }
        var tag = au16(0)
        let ch = au16(2), sr = au32(4), align = au16(12), bits = au16(14)
        let extra = af.count > 18 ? Data(af[(af.startIndex + 18)...]) : Data()
        if tag == 0xFFFE, extra.count >= 8 { tag = Int(extra[extra.startIndex + 6]) | Int(extra[extra.startIndex + 7]) << 8 }
        func writeChunks(_ url: URL, header: Data = Data(), transform: ((Data) -> Data)? = nil) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            if !header.isEmpty { h.write(header) }
            for c in a.chunks where c.size > 0 { let d = avi.bytes(c); h.write(transform?(d) ?? d) }
        }
        switch tag {
        case 1, 3:
            let url = tmp.appendingPathComponent("audio.wav")
            let dataSize = a.chunks.reduce(0) { $0 + $1.size }
            var hdr = Data()
            func put32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; hdr.append(Data(bytes: &x, count: 4)) }
            func put16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; hdr.append(Data(bytes: &x, count: 2)) }
            hdr.append("RIFF".data(using: .ascii)!); put32(36 + dataSize); hdr.append("WAVEfmt ".data(using: .ascii)!)
            put32(16); put16(tag); put16(ch); put32(sr); put32(sr * max(1, align)); put16(align); put16(bits)
            hdr.append("data".data(using: .ascii)!); put32(dataSize)
            try writeChunks(url, header: hdr)
            audioURL = url; audioNote = tag == 3 ? "PCM float" : "PCM \(bits)-bit"
        case 0x55:
            let url = tmp.appendingPathComponent("audio.mp3"); try writeChunks(url); audioURL = url; audioNote = "MP3"
        case 0x2000:
            let url = tmp.appendingPathComponent("audio.ac3"); try writeChunks(url); audioURL = url; audioNote = "AC-3"
        case 0xFF, 0x1600, 0x1610, 0x706D:
            let url = tmp.appendingPathComponent("audio.aac")
            // Raw AAC frames get ADTS headers from the AudioSpecificConfig in strf (after cbSize),
            // or, without one, AAC-LC at the stream's rate and channel count.
            let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
            let object: Int, srIndex: Int, chCfg: Int
            if extra.count >= 2 {
                let c = [UInt8](extra.prefix(2))
                object = Int(c[0] >> 3); srIndex = Int((c[0] & 7) << 1 | c[1] >> 7); chCfg = Int((c[1] >> 3) & 0xF)
            } else {
                object = 2; srIndex = rates.firstIndex(of: sr) ?? 4; chCfg = min(7, max(1, ch))
            }
            try writeChunks(url) { d in
                if d.count > 2 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] & 0xF0 == 0xF0 { return d }
                let len = d.count + 7
                let h: [UInt8] = [0xFF, 0xF1, UInt8(((max(1, object) - 1) & 3) << 6 | (srIndex & 0xF) << 2 | (chCfg >> 2) & 1),
                                  UInt8((chCfg & 3) << 6 | (len >> 11) & 3), UInt8((len >> 3) & 0xFF), UInt8((len & 7) << 5 | 0x1F), 0xFC]
                return Data(h) + d
            }
            audioURL = url; audioNote = "AAC"
        default:
            audioNote = String(format: "audio codec 0x%04X is not supported — no audio", tag)
        }
    }

    // Mux.
    let comp = AVMutableComposition()
    let vAsset = AVURLAsset(url: videoURL)
    guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
          let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AVIError("Video is empty after conversion") }
    let vDur = try await vAsset.load(.duration)
    try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)
    var aAsset: AVURLAsset?
    if let audioURL {
        let asset = AVURLAsset(url: audioURL)
        if let aTrack = try? await asset.loadTracks(withMediaType: .audio).first, let aDur = try? await asset.load(.duration),
           let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: aDur), of: aTrack, at: .zero)
            aAsset = asset
        } else {
            audioNote += " — unreadable, no audio"
        }
    }
    try? FileManager.default.removeItem(at: out)
    var exported = false
    for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] where !exported {
        guard let ex = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
        do { try await ex.export(to: out, as: .mov); exported = true } catch { try? FileManager.default.removeItem(at: out) }
    }
    withExtendedLifetime(aAsset) {}
    guard exported else { throw AVIError("Could not build a MOV from the AVI") }
    progress?(1)
    return AVIReport(video: videoNote, audio: audioNote, frames: slot, fps: fps)
}
