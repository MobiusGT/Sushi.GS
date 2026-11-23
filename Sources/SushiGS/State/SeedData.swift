import Foundation
import SushiGSKit

/// Deterministic sample data populated ONLY when `APP_SEED=1` is passed (for snapshots & visual review).
/// Uses strictly generic, non-copyrighted filenames and synthetic paths with no personal user info.
enum SeedData {
    static func populate(model: AppModel) {
        model.dependencies.applySeededPreviewState()

        let srcURL = URL(fileURLWithPath: "/Media/Source/Sample_Series_04_WEB_1080p.mkv")
        let dstURL = URL(fileURLWithPath: "/Media/Target/Sample.Series.S01E04.1080p.BluRay.x265.10bit.FLAC.mkv")

        let srcProbe = MediaProbeResult(
            filepath: srcURL.path,
            filename: srcURL.lastPathComponent,
            formatName: "matroska,webm",
            durationSeconds: 1452,
            chapterCount: 5,
            videoTracks: [VideoTrack(id: 0, codec: "h264", width: 1920, height: 1080, default: true)],
            audioTracks: [
                AudioTrack(id: 1, codec: "aac", lang: "jpn", title: "Japanese Stereo", channelLayout: "stereo", channels: 2, sampleRate: 48000, default: true),
                AudioTrack(id: 2, codec: "aac", lang: "eng", title: "English Dub", channelLayout: "stereo", channels: 2, sampleRate: 48000, default: false),
            ],
            subtitleTracks: [
                SubtitleTrack(id: 3, codec: "ass", lang: "eng", title: "English (Full)", extensionName: ".ass", supported: true, default: true),
                SubtitleTrack(id: 4, codec: "ass", lang: "eng", title: "Signs & Songs", extensionName: ".ass", supported: true, default: false, forced: true),
            ]
        )
        let dstProbe = MediaProbeResult(
            filepath: dstURL.path,
            filename: dstURL.lastPathComponent,
            formatName: "matroska,webm",
            durationSeconds: 1456,
            chapterCount: 6,
            videoTracks: [VideoTrack(id: 0, codec: "hevc", width: 1920, height: 1080, default: true)],
            audioTracks: [
                AudioTrack(id: 1, codec: "flac", lang: "eng", title: "English 5.1", channelLayout: "5.1", channels: 6, sampleRate: 48000, bitDepth: 24, default: false),
                AudioTrack(id: 2, codec: "flac", lang: "jpn", title: "Japanese 2.0", channelLayout: "stereo", channels: 2, sampleRate: 48000, bitDepth: 24, default: true),
                AudioTrack(id: 3, codec: "flac", lang: "jpn", title: "Commentary", channelLayout: "stereo", channels: 2, sampleRate: 48000, bitDepth: 16, default: false),
            ],
            subtitleTracks: []
        )

        let single = EpisodeJob(
            episodeBadge: "EP 04",
            matchKind: .episodeRegex,
            isVerified: true,
            sourceURL: srcURL,
            targetURL: dstURL,
            selectedSourceAudioID: 1,
            selectedTargetAudioID: 2,
            selectedSubtitleIDs: [3]
        )
        single.sourceProbe = srcProbe
        single.targetProbe = dstProbe
        single.status = .warned
        single.progress = 1.0
        single.stageDetail = "Completed with warnings"
        single.syncedFiles = ["\(dstURL.path).sushi.ass"]
        single.metrics = SyncMetrics(
            avgShiftSeconds: 1.428,
            medianDiff: 0.019,
            maxDiff: 0.382,
            maxShiftJumpSeconds: 1.15,
            eventCount: 318,
            groupCount: 4,
            brokenSegments: 1,
            maxWindowHits: 1,
            outOfRangeEvents: 0,
            borderFixes: 1,
            warningCount: 2
        )
        single.warnings = [
            SyncWarning(
                code: "max_window_fallback",
                summary: "Detected possibly broken segment starting at 0:11:42.10, increasing the window from 10 to 30",
                lineIndex: 5
            ),
            SyncWarning(
                code: "high_audio_diff",
                summary: "2 event(s) showed weak audio match (worst diff 0.382 at 0:11:48.50, median 0.019).",
                lineIndex: 6
            ),
        ]
        single.logs = [
            LogEntry(lineIndex: 0, timestamp: "11:02:01", source: "sushi", severity: .info, line: "Sushi - Automatic Subtitle Shifter (v0.6.7)", jobID: single.id),
            LogEntry(lineIndex: 1, timestamp: "11:02:01", source: "sushi", severity: .info, line: "---Demuxing---", jobID: single.id),
            LogEntry(lineIndex: 2, timestamp: "11:02:04", source: "sushi", severity: .info, line: "Loading WAV: 1452.0s @ 24000Hz (1ch), resampling to mono @ 24000Hz", jobID: single.id),
            LogEntry(lineIndex: 3, timestamp: "11:02:07", source: "sushi", severity: .info, line: "---Calculating shifts---", jobID: single.id),
            LogEntry(lineIndex: 4, timestamp: "11:02:08", source: "sushi", severity: .info, line: "0:00:14.20-0:00:18.40: shift: 1.4250000000, diff: 0.0180000000", jobID: single.id),
            LogEntry(lineIndex: 5, timestamp: "11:02:09", source: "sushi", severity: .warning, line: "Warning: Detected possibly broken segment starting at 0:11:42.10, increasing the window from 10 to 30", jobID: single.id),
            LogEntry(lineIndex: 6, timestamp: "11:02:10", source: "sushi", severity: .warning, line: "0:11:48.50-0:11:51.00: shift: 2.5750000000, diff: 0.3820000000", jobID: single.id),
            LogEntry(lineIndex: 7, timestamp: "11:02:12", source: "sushi", severity: .info, line: "---Grouping and smoothing---", jobID: single.id),
            LogEntry(lineIndex: 8, timestamp: "11:02:12", source: "sushi", severity: .info, line: "Total average shift: 1.428s", jobID: single.id),
            LogEntry(lineIndex: 9, timestamp: "11:02:12", source: "sushi", severity: .info, line: "Done in 11.2s", jobID: single.id),
        ]
        model.singleJob = single

        // Seed Stage 2 batch queue spanning Exact-Name Auto-Verified, Regex Unverified, and Unmatched rows.
        let batchFixtures: [(Int, JobStatus, PairMatchKind, Bool, Double?, [SyncWarning], String?)] = [
            (1, .succeeded, .exactFilename, true, 0.842, [], nil),
            (2, .warned, .episodeRegex, false, 1.428, single.warnings, nil),
            (3, .pending, .episodeRegex, false, nil, [], nil),
            (4, .failed, .episodeRegex, true, nil, [], "Audio stream index 3 does not exist in target file."),
        ]

        var jobs: [EpisodeJob] = []
        for (ep, status, matchKind, verified, shift, warns, err) in batchFixtures {
            let epStr = String(format: "%02d", ep)
            let sURL = matchKind == .exactFilename
                ? URL(fileURLWithPath: "/Media/Source/Sample Series - \(epStr).mkv")
                : URL(fileURLWithPath: "/Media/Source/Sample_Series_\(epStr)_WEB_1080p.mkv")
            let tURL = matchKind == .exactFilename
                ? URL(fileURLWithPath: "/Media/Target/Sample Series - \(epStr).mp4")
                : URL(fileURLWithPath: "/Media/Target/Sample.Series.S01E\(epStr).1080p.BluRay.x265.mkv")
            let job = EpisodeJob(
                episodeBadge: "S01E\(epStr)",
                matchKind: matchKind,
                isVerified: verified,
                sourceURL: sURL,
                targetURL: tURL,
                selectedSourceAudioID: 1,
                selectedTargetAudioID: 2,
                selectedSubtitleIDs: [3]
            )
            job.sourceProbe = srcProbe
            job.targetProbe = dstProbe
            job.status = status
            job.progress = (status == .succeeded || status == .warned) ? 1.0 : 0.0
            job.warnings = warns
            job.errorMessage = err
            if let shift {
                job.metrics = SyncMetrics(avgShiftSeconds: shift, medianDiff: 0.018, maxDiff: warns.isEmpty ? 0.041 : 0.382, eventCount: 310, groupCount: 4, warningCount: warns.count)
                job.syncedFiles = ["\(tURL.path).sushi.ass"]
                if status == .succeeded {
                    job.mergedFilepath = "/Media/Target/Merged Files/Sample Series - \(epStr).mkv"
                }
            }
            job.logs = single.logs
            jobs.append(job)
        }
        // Add an explicitly unmatched entry to verify the "No match found" + Choose File... row UI.
        let unmatchedJob = EpisodeJob(
            episodeBadge: "S02E01",
            matchKind: .unmatched,
            isVerified: false,
            sourceURL: URL(fileURLWithPath: "/Media/Source/Sample_Series_S02E01_WEB_1080p.mkv"),
            targetURL: nil,
            selectedSourceAudioID: 1,
            selectedSubtitleIDs: [3]
        )
        unmatchedJob.sourceProbe = srcProbe
        jobs.append(unmatchedJob)

        model.batchSourceFolder = URL(fileURLWithPath: "/Media/Source")
        model.batchTargetFolder = URL(fileURLWithPath: "/Media/Target")
        model.stagedSourceMedia = jobs.compactMap(\.sourceURL)
        model.stagedTargetMedia = jobs.compactMap(\.targetURL)
        model.batchJobs = jobs
        model.isBatchInQueueStage = true
        model.selectedBatchJobIDs = [jobs[1].id]
        model.globalLogs = single.logs
    }

    /// Configures a deterministic Stage 1 intake state where ONLY the Source folder is set,
    /// verifying that Batch Mode waits cleanly for Target before transitioning.
    static func configureOneFolderBatchIntake(model: AppModel) {
        model.batchJobs = []
        model.selectedBatchJobIDs = []
        model.isBatchInQueueStage = false
        model.batchSourceFolder = URL(fileURLWithPath: "/Media/Source/Sample Series Season 1")
        model.stagedSourceMedia = (1...12).map {
            URL(fileURLWithPath: String(format: "/Media/Source/Sample Series Season 1/Sample_Series_%02d_WEB_1080p.mkv", $0))
        }
        model.stagedSourceSubtitles = []
        model.batchTargetFolder = nil
        model.stagedTargetMedia = []
    }
}
