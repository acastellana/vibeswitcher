import Foundation
import Testing
import VibeCore

/// scripts/ui-journeys.sh's screenshot comparison (its helper, scripts/ui-journeys/image-diff.swift, is compiled with
/// Sources/VibeCore/ImageDiff.swift).
@Suite struct ImageDiffTests {
    let white: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)

    @Test func identicalImagesDifferNowhere() {
        let image = ImageDiff.Pixels(width: 40, height: 30, filled: white)
        let result = ImageDiff.compare(image, image)
        #expect(result.changed == 0)
        #expect(result.compared == 1_200)
        #expect(result.percent == 0)
        #expect(result.bounds == nil)
        #expect(!result.exceeds(threshold: 0))
    }

    @Test func aChangedRegionIsMeasuredAndBounded() {
        let baseline = ImageDiff.Pixels(width: 100, height: 100, filled: white)
        var current = baseline
        current.fill(ImageDiff.Rect(x: 10, y: 20, width: 5, height: 4), (0, 0, 0, 255))
        let result = ImageDiff.compare(baseline, current)
        #expect(result.changed == 20)
        #expect(result.percent == 0.2)
        #expect(result.bounds == ImageDiff.Rect(x: 10, y: 20, width: 5, height: 4))

        let diff = ImageDiff.diffImage(baseline, current)
        #expect(diff.map { Array($0.rgba[(20 * 100 + 10) * 4..<(20 * 100 + 10) * 4 + 4]) } == [255, 0, 0, 255])
    }

    @Test func theThresholdIsHonoured() {
        let baseline = ImageDiff.Pixels(width: 100, height: 100, filled: white)
        var current = baseline
        current.fill(ImageDiff.Rect(x: 0, y: 0, width: 10, height: 4), (0, 0, 0, 255))   // 40 pixels: 0.4 %
        let small = ImageDiff.compare(baseline, current)
        #expect(!small.exceeds(threshold: 0.5))
        #expect(!small.exceeds(threshold: 0.4))
        #expect(small.exceeds(threshold: 0.3))
        current.fill(ImageDiff.Rect(x: 0, y: 4, width: 10, height: 2), (0, 0, 0, 255))   // 60 pixels: 0.6 %
        #expect(ImageDiff.compare(baseline, current).exceeds(threshold: 0.5))
        #expect(!ImageDiff.compare(baseline, current).exceeds(threshold: 1))
    }

    /// The default trips on a short word's worth of a 2560x1600 shot (a label "Attention" -> "Attn TEMP" changed
    /// 4,269 pixels, 0.11 %) and not on a few stray pixels.
    @Test func theDefaultThresholdCatchesALabelChange() {
        let baseline = ImageDiff.Pixels(width: 2_560, height: 1_600, filled: white)
        var current = baseline
        current.fill(ImageDiff.Rect(x: 84, y: 116, width: 352, height: 12), (0, 0, 0, 255))   // 4,224 pixels
        #expect(ImageDiff.compare(baseline, current).exceeds(threshold: ImageDiff.defaultThreshold))
        var speck = baseline
        speck.fill(ImageDiff.Rect(x: 10, y: 10, width: 20, height: 20), (0, 0, 0, 255))   // 400 pixels
        #expect(!ImageDiff.compare(baseline, speck).exceeds(threshold: ImageDiff.defaultThreshold))
    }

    @Test func noiseWithinTheToleranceAndMaskedPixelsDontCount() {
        let baseline = ImageDiff.Pixels(width: 20, height: 20, filled: (100, 100, 100, 255))
        var current = baseline
        current.fill(ImageDiff.Rect(x: 0, y: 0, width: 20, height: 20), (108, 92, 100, 255))   // every pixel, by 8
        #expect(ImageDiff.compare(baseline, current).changed == 0)
        #expect(ImageDiff.compare(baseline, current, tolerance: 7).changed == 400)

        current.fill(ImageDiff.Rect(x: 2, y: 2, width: 3, height: 3), (0, 0, 0, 255))   // a "caret"
        let masked = ImageDiff.compare(baseline, current, masks: [ImageDiff.Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(masked.changed == 0)
        #expect(masked.compared == 300)
    }

    @Test func imagesOfDifferentSizesDifferEverywhere() {
        let result = ImageDiff.compare(ImageDiff.Pixels(width: 10, height: 10, filled: white),
                                       ImageDiff.Pixels(width: 10, height: 12, filled: white))
        #expect(result.sizeDiffers)
        #expect(result.percent == 100)
        #expect(result.exceeds(threshold: 100))
    }

    @Test func aPNGReadsBackAsWritten() throws {
        let scratch = Scratch()
        var image = ImageDiff.Pixels(width: 8, height: 6, filled: white)
        image.fill(ImageDiff.Rect(x: 1, y: 1, width: 2, height: 2), (200, 30, 40, 255))
        let file = scratch.adopt(scratchRoot.appendingPathComponent("image-diff-\(UUID().uuidString).png"))
        #expect(ImageDiff.writePNG(image, to: file))
        let read = try #require(ImageDiff.load(file))
        #expect(ImageDiff.compare(image, read, tolerance: 0).changed == 0)
    }
}
