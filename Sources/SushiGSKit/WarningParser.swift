import Foundation

/// Parses real-time and post-run Sushi, FFmpeg, Aegisub-CLI, and MKVMerge logs
/// into structured audio-matching telemetry (`SyncMetrics`) and actionable `SyncWarning`s.
public struct WarningAnalyzer: Sendable {
    public var maxSafeAverageShiftSeconds: Double
    public var maxSafeShiftJumpSeconds: Double
    public var absoluteHighDiffThreshold: Double
    public var relativeMedianDiffMultiplier: Double

    public init(
        maxSafeAverageShiftSeconds: Double = 5.0,
        maxSafeShiftJumpSeconds: Double = 0.75,
        absoluteHighDiffThreshold: Double = 0.30,
        relativeMedianDiffMultiplier: Double = 5.0
    ) {
        self.maxSafeAverageShiftSeconds = maxSafeAverageShiftSeconds
        self.maxSafeShiftJumpSeconds = maxSafeShiftJumpSeconds
        self.absoluteHighDiffThreshold = absoluteHighDiffThreshold
        self.relativeMedianDiffMultiplier = relativeMedianDiffMultiplier
    }

    public struct AnalysisResult: Hashable, Sendable {
        public var warnings: [SyncWarning]
        public var metrics: SyncMetrics

        public var hasWarnings: Bool { !warnings.isEmpty }

        public var bannerSummary: String? {
            guard !warnings.isEmpty else { return nil }
            if warnings.count == 1 {
                return warnings[0].summary
            }
            let uniqueCategories = Array(NSOrderedSet(array: warnings.map(\.code)).compactMap { $0 as? String })
            let lead = warnings[0].summary
            if uniqueCategories.count == 1 {
                return "\(warnings.count) warnings: \(lead)"
            }
            return "\(warnings.count) issues detected — \(lead)"
        }
    }

    private struct ShiftSample {
        var lineIndex: Int
        var timestamp: String
        var shift: Double
        var diff: Double
    }

    public func analyze(lines: [String]) -> AnalysisResult {
        var warnings: [SyncWarning] = []
        var samples: [ShiftSample] = []
        var avgShift: Double?
        var groupCount = 0
        var brokenSegments = 0
        var maxWindowHits = 0
        var outOfRangeEvents = 0
        var borderFixes = 0

        let shiftRegex = try? NSRegularExpression(
            pattern: #"^(\d+:\d{2}:\d{2}\.\d+)-(\d+:\d{2}:\d{2}\.\d+):\s*shift:\s*([+-]?\d+(?:\.\d+)?),\s*diff:\s*([+-]?\d+(?:\.\d+)?)"#
        )
        let avgRegex = try? NSRegularExpression(
            pattern: #"^Total average shift:\s*([+-]?\d+(?:\.\d+)?)s?"#
        )
        let groupRegex = try? NSRegularExpression(
            pattern: #"^Group \(start:\s*[^,]+,\s*end:\s*[^,]+,\s*lines:\s*(\d+)\)"#
        )

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)

            if let m = shiftRegex?.firstMatch(in: line, range: nsRange),
               let tsRange = Range(m.range(at: 1), in: line),
               let shiftRange = Range(m.range(at: 3), in: line),
               let diffRange = Range(m.range(at: 4), in: line),
               let shiftVal = Double(line[shiftRange]),
               let diffVal = Double(line[diffRange]) {
                let ts = String(line[tsRange])
                if let prev = samples.last {
                    let jump = abs(shiftVal - prev.shift)
                    if jump > maxSafeShiftJumpSeconds {
                        warnings.append(
                            SyncWarning(
                                code: "shift_jump",
                                summary: String(format: "Large shift jump (%.2fs) between segments at %@.", jump, ts),
                                lineIndex: idx
                            )
                        )
                    }
                }
                samples.append(ShiftSample(lineIndex: idx, timestamp: ts, shift: shiftVal, diff: diffVal))
                continue
            }

            if let m = avgRegex?.firstMatch(in: line, range: nsRange),
               let avgRange = Range(m.range(at: 1), in: line),
               let avg = Double(line[avgRange]) {
                avgShift = avg
                if abs(avg) > maxSafeAverageShiftSeconds {
                    warnings.append(
                        SyncWarning(
                            code: "large_avg_shift",
                            summary: String(format: "Average shift (%+.3fs) exceeds ±%.1fs safe threshold.", avg, maxSafeAverageShiftSeconds),
                            lineIndex: idx
                        )
                    )
                }
                continue
            }

