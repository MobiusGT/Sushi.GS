import Foundation
import Observation
import SushiGSKit

/// Observable model for a single Source -> Target sync/merge job
/// (used in both Single Episode workspace and every row of the Batch Queue).
@Observable
final class EpisodeJob: Identifiable {
    let id: UUID
    var episodeBadge: String
    var isExactMatch: Bool

    var sourceURL: URL?
    var targetURL: URL?
    var externalSubtitleURL: URL?
    var useExternalSubtitle: Bool

    var sourceProbe: MediaProbeResult?
    var targetProbe: MediaProbeResult?
    var isProbingSource = false
    var isProbingTarget = false
    var probeError: String?

    // Explicit track selection (can be driven by batch rules or per-episode override).
    var selectedSourceAudioID: Int?
    var selectedTargetAudioID: Int?
    var selectedSubtitleIDs: Set<Int>
    var hasCustomTrackOverrides = false

    // Runtime execution state.
    var status: JobStatus = .pending
    var stageDetail: String = ""
    var progress: Double = 0
    var logs: [LogEntry] = []
    var warnings: [SyncWarning] = []
    var metrics: SyncMetrics?
    var syncedFiles: [String] = []
    var mergedFilepath: String?
    var errorMessage: String?
    var sushiLogPath: String?
    var mergeLogPath: String?

    init(
        id: UUID = UUID(),
        episodeBadge: String = "",
        isExactMatch: Bool = true,
        sourceURL: URL? = nil,
        targetURL: URL? = nil,
        externalSubtitleURL: URL? = nil,
        useExternalSubtitle: Bool = false,
        selectedSourceAudioID: Int? = nil,
        selectedTargetAudioID: Int? = nil,
        selectedSubtitleIDs: Set<Int> = []
    ) {
        self.id = id
        self.episodeBadge = episodeBadge
        self.isExactMatch = isExactMatch
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.externalSubtitleURL = externalSubtitleURL
        self.useExternalSubtitle = useExternalSubtitle
        self.selectedSourceAudioID = selectedSourceAudioID
        self.selectedTargetAudioID = selectedTargetAudioID
        self.selectedSubtitleIDs = selectedSubtitleIDs
    }

    var displayTitle: String {
        if let targetURL {
            return targetURL.deletingPathExtension().lastPathComponent
        }
        if let sourceURL {
            return sourceURL.deletingPathExtension().lastPathComponent
        }
        return "Untitled Episode"
    }

    var hasRequiredInputs: Bool {
        guard sourceURL != nil, targetURL != nil else { return false }
        if useExternalSubtitle {
            return externalSubtitleURL != nil
        }
        if !selectedSubtitleIDs.isEmpty {
            return true
        }
        return externalSubtitleURL != nil
    }

    var canMergeManually: Bool {
        !syncedFiles.isEmpty && targetURL != nil && status != .running && (targetProbe?.videoTracks.isEmpty == false)
    }

    var warningBannerSummary: String? {
        guard !warnings.isEmpty else { return nil }
        if warnings.count == 1 {
            return warnings[0].summary
        }
        return "\(warnings.count) audio-matching or pipeline warnings — \(warnings[0].summary)"
    }

    var selectedSourceAudioTrack: AudioTrack? {
        guard let tracks = sourceProbe?.audioTracks else { return nil }
        return tracks.first(where: { $0.id == selectedSourceAudioID }) ?? tracks.first
    }

    var selectedTargetAudioTrack: AudioTrack? {
        guard let tracks = targetProbe?.audioTracks else { return nil }
        return tracks.first(where: { $0.id == selectedTargetAudioID }) ?? tracks.first
    }

    var selectedEmbeddedSubtitles: [SubtitleTrack] {
        guard let tracks = sourceProbe?.supportedSubtitleTracks else { return [] }
        return tracks.filter { selectedSubtitleIDs.contains($0.id) }
    }

    func buildSubtitleTargets() -> [WorkerSubtitleTarget] {
        if useExternalSubtitle, let extURL = externalSubtitleURL {
            return [.external(url: extURL)]
        }
        let embedded = selectedEmbeddedSubtitles
        if !embedded.isEmpty {
            return embedded.map { .embedded($0) }
        }
        if let extURL = externalSubtitleURL {
            return [.external(url: extURL)]
        }
        return []
    }

    func buildExistingSyncedOutputs() -> [WorkerExistingSyncedOutput] {
        let embedded = selectedEmbeddedSubtitles
        return syncedFiles.enumerated().map { index, path in
            let meta = index < embedded.count ? embedded[index] : nil
            return WorkerExistingSyncedOutput(
                syncedPath: path,
                lang: meta?.lang ?? "und",
                title: meta?.title ?? "",
                default: meta?.default ?? (index == 0),
                forced: meta?.forced ?? false
            )
        }
    }

    func applyBatchRules(srcAudio: BatchTrackRule, dstAudio: BatchTrackRule, subRule: BatchTrackRule, force: Bool = false) {
        guard force || !hasCustomTrackOverrides else { return }
        if let srcTracks = sourceProbe?.audioTracks, let chosen = srcAudio.resolveAudio(in: srcTracks) {
            selectedSourceAudioID = chosen.id
        }
        if let dstTracks = targetProbe?.audioTracks, let chosen = dstAudio.resolveAudio(in: dstTracks) {
            selectedTargetAudioID = chosen.id
        }
        if !useExternalSubtitle, let subTracks = sourceProbe?.subtitleTracks {
            let chosen = subRule.resolveSubtitles(in: subTracks)
            if !chosen.isEmpty {
                selectedSubtitleIDs = Set(chosen.map(\.id))
            }
        }
        if force {
            hasCustomTrackOverrides = false
        }
    }

    func resetForRetry() {
        status = .pending
        stageDetail = ""
        progress = 0
        warnings.removeAll()
        metrics = nil
        errorMessage = nil
    }
}
