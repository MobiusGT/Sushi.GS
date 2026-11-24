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

        // Seed Auto Batch Stage 2 queue (External mode showing 3-folder pairing + exact, regex, unmatched rows)
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
            let subURL = matchKind == .exactFilename
                ? URL(fileURLWithPath: "/Media/Subtitles/Sample Series - \(epStr).ass")
                : URL(fileURLWithPath: "/Media/Subtitles/Sample_Series_S01E\(epStr)_EN.ass")
            let job = EpisodeJob(
                episodeBadge: "S01E\(epStr)",
                matchKind: matchKind,
                isVerified: verified,
                sourceURL: sURL,
                targetURL: tURL,
                externalSubtitleURL: subURL,
                useExternalSubtitle: true,
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
            externalSubtitleURL: nil,
            useExternalSubtitle: true,
            selectedSourceAudioID: 1,
            selectedSubtitleIDs: [3]
        )
        unmatchedJob.sourceProbe = srcProbe
        jobs.append(unmatchedJob)

        model.batchSubtitleMode = .external
        model.batchSourceFolder = URL(fileURLWithPath: "/Media/Source")
        model.batchTargetFolder = URL(fileURLWithPath: "/Media/Target")
        model.batchSubtitleFolder = URL(fileURLWithPath: "/Media/Subtitles")
        model.stagedSourceMedia = jobs.compactMap(\.sourceURL)
        model.stagedTargetMedia = jobs.compactMap(\.targetURL)
        model.stagedExternalSubtitles = jobs.compactMap(\.externalSubtitleURL)
        model.batchJobs = jobs
        model.isBatchInQueueStage = true
        model.selectedBatchJobIDs = [jobs[1].id]
        model.globalLogs = single.logs

        // Seed Manual Batch workspace (File Browser + External 4-column populated state)
        populateManualBatch(model: model, subtitleMode: .external, srcProbe: srcProbe, dstProbe: dstProbe, sampleLogs: single.logs, sampleWarnings: single.warnings)
    }

    static func populateManualBatch(
        model: AppModel,
        subtitleMode: BatchSubtitleMode,
        srcProbe: MediaProbeResult? = nil,
        dstProbe: MediaProbeResult? = nil,
        sampleLogs: [LogEntry] = [],
        sampleWarnings: [SyncWarning] = []
    ) {
        let root = URL(fileURLWithPath: "/Media/Sample_Series")
        let srcDir = URL(fileURLWithPath: "/Media/Sample_Series/WEB_Source")
        let subDir = URL(fileURLWithPath: "/Media/Sample_Series/Subtitles_ASS")
        let dstDir = URL(fileURLWithPath: "/Media/Sample_Series/BluRay_Target")

        model.isSeededSyntheticBrowser = true
        model.manualBrowserRootURL = root
        model.manualBrowserFilter = .all
        model.manualBrowserSearch = ""
        model.manualBrowserExpandedPaths = [srcDir.path, subDir.path]
        model.manualBrowserSelectedPaths = [srcDir.appendingPathComponent("Episode_03_WEB.mkv").path]
        model.manualBrowserDirectoryCache = [
            root.path: [
                FileBrowserEntry(url: dstDir, isDirectory: true),
                FileBrowserEntry(url: subDir, isDirectory: true),
                FileBrowserEntry(url: srcDir, isDirectory: true),
                FileBrowserEntry(url: root.appendingPathComponent("Bonus_OVA_WEB.mkv"), isDirectory: false),
            ],
            srcDir.path: [
                FileBrowserEntry(url: srcDir.appendingPathComponent("Episode_01_WEB.mkv"), isDirectory: false),
                FileBrowserEntry(url: srcDir.appendingPathComponent("Episode_02_WEB.mkv"), isDirectory: false),
                FileBrowserEntry(url: srcDir.appendingPathComponent("Episode_03_WEB.mkv"), isDirectory: false),
                FileBrowserEntry(url: srcDir.appendingPathComponent("Episode_04_WEB.mkv"), isDirectory: false),
                FileBrowserEntry(url: srcDir.appendingPathComponent("Episode_05_WEB.mkv"), isDirectory: false),
            ],
            subDir.path: [
                FileBrowserEntry(url: subDir.appendingPathComponent("Ep01_EN.ass"), isDirectory: false),
                FileBrowserEntry(url: subDir.appendingPathComponent("Ep02_EN.ass"), isDirectory: false),
                FileBrowserEntry(url: subDir.appendingPathComponent("Ep03_EN.ass"), isDirectory: false),
                FileBrowserEntry(url: subDir.appendingPathComponent("Ep04_EN.ass"), isDirectory: false),
            ],
            dstDir.path: [
                FileBrowserEntry(url: dstDir.appendingPathComponent("Sample.BD.01.1080p.FLAC.mkv"), isDirectory: false),
                FileBrowserEntry(url: dstDir.appendingPathComponent("Sample.BD.02.1080p.FLAC.mkv"), isDirectory: false),
                FileBrowserEntry(url: dstDir.appendingPathComponent("Sample.BD.03.1080p.FLAC.mkv"), isDirectory: false),
                FileBrowserEntry(url: dstDir.appendingPathComponent("Sample.BD.04.1080p.FLAC.mkv"), isDirectory: false),
                FileBrowserEntry(url: dstDir.appendingPathComponent("Sample.BD.05.1080p.FLAC.mkv"), isDirectory: false),
            ],
        ]

        var columns = ManualBatchColumns(subtitleMode: subtitleMode)
        columns.sourceVideos = [
            ManualBatchCell(url: srcDir.appendingPathComponent("Episode_01_WEB.mkv")),
            ManualBatchCell(url: srcDir.appendingPathComponent("Episode_02_WEB.mkv")),
            ManualBatchCell(url: srcDir.appendingPathComponent("Episode_03_WEB.mkv")),
            ManualBatchCell(url: srcDir.appendingPathComponent("Episode_04_WEB.mkv")),
            ManualBatchCell(url: srcDir.appendingPathComponent("Episode_05_WEB.mkv")),
        ]
        columns.sourceSubtitles = [
            ManualBatchCell(url: subDir.appendingPathComponent("Ep01_EN.ass")),
            ManualBatchCell(url: subDir.appendingPathComponent("Ep02_EN.ass")),
            ManualBatchCell(url: subDir.appendingPathComponent("Ep03_EN.ass")),
            ManualBatchCell(url: nil), // Explicit blank alignment slot on row #4
            ManualBatchCell(url: subDir.appendingPathComponent("Ep04_EN.ass")),
        ]
        columns.targetVideos = [
            ManualBatchCell(url: dstDir.appendingPathComponent("Sample.BD.01.1080p.FLAC.mkv")),
            ManualBatchCell(url: dstDir.appendingPathComponent("Sample.BD.02.1080p.FLAC.mkv")),
            ManualBatchCell(url: dstDir.appendingPathComponent("Sample.BD.03.1080p.FLAC.mkv")),
            ManualBatchCell(url: dstDir.appendingPathComponent("Sample.BD.04.1080p.FLAC.mkv")),
        ] // Intentionally 4 items to demonstrate visible empty-slot cell on row #5

        model.manualColumns = columns
        model.manualJobs = []
        model.syncManualJobs()

        let effectiveSrcProbe = srcProbe ?? model.singleJob.sourceProbe
        let effectiveDstProbe = dstProbe ?? model.singleJob.targetProbe
        let effectiveLogs = sampleLogs.isEmpty ? model.singleJob.logs : sampleLogs
        let effectiveWarnings = sampleWarnings.isEmpty ? model.singleJob.warnings : sampleWarnings

        for (idx, job) in model.manualJobs.enumerated() {
            job.sourceProbe = effectiveSrcProbe
            job.targetProbe = effectiveDstProbe
            job.selectedSourceAudioID = 1
            job.selectedTargetAudioID = 2
            job.selectedSubtitleIDs = [3]
            job.logs = effectiveLogs
            if idx == 0 {
                job.status = .succeeded
                job.progress = 1.0
                job.syncedFiles = ["\(job.targetURL?.path ?? "/Media/Ep01").sushi.ass"]
                job.mergedFilepath = "/Media/Sample_Series/Merged Files/Sample.BD.01.mkv"
            } else if idx == 1 {
                job.status = .warned
                job.progress = 1.0
                job.warnings = effectiveWarnings
                job.syncedFiles = ["\(job.targetURL?.path ?? "/Media/Ep02").sushi.ass"]
            } else if idx == 2 {
                job.status = .pending
            }
        }
        model.selectedManualRowIndex = 1
        model.selectedManualColumn = .sourceVideo
        if let secondCell = columns.sourceVideos.dropFirst().first {
            model.selectedManualCellIDs = [secondCell.id]
        }
        model.syncMenuState()
    }

    /// Configures a deterministic Stage 1 Embedded intake state where ONLY Source Media Folder is set.
    static func configureEmbeddedOneFolderIntake(model: AppModel) {
        model.batchSubtitleMode = .embedded
        model.batchJobs = []
        model.selectedBatchJobIDs = []
        model.isBatchInQueueStage = false
        model.batchSourceFolder = URL(fileURLWithPath: "/Media/Source/Sample Series Season 1")
        model.stagedSourceMedia = (1...12).map {
            URL(fileURLWithPath: String(format: "/Media/Source/Sample Series Season 1/Sample_Series_%02d_WEB_1080p.mkv", $0))
        }
        model.batchTargetFolder = nil
        model.stagedTargetMedia = []
        model.batchSubtitleFolder = nil
        model.stagedExternalSubtitles = []
        model.syncMenuState()
    }

    /// Configures a deterministic Stage 1 External intake state showing all 3 drop boxes (Source + Target ready, waiting for Subtitle Folder).
    static func configureExternalThreeFolderIntake(model: AppModel) {
        model.batchSubtitleMode = .external
        model.batchJobs = []
        model.selectedBatchJobIDs = []
        model.isBatchInQueueStage = false
        model.batchSourceFolder = URL(fileURLWithPath: "/Media/Source/Sample Series Season 1")
        model.stagedSourceMedia = (1...12).map {
            URL(fileURLWithPath: String(format: "/Media/Source/Sample Series Season 1/Sample_Series_%02d_WEB_1080p.mkv", $0))
        }
        model.batchTargetFolder = URL(fileURLWithPath: "/Media/Target/Sample Series BluRay")
        model.stagedTargetMedia = (1...12).map {
            URL(fileURLWithPath: String(format: "/Media/Target/Sample Series BluRay/Sample.Series.S01E%02d.BluRay.mkv", $0))
        }
        model.batchSubtitleFolder = nil
        model.stagedExternalSubtitles = []
        model.syncMenuState()
    }
}
