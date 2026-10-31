# avi2mov

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

Convert AVI files to MOV on macOS **without ffmpeg or any other external program**.

macOS can't read the AVI container. avi2mov parses it itself, lets the system decode the frames and re-encode them to H.264, and carries the sound over unchanged. It is a Swift package: a command-line tool and a library, usable from apps and from app extensions (it needs no helper processes, so it works inside a sandbox).

```console
$ avi2mov holiday.avi
/Users/me/holiday.mov
video: MJPEG, 600 frames, 30.000 fps
audio: PCM 16-bit
```

## Supported content

| Inside the AVI | Support |
|---|---|
| MJPEG (cameras), including streams without Huffman tables | yes, tested |
| H.264 (Annex B and avc1), including B-frames | yes, tested |
| Uncompressed RGB 24/32 bit | yes, tested |
| Sound: PCM (8–32 bit, float), AAC | yes, tested |
| Sound: MP3, AC-3 | passed through as it is, **not tested** (no test files) |
| MPEG-4 Part 2 (Xvid / DivX) | only if the macOS decoder opens it; **not tested**. Otherwise a clear error |
| WMV, Cinepak, Indeo and others | no, with a clear error |

Details that matter:

- One output frame is produced per AVI frame slot at the stream's exact rate, so a dropped frame in the source (an empty chunk) keeps the timing.
- AVI 2.0 (OpenDML) files that continue in further `RIFF AVIX` lists are read.
- Odd frame sizes are rounded down to even numbers, as H.264 requires.

## Requirements

- macOS 13 or later
- Xcode or the Command Line Tools (Swift 5.9+) to build

## Command line

```sh
git clone https://github.com/morizmatik/avi2mov.git && cd avi2mov
swift build -c release
.build/release/avi2mov input.avi --out output.mov
```

Without `--out` the result goes next to the input with the `.mov` extension. An existing output file is replaced. Exit codes: `0` success, `1` conversion failed, `2` invalid usage.

## Library

Add the package and import `AVIConvert`:

```swift
// Package.swift
.package(url: "https://github.com/morizmatik/avi2mov.git", branch: "main"),
// target dependency
.product(name: "AVIConvert", package: "avi2mov"),
```

```swift
import AVIConvert

if isAVI(url) {
    let report = try await convertAVI(url, to: movURL) { fraction in
        print("progress: \(Int(fraction * 100))%")
    }
    print(report.video, report.audio, report.frames, report.fps)
}
```

| API | Description |
|---|---|
| `isAVI(_ url: URL) -> Bool` | True for a `.avi` file name |
| `convertAVI(_:to:progress:) async throws -> AVIReport` | Converts and returns what was found: `video`, `audio`, `frames`, `fps` |
| `AVIError` | The error thrown for an unreadable or unsupported file; its `description` is written for users |

It is a single file, `Sources/AVIConvert/AVIConvert.swift`, with no dependencies beyond system frameworks (AVFoundation, VideoToolbox, ImageIO). It can be copied into a project as it is.

## Tests

```sh
scripts/test.sh
```

This builds the tool, generates a 20-second source clip whose every frame carries its own number, builds five test AVI files (MJPEG with PCM, MJPEG without Huffman tables with a dropped frame, H.264 with B-frames and AAC, uncompressed RGB, H.264 avc1 with float PCM), converts them and checks that **every output slot holds the expected source frame**, that the frame rate matches and that the sound is present. It needs macOS and takes a minute or two.

What the tests do not cover: MP3 and AC-3 sound, Xvid/DivX, very large files, and playback of the result in specific players.

## License

[MIT](LICENSE)
