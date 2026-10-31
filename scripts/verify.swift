// Checks a converted MOV: every slot holds exactly the expected source frame (by the binary number
// drawn on it), the frame rate matches, and, when expected, the sound is there.
// Usage: swift scripts/verify.swift <result.mov> <name.expect.json>

import AVFoundation
import Foundation

struct Expect: Decodable { let frames: [Int]; let fps: Double; let width: Int; let audio: Bool }
let args = CommandLine.arguments
let e = try JSONDecoder().decode(Expect.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
var failures = 0

guard let vt = try await asset.loadTracks(withMediaType: .video).first else { print("✗ no video track"); exit(1) }
let fps = Double(try await vt.load(.nominalFrameRate))
let dur = try await asset.load(.duration).seconds
let n = Int((dur * e.fps).rounded())
if n != e.frames.count || abs(fps - e.fps) > 0.05 { failures += 1; print(String(format: "✗ %d frames (expected %d), %.2f fps", n, e.frames.count, fps)) }

let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let s = Double(e.width) / 640
var bad = 0
for k in 0..<min(n, e.frames.count) {
    let img = try await gen.image(at: CMTime(seconds: (Double(k) + 0.25) / e.fps, preferredTimescale: 6000)).image
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    func lum(_ x: Double) -> Int { let o = (Int(40 * s) * w + Int(x * s)) * 4; return (Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2])) / 3 }
    let marker = lum(30)
    var v = 0
    for b in 0..<10 where lum(90 + Double(b) * 56) > marker / 2 { v |= 1 << b }
    if marker < 100 || v != e.frames[k] {
        bad += 1
        if bad <= 8 { print("✗ slot \(k): frame \(marker < 100 ? "not recognized" : String(v)), expected \(e.frames[k])") }
    }
}
print(bad == 0 ? String(format: "✓ all %d frames in place, %.0f fps", min(n, e.frames.count), fps) : "✗ frames that do not match: \(bad)")
failures += bad

let at = try await asset.loadTracks(withMediaType: .audio).first
if e.audio {
    if let at {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out); reader.startReading()
        var sum: Double = 0, count = 0
        while count < 96000 * 2, let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb) / 4
            var f = [Float](repeating: 0, count: len)
            f.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len * 4, destination: $0.baseAddress!) }
            for x in f { sum += Double(x * x) }; count += len
        }
        let rms = (sum / Double(max(1, count))).squareRoot()
        let adur = try await at.load(.timeRange).duration.seconds
        if rms > 0.05 { print(String(format: "✓ sound present: %.2f s, RMS %.3f", adur, rms)) } else { failures += 1; print(String(format: "✗ sound too quiet: RMS %.4f", rms)) }
    } else { failures += 1; print("✗ no audio track") }
} else if at != nil { print("· there is sound although none was expected") }
exit(failures == 0 ? 0 : 1)
