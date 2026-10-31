import AVIConvert
import Foundation

let usage = """
avi2mov: convert an AVI file to MOV with no ffmpeg (macOS only)

Usage: avi2mov <input.avi> [--out <output.mov>]

The video is re-encoded to H.264, the sound is carried over as it is.
Without --out the result is written next to the input, with the .mov extension.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("avi2mov: \(message)\n".utf8))
    exit(code)
}

var input: String?
var output: String?
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--out", "-o":
        guard let value = args.first else { fail("--out needs a path", code: 2) }
        args.removeFirst()
        output = value
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)", code: 2) }
        if input != nil { fail("only one input file is accepted", code: 2) }
        input = arg
    }
}
guard let input else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

let source = URL(fileURLWithPath: input)
guard FileManager.default.fileExists(atPath: source.path) else { fail("file not found: \(input)") }
let target = URL(fileURLWithPath: output ?? source.deletingPathExtension().appendingPathExtension("mov").path)
guard target.standardizedFileURL != source.standardizedFileURL else { fail("the output would overwrite the input", code: 2) }

do {
    var last = -1
    let report = try await convertAVI(source, to: target) { fraction in
        let percent = Int(fraction * 100)
        if percent != last, isatty(2) != 0 {
            last = percent
            FileHandle.standardError.write(Data("\r\(percent)%".utf8))
        }
    }
    if last >= 0 { FileHandle.standardError.write(Data("\r    \r".utf8)) }
    print("\(target.path)")
    print("video: \(report.video), \(report.frames) frames, \(String(format: "%.3f", report.fps)) fps")
    print("audio: \(report.audio)")
} catch {
    fail("\(error)")
}
