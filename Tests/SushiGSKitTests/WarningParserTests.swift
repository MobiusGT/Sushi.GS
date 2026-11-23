import Testing
@testable import SushiGSKit

@Suite("Sushi Audio-Matching Warning Analyzer")
struct WarningParserTests {
    private let analyzer = WarningAnalyzer()

    @Test("Clean sync produces zero warnings and accurate metrics")
    func cleanSyncProducesNoWarnings() {
        let lines = [
            "Sushi - Automatic Subtitle Shifter (v0.6.7)",
            "---Demuxing---",
            "Loading WAV: 1420.0s @ 24000Hz (1ch), resampling to mono @ 24000Hz",
            "---Calculating shifts---",
            "0:00:12.00-0:00:15.20: shift: 1.2400000000, diff: 0.0120000000",
            "0:00:16.00-0:00:19.10: shift: 1.2420000000, diff: 0.0140000000",
            "0:00:20.00-0:00:24.00: shift: 1.2390000000, diff: 0.0110000000",
            "---Grouping and smoothing---",
            "Group (start: 0:00:12.00, end: 0:23:40.00, lines: 340), shifts (start: 1.240, end: 1.239, average: 1.240)",
            "Total average shift: 1.240s",
            "Done in 3.4s",
        ]

        let result = analyzer.analyze(lines: lines)
        #expect(!result.hasWarnings)
        #expect(result.warnings.isEmpty)
        #expect(result.metrics.eventCount == 3)
        #expect(result.metrics.groupCount == 1)
        #expect(result.metrics.avgShiftSeconds == 1.24)
        #expect(result.metrics.brokenSegments == 0)
        #expect(result.metrics.maxWindowHits == 0)
        #expect(result.bannerSummary == nil)
    }

    @Test("Detects max-window fallback and broken segment warnings with exact line indices")
    func detectsMaxWindowAndBrokenSegment() {
        let lines = [
            "---Calculating shifts---",
            "0:01:00.00-0:01:03.00: shift: 0.5000000000, diff: 0.0200000000",
            "Warning: Detected possibly broken segment starting at 0:05:12.00, increasing the window from 10 to 30",
            "Warning: Events from 0:05:12.00 to 0:05:45.00 will most likely be broken!",
            "Total average shift: 0.510s",
        ]

        let result = analyzer.analyze(lines: lines)
        #expect(result.hasWarnings)
        #expect(result.metrics.maxWindowHits == 1)
        #expect(result.metrics.brokenSegments == 1)
        #expect(result.warnings.contains { $0.code == "max_window_fallback" && $0.lineIndex == 2 })
        #expect(result.warnings.contains { $0.code == "broken_segment" && $0.lineIndex == 3 })
        #expect(result.bannerSummary != nil)
    }

    @Test("Detects high audio-matching diff / low correlation confidence")
    func detectsHighAudioDiff() {
        let lines = [
            "0:00:10.00-0:00:13.00: shift: 0.2000000000, diff: 0.0200000000",
            "0:00:15.00-0:00:18.00: shift: 0.2010000000, diff: 0.0210000000",
            "0:00:20.00-0:00:23.00: shift: 0.2020000000, diff: 0.0190000000",
            "0:00:25.00-0:00:28.00: shift: 0.2050000000, diff: 0.4400000000",
            "Total average shift: 0.202s",
        ]

        let result = analyzer.analyze(lines: lines)
        #expect(result.hasWarnings)
        let highDiff = result.warnings.first { $0.code == "high_audio_diff" }
        #expect(highDiff != nil)
        #expect(highDiff?.lineIndex == 3)
        #expect(result.metrics.maxDiff == 0.44)
    }

    @Test("Detects suspicious shift jumps and large average shift")
    func detectsShiftJumpAndLargeAvgShift() {
        let lines = [
            "0:00:10.00-0:00:12.00: shift: 0.1000000000, diff: 0.0150000000",
            "0:01:10.00-0:01:12.00: shift: 7.8000000000, diff: 0.0160000000",
            "Total average shift: 6.450s",
        ]

        let result = analyzer.analyze(lines: lines)
        #expect(result.warnings.contains { $0.code == "shift_jump" && $0.lineIndex == 1 })
        #expect(result.warnings.contains { $0.code == "large_avg_shift" && $0.lineIndex == 2 })
        #expect((result.metrics.maxShiftJumpSeconds ?? 0) > 7.5)
    }

    @Test("Detects inconsistent chapters, keyframe mismatch, out-of-range, and MKVMerge warnings")
    func detectsPipelineAndKeyframeWarnings() {
        let lines = [
            "0:24:01.00-0:24:04.00: outside of audio range",
            "Warning: Shift is not consistent between 0:00:00.00 and 0:23:00.00, most likely chapters are wrong (std: 0.41). Switching to automatic grouping.",
            "Warning: Typesetting group at 0:12:04.20 had different shift at start/end points (0.04 and -0.02). Shifting by 0.04.",
            "Warning: mkvmerge: Found one or more B frames without second reference in the first GOP.",
        ]

        let result = analyzer.analyze(lines: lines)
        #expect(result.warnings.contains { $0.code == "outside_audio_range" && $0.lineIndex == 0 })
        #expect(result.warnings.contains { $0.code == "inconsistent_group" && $0.lineIndex == 1 })
        #expect(result.warnings.contains { $0.code == "keyframe_mismatch" && $0.lineIndex == 2 })
        #expect(result.warnings.contains { $0.code == "pipeline_warning" && $0.lineIndex == 3 })
    }
}