            if groupRegex?.firstMatch(in: line, range: nsRange) != nil {
                groupCount += 1
                continue
            }

            let lower = line.lowercased()
            if lower.contains("increasing the window from") {
                maxWindowHits += 1
                warnings.append(
                    SyncWarning(
                        code: "max_window_fallback",
                        summary: stripWarningPrefix(line),
                        lineIndex: idx
                    )
                )
            } else if lower.contains("will most likely be broken") {
                brokenSegments += 1
                warnings.append(
                    SyncWarning(
                        code: "broken_segment",
                        summary: stripWarningPrefix(line),
                        lineIndex: idx
                    )
                )
            } else if lower.contains("shift is not consistent between") {
                brokenSegments += 1
                warnings.append(
                    SyncWarning(
                        code: "inconsistent_group",
                        summary: stripWarningPrefix(line),
                        lineIndex: idx
                    )
                )
            } else if lower.contains("typesetting group at") && lower.contains("different shift") {
                warnings.append(
                    SyncWarning(
                        code: "keyframe_mismatch",
                        summary: stripWarningPrefix(line),
                        lineIndex: idx
                    )
                )
            } else if lower.contains("outside of audio range") {
                outOfRangeEvents += 1
                if outOfRangeEvents == 1 {
                    warnings.append(
                        SyncWarning(
                            code: "outside_audio_range",
                            summary: "Subtitle event(s) fell outside the audio duration.",
                            lineIndex: idx
                        )
                    )
                }
            } else if lower.contains("fixing") && lower.contains("border events") {
                borderFixes += 1
            } else if lower.contains("skipped because zero duration") {
                // Informational unless repeated excessively; tracked via logs.
                continue
            } else if lower.contains("could not be resampled") || lower.contains("resample failed") {
                warnings.append(
                    SyncWarning(code: "resample_failed", summary: stripWarningPrefix(line), lineIndex: idx)
                )
            } else if lower.contains("could not be encoded") || lower.contains("audio encode failed") {
                warnings.append(
                    SyncWarning(code: "audio_encode_failed", summary: stripWarningPrefix(line), lineIndex: idx)
                )
            } else if line.hasPrefix("Warning:") || line.hasPrefix("WARNING:") {
                warnings.append(
                    SyncWarning(code: "pipeline_warning", summary: stripWarningPrefix(line), lineIndex: idx)
                )
            }
        }

        let diffs = samples.map(\.diff).filter(\.isFinite).sorted()
        let medianDiff: Double? = if diffs.isEmpty {
            nil
        } else if diffs.count % 2 == 1 {
            diffs[diffs.count / 2]
        } else {
            (diffs[diffs.count / 2 - 1] + diffs[diffs.count / 2]) / 2.0
        }
        let maxDiff = diffs.last

        var maxJump: Double?
        if samples.count >= 2 {
            var peak = 0.0
            for i in 1..<samples.count {
                peak = max(peak, abs(samples[i].shift - samples[i - 1].shift))
            }
            maxJump = peak
        }

        if let median = medianDiff {
            let threshold = max(0.18, median * relativeMedianDiffMultiplier)
            let weakSamples = samples.filter { $0.diff > absoluteHighDiffThreshold || (median > 0 && $0.diff > threshold) }
            if let worst = weakSamples.max(by: { $0.diff < $1.diff }) {
                warnings.append(
                    SyncWarning(
                        code: "high_audio_diff",
                        summary: String(
                            format: "%d event(s) had weak audio match (worst diff %.3f at %@, median %.3f).",
                            weakSamples.count, worst.diff, worst.timestamp, median
                        ),
                        lineIndex: worst.lineIndex
                    )
                )
            }
        }

        let metrics = SyncMetrics(
            avgShiftSeconds: avgShift,
            medianDiff: medianDiff,
            maxDiff: maxDiff,
            maxShiftJumpSeconds: maxJump,
            eventCount: samples.count,
            groupCount: groupCount,
            brokenSegments: brokenSegments,
            maxWindowHits: maxWindowHits,
            outOfRangeEvents: outOfRangeEvents,
            borderFixes: borderFixes,
            warningCount: warnings.count
        )
        return AnalysisResult(warnings: warnings, metrics: metrics)
    }

    private func stripWarningPrefix(_ line: String) -> String {
        for prefix in ["Warning:", "WARNING:", "[MKVMerge] Warning:", "[Sushi] Warning:"] {
            if line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }
}
