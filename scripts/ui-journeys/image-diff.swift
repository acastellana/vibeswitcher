// scripts/ui-journeys.sh's screenshot comparer: compiled with Sources/VibeCore/MacOnly/ImageDiff.swift (which holds the
// comparison and its tests' subject) into .build/ui-journeys/image-diff, no package needed.
//
// image-diff BASELINE CURRENT DIFF [--tolerance N] [--threshold PERCENT] [--mask X,Y,W,H]...
// Prints one line: "same", "changed P% (N of M pixels) in X,Y WxH" or "size WxH -> WxH". Writes DIFF (the current
// image faded, changed pixels red, masks grey) when the change is beyond the threshold. Exits 0 within the threshold,
// 1 beyond it, 2 when an image can't be read or the arguments are wrong.
import Foundation

@main
enum ImageDiffCommand {
    static func main() {
        var positional: [String] = []
        var tolerance = ImageDiff.defaultTolerance
        var threshold = ImageDiff.defaultThreshold
        var masks: [ImageDiff.Rect] = []
        var arguments = CommandLine.arguments.dropFirst()[...]
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("image-diff: \(message)\n".utf8))
            exit(2)
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--tolerance":
                guard let value = arguments.popFirst().flatMap(Int.init), (0...255).contains(value) else { fail("--tolerance takes 0–255") }
                tolerance = value
            case "--threshold":
                guard let value = arguments.popFirst().flatMap(Double.init), value >= 0 else { fail("--threshold takes a percentage") }
                threshold = value
            case "--mask":
                let parts = (arguments.popFirst() ?? "").split(separator: ",").compactMap { Int($0) }
                guard parts.count == 4 else { fail("--mask takes X,Y,W,H in pixels") }
                masks.append(ImageDiff.Rect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
            default: positional.append(argument)
            }
        }
        guard positional.count == 3 else { fail("usage: image-diff BASELINE CURRENT DIFF [--tolerance N] [--threshold P] [--mask X,Y,W,H]...") }
        let (baselineURL, currentURL, diffURL) = (URL(fileURLWithPath: positional[0]), URL(fileURLWithPath: positional[1]),
                                                  URL(fileURLWithPath: positional[2]))
        guard let baseline = ImageDiff.load(baselineURL) else { fail("can't read \(baselineURL.path)") }
        guard let current = ImageDiff.load(currentURL) else { fail("can't read \(currentURL.path)") }
        let result = ImageDiff.compare(baseline, current, tolerance: tolerance, masks: masks)
        let beyond = result.exceeds(threshold: threshold)
        if result.sizeDiffers {
            print("size \(baseline.width)x\(baseline.height) -> \(current.width)x\(current.height)")
        } else if result.changed == 0 {
            print("same")
        } else {
            let box = result.bounds.map { " in \($0.x),\($0.y) \($0.width)x\($0.height)" } ?? ""
            print(String(format: "changed %.3f%% (%d of %d pixels)", result.percent, result.changed, result.compared) + box)
        }
        if beyond, let diff = ImageDiff.diffImage(baseline, current, tolerance: tolerance, masks: masks) {
            guard ImageDiff.writePNG(diff, to: diffURL) else { fail("can't write \(diffURL.path)") }
        }
        exit(beyond ? 1 : 0)
    }
}
