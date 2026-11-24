import AppKit
import Combine
import Foundation
import Observation
import SushiGSKit
import UniformTypeIdentifiers

enum SidebarDestination: String, CaseIterable, Identifiable {
    case singleEpisode
    case autoBatch
    case manualBatch
    case dependencies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleEpisode: "Single Episode"
        case .autoBatch: "Auto Batch"
        case .manualBatch: "Manual Batch"
        case .dependencies: "Dependencies"
        }
    }

    var symbol: String {
        switch self {
        case .singleEpisode: "film"
        case .autoBatch: "square.stack.3d.up"
        case .manualBatch: "rectangle.split.3x1"
        case .dependencies: "shippingbox"
        }
    }
}

enum BatchIntakeSlot {
    case sourceMedia
    case targetMedia
    case externalSubtitles
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case sync
    case merge
    case audio
    case dependencies
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sync: "Sync"
        case .merge: "Merge"
        case .audio: "Audio"
        case .dependencies: "Dependencies"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sync: "waveform.path"
        case .merge: "film.stack"
        case .audio: "waveform"
        case .dependencies: "shippingbox"
        case .appearance: "paintpalette"
        }
    }
}

enum LogScope: String, CaseIterable, Identifiable {
    case selectedJob
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedJob: "Selected"
        case .global: "Global"
        }
    }
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case warnings
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .warnings: "Warnings"
        case .errors: "Errors"
        }
    }
}

/// Bridges `@Observable` `AppModel` state into SwiftUI `.commands` so menu items
/// dynamically enable/disable without going stale (per `swift-swiftui` skill).
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published var canRun = false
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var canRetry = false
    @Published var canMerge = false
    @Published var canClearSingle = false
    @Published var canClearBatch = false
    @Published var canClearManualBatch = false
    @Published var unverifiedBatchCount = 0
    @Published var hasLogs = false
    @Published var selectedBatchCount = 0
}

@Observable
final class AppModel {
    let paths: AppPaths
    let workerClient: WorkerClient
    let dependencies: DependencyManager
    private let warningAnalyzer = WarningAnalyzer()

    var sidebar: SidebarDestination = .singleEpisode {
        didSet { syncMenuState() }
    }
    var settingsTab: SettingsTab = .general
    var showInspector = false

    // Inspector state
    var logScope: LogScope = .selectedJob
    var logFilter: LogFilter = .all
    var logSearch = ""
    var highlightedLogID: UUID?
    var highlightedLineIndex: Int?

    // Configuration & Presets
    var config: AppConfiguration {
        didSet { saveConfiguration() }
    }
    var presets: [JobPreset]
    var selectedPresetID: UUID?

    // Single Episode workspace
    var singleJob = EpisodeJob(episodeBadge: "Single")

    // Auto Batch intake & Stage 2 queue state
    var batchSubtitleMode: BatchSubtitleMode = .embedded {
        didSet { syncMenuState() }
    }
    var batchSourceFolder: URL?
    var batchTargetFolder: URL?
    var batchSubtitleFolder: URL?
    var stagedSourceMedia: [URL] = []
    var stagedExternalSubtitles: [URL] = []
    var stagedTargetMedia: [URL] = []
    var isBatchInQueueStage = false {
        didSet { syncMenuState() }
    }
    var batchJobs: [EpisodeJob] = [] {
        didSet { syncMenuState() }
    }
    var selectedBatchJobIDs: Set<UUID> = [] {
        didSet { syncMenuState() }
    }
    var batchSrcAudioRule = BatchTrackRule()
    var batchDstAudioRule = BatchTrackRule()
    var batchSubRule = BatchTrackRule()

    // Manual Batch column-pairing state & File Browser state
    var manualColumns = ManualBatchColumns()
    var manualJobs: [EpisodeJob] = [] {
        didSet { syncMenuState() }
    }
    var selectedManualRowIndex: Int? {
        didSet { syncMenuState() }
    }
    var selectedManualColumn: ManualBatchColumnKind?
    var selectedManualCellIDs: Set<UUID> = []
    var manualSrcAudioRule = BatchTrackRule()
    var manualDstAudioRule = BatchTrackRule()
    var manualSubRule = BatchTrackRule()
    var showClearManualBatchConfirmation = false

    // Lightweight Native File Browser state (Manual Batch inverted-L browser)
    var manualBrowserHistory = FileBrowserHistory()
    var manualBrowserRootURL: URL? { manualBrowserHistory.current }
    var manualBrowserFilter: FileBrowserFilter = .all
    var manualBrowserSearch: String = ""
    var manualBrowserExpandedPaths: Set<String> = []
    var manualBrowserSelection = FileBrowserSelectionState()
    var manualBrowserDirectoryCache: [String: [FileBrowserEntry]] = [:]
    var isSeededSyntheticBrowser = false

    // Shared media probe cache by file path so Manual Batch reorders resolve tracks immediately
    @ObservationIgnored private var probeCache: [String: MediaProbeResult] = [:]
    @ObservationIgnored private var manualProbeTask: Task<Void, Never>?

    // Queue runner state
    private(set) var isRunning = false {
        didSet { syncMenuState() }
    }
    private(set) var isPaused = false {
        didSet { syncMenuState() }
    }
    private(set) var isCancelling = false
    private(set) var activeJobID: UUID?
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    // Global log stream across all runs
    var globalLogs: [LogEntry] = [] {
        didSet { syncMenuState() }
    }
    @ObservationIgnored private var globalLineCounter = 0

    // Transient alert/toast feedback & confirmation sheets
    var statusNotice: String?
    var showClearBatchConfirmation = false

    init(paths: AppPaths = AppPaths.current()) {
        self.paths = paths
        try? paths.ensureDirectories()
        self.workerClient = WorkerClient(paths: paths)
        self.dependencies = DependencyManager(paths: paths, workerClient: workerClient)
        self.config = Self.loadConfiguration(from: paths.configFile)
        self.presets = Self.loadPresets(from: paths.presetsFile)
        self.selectedPresetID = presets.first?.id

        if ProcessInfo.processInfo.environment["APP_SEED"] == "1" {
            SeedData.populate(model: self)
        }
        syncMenuState()
    }

    // MARK: - Startup

    func bootstrapOnLaunch() async {
        if ProcessInfo.processInfo.environment["APP_SEED"] == "1" {
            return
        }
        await dependencies.refreshAll(config: config, checkRemoteUpdates: true)
        if !dependencies.allRequiredReady {
            sidebar = .dependencies
        }
        syncMenuState()
    }

    // MARK: - Active / Selected Job Helpers

    var focusedJob: EpisodeJob? {
        switch sidebar {
        case .singleEpisode:
            return singleJob
        case .autoBatch:
            if let firstID = selectedBatchJobIDs.first,
               let match = batchJobs.first(where: { $0.id == firstID }) {
                return match
            }
            if let activeID = activeJobID,
               let active = batchJobs.first(where: { $0.id == activeID }) {
                return active
            }
            return batchJobs.first
        case .manualBatch:
            if let idx = selectedManualRowIndex, manualJobs.indices.contains(idx) {
                return manualJobs[idx]
            }
            if let activeID = activeJobID,
               let active = manualJobs.first(where: { $0.id == activeID }) {
                return active
            }
            return manualJobs.first
        case .dependencies:
            if singleJob.sourceURL != nil { return singleJob }
            if let firstAuto = batchJobs.first { return firstAuto }
            return manualJobs.first
        }
    }

    var windowSubtitle: String {
        switch sidebar {
        case .singleEpisode:
            if singleJob.status == .running {
                return singleJob.stageDetail.isEmpty ? "Syncing Episode…" : singleJob.stageDetail
            }
            if let avg = singleJob.metrics?.formattedAverageShift {
                return "Single Episode · \(avg)"
            }
            return "Single Episode"
        case .autoBatch:
            if isRunning && batchJobs.contains(where: { $0.id == activeJobID }) {
                let done = batchJobs.filter { $0.status == .succeeded || $0.status == .warned }.count
                return isPaused ? "Auto Batch Paused · \(done)/\(batchJobs.count)" : "Syncing \(done + 1) of \(batchJobs.count)…"
            }
            if !isBatchInQueueStage {
                let progress = stagedFolderProgress
                if progress.ready > 0 && progress.ready < progress.total {
                    return "Auto Batch Setup · \(progress.ready)/\(progress.total) Folders Ready"
                }
                return "Auto Batch"
            }
            let count = batchJobs.count
            return count == 0 ? "Auto Batch" : "\(count) \(count == 1 ? "Episode" : "Episodes") Queued"
        case .manualBatch:
            if isRunning && manualJobs.contains(where: { $0.id == activeJobID }) {
                let total = manualJobs.filter(\.hasPairedFiles).count
                let done = manualJobs.filter { $0.status == .succeeded || $0.status == .warned }.count
                return isPaused ? "Manual Batch Paused · \(done)/\(total)" : "Syncing \(done + 1) of \(max(total, 1))…"
            }
            let totalRows = manualColumns.rowCount
            if totalRows == 0 {
                return "Manual Batch · \(manualColumns.subtitleMode.displayName)"
            }
            let complete = manualColumns.completeRowCount
            if complete == totalRows {
                return "\(complete) \(complete == 1 ? "Pair" : "Pairs") Ready"
            }
            return "\(totalRows) Rows · \(complete) Ready"
        case .dependencies:
            let missing = dependencies.missingRequiredDependencies.count
            return missing == 0 ? "Dependencies Ready" : "\(missing) Required Missing"
        }
    }

    // MARK: - Auto Batch Intake & Verification Computed Helpers

    var hasStagedSource: Bool {
        batchSourceFolder != nil || !stagedSourceMedia.isEmpty
    }

    var hasStagedTarget: Bool {
        batchTargetFolder != nil || !stagedTargetMedia.isEmpty
    }

    var hasStagedExternalSubtitles: Bool {
        batchSubtitleFolder != nil || !stagedExternalSubtitles.isEmpty
    }

    var hasAllRequiredBatchFolders: Bool {
        switch batchSubtitleMode {
        case .embedded:
            hasStagedSource && hasStagedTarget
        case .external:
            hasStagedSource && hasStagedTarget && hasStagedExternalSubtitles
        }
    }

    var hasAnyStagedBatchFolder: Bool {
        hasStagedSource || hasStagedTarget || (batchSubtitleMode == .external && hasStagedExternalSubtitles)
    }

    var stagedFolderProgress: (ready: Int, total: Int) {
        switch batchSubtitleMode {
        case .embedded:
            let count = (hasStagedSource ? 1 : 0) + (hasStagedTarget ? 1 : 0)
            return (count, 2)
        case .external:
            let count = (hasStagedSource ? 1 : 0) + (hasStagedTarget ? 1 : 0) + (hasStagedExternalSubtitles ? 1 : 0)
            return (count, 3)
        }
    }

    /// Folder opened by default when choosing or reselecting a Source Media file in Auto Batch.
    var effectiveBatchSourceDirectory: URL? {
        if let folder = batchSourceFolder { return folder }
        if let staged = stagedSourceMedia.first { return staged.deletingLastPathComponent() }
        if let jobSrc = batchJobs.compactMap(\.sourceURL).first { return jobSrc.deletingLastPathComponent() }
        return nil
    }

    /// Folder opened by default when choosing or reselecting a Target Media file in Auto Batch.
    var effectiveBatchTargetDirectory: URL? {
        if let folder = batchTargetFolder { return folder }
        if let staged = stagedTargetMedia.first { return staged.deletingLastPathComponent() }
        if let jobDst = batchJobs.compactMap(\.targetURL).first { return jobDst.deletingLastPathComponent() }
        return nil
    }

    /// Folder opened by default when choosing or reselecting an External Subtitle file in Auto Batch.
    var effectiveBatchSubtitleDirectory: URL? {
        if let folder = batchSubtitleFolder { return folder }
        if let staged = stagedExternalSubtitles.first { return staged.deletingLastPathComponent() }
        if let jobSub = batchJobs.compactMap(\.externalSubtitleURL).first { return jobSub.deletingLastPathComponent() }
        return effectiveBatchSourceDirectory
    }

    var unverifiedBatchCount: Int {
        batchJobs.filter { !$0.isVerified && $0.isComplete(for: batchSubtitleMode) }.count
    }

    var batchNeedsClearConfirmation: Bool {
        isRunning || batchJobs.contains(where: { $0.status == .pending || $0.status == .running })
    }

    func requestClearBatchQueue() {
        guard !isRunning else { return }
        if batchNeedsClearConfirmation {
            sidebar = .autoBatch
            showClearBatchConfirmation = true
        } else {
            clearBatchQueue()
        }
    }

    // MARK: - Persistence

    private static func loadConfiguration(from url: URL) -> AppConfiguration {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return decoded
    }

    func saveConfiguration() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: paths.configFile, options: .atomic)
        }
    }

    private static func loadPresets(from url: URL) -> [JobPreset] {
        var combined = JobPreset.builtInPresets
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([JobPreset].self, from: data) {
            let custom = saved.filter { !$0.isBuiltIn }
            combined.append(contentsOf: custom)
        }
        return combined
    }

    func savePresets() {
        let custom = presets.filter { !$0.isBuiltIn }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(custom) {
            try? data.write(to: paths.presetsFile, options: .atomic)
        }
    }

    func applyPreset(_ preset: JobPreset) {
        selectedPresetID = preset.id
        config.sync = preset.sync
        config.merge = preset.merge
        config.audioEncode = preset.audioEncode
        statusNotice = "Applied preset \"\(preset.name)\""
    }

    func saveCurrentAsPreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = JobPreset(
            name: name,
            sync: config.sync,
            merge: config.merge,
            audioEncode: config.audioEncode,
            isBuiltIn: false
        )
        presets.append(preset)
        selectedPresetID = preset.id
        savePresets()
        statusNotice = "Saved preset \"\(name)\""
    }

    func deletePreset(_ preset: JobPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id {
            selectedPresetID = presets.first?.id
        }
        savePresets()
    }

    // MARK: - Single Episode File, Track Inspection & Clean-Slate Clear

    func setSingleSource(_ url: URL) {
        singleJob.sourceURL = url
        singleJob.probeError = nil
        if let key = EpisodePairing.extractEpisodeKey(from: url.lastPathComponent) {
            singleJob.episodeBadge = key.displayBadge
        } else {
            singleJob.episodeBadge = "Single"
        }
        singleJob.resetForRetry()
        syncMenuState()
        Task { await probeSingleSource() }
    }

    func setSingleTarget(_ url: URL) {
        singleJob.targetURL = url
        singleJob.probeError = nil
        singleJob.resetForRetry()
        syncMenuState()
        Task { await probeSingleTarget() }
    }

    func setSingleExternalSubtitle(_ url: URL?) {
        singleJob.externalSubtitleURL = url
        singleJob.useExternalSubtitle = (url != nil)
        singleJob.resetForRetry()
        syncMenuState()
    }

    func clearSingleEpisode() {
        guard !isRunning else { return }
        singleJob = EpisodeJob(episodeBadge: "Single")
        highlightedLogID = nil
        highlightedLineIndex = nil
        statusNotice = "Cleared Single Episode workspace"
        syncMenuState()
    }

    func probeSingleSource() async {
        guard let url = singleJob.sourceURL else { return }
        singleJob.isProbingSource = true
        defer { singleJob.isProbingSource = false }
        do {
            let probe = try await probeMediaCached(fileURL: url)
            singleJob.sourceProbe = probe
            singleJob.probeError = nil
            if let defAudio = probe.audioTracks.first(where: \.default) ?? probe.audioTracks.first {
                singleJob.selectedSourceAudioID = defAudio.id
            }
            if !singleJob.useExternalSubtitle {
                if let defSub = probe.supportedSubtitleTracks.first(where: \.default) ?? probe.supportedSubtitleTracks.first {
                    singleJob.selectedSubtitleIDs = [defSub.id]
                } else {
                    singleJob.selectedSubtitleIDs = []
                }
            }
            syncMenuState()
        } catch {
            singleJob.probeError = error.localizedDescription
        }
    }

    func probeSingleTarget() async {
        guard let url = singleJob.targetURL else { return }
        singleJob.isProbingTarget = true
        defer { singleJob.isProbingTarget = false }
        do {
            let probe = try await probeMediaCached(fileURL: url)
            singleJob.targetProbe = probe
            singleJob.probeError = nil
            if let defAudio = probe.audioTracks.first(where: \.default) ?? probe.audioTracks.first {
                singleJob.selectedTargetAudioID = defAudio.id
            }
            syncMenuState()
        } catch {
            singleJob.probeError = error.localizedDescription
        }
    }

    private func probeMediaCached(fileURL: URL) async throws -> MediaProbeResult {
        if let cached = probeCache[fileURL.path] {
            return cached
        }
        let probe = try await workerClient.probeMedia(fileURL: fileURL, config: config)
        probeCache[fileURL.path] = probe
        return probe
    }

    // MARK: - Auto Batch Intake, Stage 2 Additions & Pair Verification

    /// Stage 1 / Stage 2 intake handler for Auto Batch.
    /// In Embedded mode, auto-transitions to Stage 2 once Source Media and Target Media folders are set.
    /// In External mode, auto-transitions to Stage 2 only once Source Media, Target Media, and Subtitle folders are all set.
    func stageBatchInput(_ urls: [URL], slot: BatchIntakeSlot, replaceExisting: Bool = false) {
        var media: [URL] = []
        var subs: [URL] = []
        var pickedFolder: URL?
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                pickedFolder = url
                let scanned = EpisodePairing.scanMediaFiles(in: url)
                media.append(contentsOf: scanned.media)
                subs.append(contentsOf: scanned.subtitles)
            } else {
                let ext = url.pathExtension.lowercased()
                if EpisodePairing.mediaExtensions.contains(ext) {
                    media.append(url)
                } else if EpisodePairing.subtitleExtensions.contains(ext), !url.lastPathComponent.contains(".sushi.") {
                    subs.append(url)
                }
            }
        }

        switch slot {
        case .sourceMedia:
            let inferredFolder = pickedFolder ?? media.first?.deletingLastPathComponent()
            if replaceExisting || !isBatchInQueueStage {
                batchSourceFolder = inferredFolder ?? batchSourceFolder
                stagedSourceMedia = uniqueURLs(replaceExisting ? media : (isBatchInQueueStage ? stagedSourceMedia + media : media))
            } else {
                if let inferredFolder { batchSourceFolder = inferredFolder }
                stagedSourceMedia = uniqueURLs(stagedSourceMedia + media)
            }
        case .targetMedia:
            let inferredFolder = pickedFolder ?? media.first?.deletingLastPathComponent()
            if replaceExisting || !isBatchInQueueStage {
                batchTargetFolder = inferredFolder ?? batchTargetFolder
                stagedTargetMedia = uniqueURLs(replaceExisting ? media : (isBatchInQueueStage ? stagedTargetMedia + media : media))
            } else {
                if let inferredFolder { batchTargetFolder = inferredFolder }
                stagedTargetMedia = uniqueURLs(stagedTargetMedia + media)
            }
        case .externalSubtitles:
            batchSubtitleMode = .external
            let inferredFolder = pickedFolder ?? subs.first?.deletingLastPathComponent()
            if replaceExisting || !isBatchInQueueStage {
                batchSubtitleFolder = inferredFolder ?? batchSubtitleFolder
                stagedExternalSubtitles = uniqueURLs(replaceExisting ? subs : (isBatchInQueueStage ? stagedExternalSubtitles + subs : subs))
            } else {
                if let inferredFolder { batchSubtitleFolder = inferredFolder }
                stagedExternalSubtitles = uniqueURLs(stagedExternalSubtitles + subs)
            }
        }

        if isBatchInQueueStage || hasAllRequiredBatchFolders {
            rebuildBatchPairsPreservingVerification()
            isBatchInQueueStage = true
        }
        syncMenuState()
    }

    func clearBatchSourceIntake() {
        batchSourceFolder = nil
        stagedSourceMedia = []
        syncMenuState()
    }

    func clearBatchTargetIntake() {
        batchTargetFolder = nil
        stagedTargetMedia = []
        syncMenuState()
    }

    func clearBatchSubtitleIntake() {
        batchSubtitleFolder = nil
        stagedExternalSubtitles = []
        syncMenuState()
    }

    func pickBatchSourceFolder(replaceExisting: Bool = false) {
        guard let folder = pickFolder(title: "Select Source Media Folder") else { return }
        sidebar = .autoBatch
        stageBatchInput([folder], slot: .sourceMedia, replaceExisting: replaceExisting)
    }

    func pickBatchTargetFolder(replaceExisting: Bool = false) {
        guard let folder = pickFolder(title: "Select Target Media Folder") else { return }
        sidebar = .autoBatch
        stageBatchInput([folder], slot: .targetMedia, replaceExisting: replaceExisting)
    }

    func pickBatchSubtitleFolder(replaceExisting: Bool = false) {
        guard let folder = pickFolder(title: "Select External Subtitle Folder") else { return }
        sidebar = .autoBatch
        stageBatchInput([folder], slot: .externalSubtitles, replaceExisting: replaceExisting)
    }

    /// Transitions immediately from Stage 1 intake into Stage 2 queue.
    /// Populates all files from any 1 or 2 populated folders (pairing any 2 populated sides),
    /// or opens Stage 2 with a single blank editable row when 0 folders are populated.
    func continueToAutoBatchQueue() {
        let hasAnyStagedFiles = !stagedSourceMedia.isEmpty
            || !stagedTargetMedia.isEmpty
            || (batchSubtitleMode == .external && !stagedExternalSubtitles.isEmpty)
        if hasAnyStagedFiles {
            rebuildBatchPairsPreservingVerification()
            isBatchInQueueStage = true
            syncMenuState()
        } else {
            addEmptyBatchRow()
        }
    }

    func clearBatchQueue() {
        guard !isRunning else { return }
        batchJobs = []
        selectedBatchJobIDs = []
        batchSourceFolder = nil
        batchTargetFolder = nil
        batchSubtitleFolder = nil
        stagedSourceMedia = []
        stagedExternalSubtitles = []
        stagedTargetMedia = []
        isBatchInQueueStage = false
        highlightedLogID = nil
        highlightedLineIndex = nil
        statusNotice = "Cleared Auto Batch queue"
        syncMenuState()
    }

    private func rebuildBatchPairsPreservingVerification() {
        var existingByFullKey: [String: EpisodeJob] = [:]
        var existingByMediaKey: [String: EpisodeJob] = [:]
        for job in batchJobs {
            let s = job.sourceURL?.path ?? ""
            let t = job.targetURL?.path ?? ""
            let sub = job.externalSubtitleURL?.path ?? ""
            if !s.isEmpty || !t.isEmpty || !sub.isEmpty {
                existingByFullKey["\(s)|\(t)|\(sub)"] = job
            }
            if !s.isEmpty && !t.isEmpty {
                existingByMediaKey["\(s)|\(t)"] = job
            }
        }

        let allSources = uniqueURLs(stagedSourceMedia + batchJobs.compactMap(\.sourceURL))
        let allTargets = uniqueURLs(stagedTargetMedia + batchJobs.compactMap(\.targetURL))
        let allSubs = batchSubtitleMode == .external
            ? uniqueURLs(stagedExternalSubtitles + batchJobs.compactMap(\.externalSubtitleURL))
            : []

        let drafts = EpisodePairing.pairFiles(
            sources: allSources,
            targets: allTargets,
            externalSubtitles: allSubs,
            subtitleMode: batchSubtitleMode
        )

        let rebuilt: [EpisodeJob] = drafts.enumerated().map { idx, draft in
            let s = draft.sourceFile?.path ?? ""
            let t = draft.targetFile?.path ?? ""
            let sub = draft.externalSubtitleFile?.path ?? ""

            if let preserved = existingByFullKey["\(s)|\(t)|\(sub)"] {
                if batchSubtitleMode == .external {
                    preserved.useExternalSubtitle = true
                }
                return preserved
            }

            if !s.isEmpty && !t.isEmpty, let preserved = existingByMediaKey["\(s)|\(t)"] {
                preserved.externalSubtitleURL = draft.externalSubtitleFile
                preserved.useExternalSubtitle = (batchSubtitleMode == .external) || (draft.externalSubtitleFile != nil)
                preserved.matchKind = draft.matchKind
                preserved.isVerified = draft.isVerified
                return preserved
            }

            let job = EpisodeJob(
                episodeBadge: draft.episodeKey?.displayBadge ?? String(format: "#%02d", idx + 1),
                matchKind: draft.matchKind,
                isVerified: draft.isVerified,
                sourceURL: draft.sourceFile,
                targetURL: draft.targetFile,
                externalSubtitleURL: draft.externalSubtitleFile,
                useExternalSubtitle: batchSubtitleMode == .external || draft.externalSubtitleFile != nil
            )
            if let src = job.sourceURL, let cached = probeCache[src.path] {
                job.sourceProbe = cached
            }
            if let dst = job.targetURL, let cached = probeCache[dst.path] {
                job.targetProbe = cached
            }
            job.applyBatchRules(srcAudio: batchSrcAudioRule, dstAudio: batchDstAudioRule, subRule: batchSubRule)
            return job
        }
        batchJobs = rebuilt
        if selectedBatchJobIDs.isEmpty, let first = rebuilt.first {
            selectedBatchJobIDs = [first.id]
        }
        Task { await probeAllBatchJobs() }
    }

    func toggleVerification(for job: EpisodeJob) {
        job.isVerified.toggle()
        syncMenuState()
    }

    func markVerified(_ job: EpisodeJob) {
        job.isVerified = true
        if let src = job.sourceURL, let dst = job.targetURL,
           EpisodePairing.isExactFilenameMatch(source: src, target: dst) {
            if batchSubtitleMode == .external {
                if let sub = job.externalSubtitleURL,
                   EpisodePairing.isExactFilenameMatch(source: src, target: sub) {
                    job.matchKind = .exactFilename
                } else {
                    job.matchKind = .episodeRegex
                }
            } else {
                job.matchKind = .exactFilename
            }
        }
        syncMenuState()
    }

    func verifyAllBatchPairs() {
        var changed = 0
        for job in batchJobs where !job.isVerified && job.isComplete(for: batchSubtitleMode) {
            job.isVerified = true
            changed += 1
        }
        if changed > 0 {
            statusNotice = "Verified \(changed) episode \(changed == 1 ? "pair" : "pairs")"
        }
        syncMenuState()
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    func probeAllBatchJobs() async {
        for job in batchJobs where (job.sourceURL != nil && job.sourceProbe == nil) || (job.targetURL != nil && job.targetProbe == nil) {
            await probeBatchJob(job)
        }
        syncMenuState()
    }

    func probeBatchJob(_ job: EpisodeJob) async {
        if let src = job.sourceURL {
            job.isProbingSource = true
            if let probe = try? await probeMediaCached(fileURL: src) {
                job.sourceProbe = probe
            }
            job.isProbingSource = false
        }
        if let dst = job.targetURL {
            job.isProbingTarget = true
            if let probe = try? await probeMediaCached(fileURL: dst) {
                job.targetProbe = probe
            }
            job.isProbingTarget = false
        }
        job.applyBatchRules(srcAudio: batchSrcAudioRule, dstAudio: batchDstAudioRule, subRule: batchSubRule)
    }

    func applyBatchTrackRulesToAll() {
        for job in batchJobs {
            job.applyBatchRules(srcAudio: batchSrcAudioRule, dstAudio: batchDstAudioRule, subRule: batchSubRule, force: true)
        }
        statusNotice = "Applied batch track rules to \(batchJobs.count) episode(s)"
    }

    func reselectBatchSource(for job: EpisodeJob) {
        guard job.status != .running else { return }
        guard let url = pickSingleFile(
            title: "Choose Source Media",
            allowedExtensions: Array(EpisodePairing.mediaExtensions),
            initialDirectory: effectiveBatchSourceDirectory
        ) else { return }

        if let previous = job.sourceURL {
            stagedSourceMedia.removeAll { $0.path == previous.path }
        }
        job.sourceURL = url
        job.sourceProbe = nil
        job.selectedSourceAudioID = nil
        job.selectedSubtitleIDs = []
        if batchSourceFolder == nil {
            batchSourceFolder = url.deletingLastPathComponent()
        }
        stagedSourceMedia = uniqueURLs(stagedSourceMedia + [url])
        if let key = EpisodePairing.extractEpisodeKey(from: url.lastPathComponent),
           job.episodeBadge.isEmpty || job.episodeBadge.hasPrefix("#") {
            job.episodeBadge = key.displayBadge
        }
        if job.isComplete(for: batchSubtitleMode) {
            markVerified(job)
        } else {
            job.matchKind = .unmatched
            job.isVerified = false
            syncMenuState()
        }
        Task { await probeBatchJob(job) }
    }

    func reselectBatchTarget(for job: EpisodeJob) {
        guard job.status != .running else { return }
        guard let url = pickSingleFile(
            title: "Choose Target Media",
            allowedExtensions: Array(EpisodePairing.mediaExtensions),
            initialDirectory: effectiveBatchTargetDirectory
        ) else { return }

        if let previous = job.targetURL {
            stagedTargetMedia.removeAll { $0.path == previous.path }
        }
        job.targetURL = url
        job.targetProbe = nil
        job.selectedTargetAudioID = nil
        if batchTargetFolder == nil {
            batchTargetFolder = url.deletingLastPathComponent()
        }
        stagedTargetMedia = uniqueURLs(stagedTargetMedia + [url])
        if job.isComplete(for: batchSubtitleMode) {
            markVerified(job)
        } else {
            job.matchKind = .unmatched
            job.isVerified = false
            syncMenuState()
        }
        Task { await probeBatchJob(job) }
    }

    func reselectBatchSubtitle(for job: EpisodeJob) {
        guard job.status != .running else { return }
        guard let url = pickSingleFile(
            title: "Choose External Subtitle",
            allowedExtensions: Array(EpisodePairing.subtitleExtensions),
            initialDirectory: effectiveBatchSubtitleDirectory
        ) else { return }

        if let previous = job.externalSubtitleURL {
            stagedExternalSubtitles.removeAll { $0.path == previous.path }
        }
        job.externalSubtitleURL = url
        job.useExternalSubtitle = true
        if batchSubtitleFolder == nil {
            batchSubtitleFolder = url.deletingLastPathComponent()
        }
        stagedExternalSubtitles = uniqueURLs(stagedExternalSubtitles + [url])
        if job.isComplete(for: batchSubtitleMode) {
            markVerified(job)
        } else {
            job.matchKind = .unmatched
            job.isVerified = false
            syncMenuState()
        }
    }

    func removeBatchSource(for job: EpisodeJob) {
        guard job.status != .running else { return }
        if let previous = job.sourceURL {
            stagedSourceMedia.removeAll { $0.path == previous.path }
        }
        job.sourceURL = nil
        job.sourceProbe = nil
        job.selectedSourceAudioID = nil
        job.selectedSubtitleIDs = []
        job.matchKind = .unmatched
        job.isVerified = false
        job.resetForRetry()
        syncMenuState()
    }

    func removeBatchTarget(for job: EpisodeJob) {
        guard job.status != .running else { return }
        if let previous = job.targetURL {
            stagedTargetMedia.removeAll { $0.path == previous.path }
        }
        job.targetURL = nil
        job.targetProbe = nil
        job.selectedTargetAudioID = nil
        job.matchKind = .unmatched
        job.isVerified = false
        job.resetForRetry()
        syncMenuState()
    }

    func removeBatchSubtitle(for job: EpisodeJob) {
        guard job.status != .running else { return }
        if let previous = job.externalSubtitleURL {
            stagedExternalSubtitles.removeAll { $0.path == previous.path }
        }
        job.externalSubtitleURL = nil
        if batchSubtitleMode == .external {
            job.useExternalSubtitle = true
            job.matchKind = .unmatched
            job.isVerified = false
            job.resetForRetry()
        } else {
            job.useExternalSubtitle = false
        }
        syncMenuState()
    }

    func removeBatchJob(_ job: EpisodeJob, undoManager: UndoManager?) {
        guard job.status != .running else { return }
        removeBatchJobs(ids: [job.id], undoManager: undoManager)
    }

    func removeBatchJobs(ids: Set<UUID>, undoManager: UndoManager?) {
        let removableIDs = ids.filter { id in
            batchJobs.first(where: { $0.id == id })?.status != .running
        }
        guard !removableIDs.isEmpty else { return }

        let snapshot = batchJobs
        let oldSelection = selectedBatchJobIDs
        let oldStage = isBatchInQueueStage
        let oldSources = stagedSourceMedia
        let oldTargets = stagedTargetMedia
        let oldSubs = stagedExternalSubtitles
        let oldSrcFolder = batchSourceFolder
        let oldDstFolder = batchTargetFolder
        let oldSubFolder = batchSubtitleFolder

        let removedJobs = batchJobs.filter { removableIDs.contains($0.id) }
        let removedSourcePaths = Set(removedJobs.compactMap { $0.sourceURL?.path })
        let removedTargetPaths = Set(removedJobs.compactMap { $0.targetURL?.path })
        let removedSubPaths = Set(removedJobs.compactMap { $0.externalSubtitleURL?.path })

        let removedIndices = batchJobs.enumerated().filter { removableIDs.contains($0.element.id) }.map(\.offset)
        batchJobs.removeAll { removableIDs.contains($0.id) }
        stagedSourceMedia.removeAll { removedSourcePaths.contains($0.path) }
        stagedTargetMedia.removeAll { removedTargetPaths.contains($0.path) }
        stagedExternalSubtitles.removeAll { removedSubPaths.contains($0.path) }

        if let firstIdx = removedIndices.first, !batchJobs.isEmpty {
            let nextIdx = min(firstIdx, batchJobs.count - 1)
            selectedBatchJobIDs = [batchJobs[nextIdx].id]
        } else {
            selectedBatchJobIDs = []
            if batchJobs.isEmpty {
                isBatchInQueueStage = false
                batchSourceFolder = nil
                batchTargetFolder = nil
                batchSubtitleFolder = nil
                stagedSourceMedia = []
                stagedExternalSubtitles = []
                stagedTargetMedia = []
            }
        }

        undoManager?.registerUndo(withTarget: self) { target in
            target.batchJobs = snapshot
            target.selectedBatchJobIDs = oldSelection
            target.isBatchInQueueStage = oldStage
            target.stagedSourceMedia = oldSources
            target.stagedTargetMedia = oldTargets
            target.stagedExternalSubtitles = oldSubs
            target.batchSourceFolder = oldSrcFolder
            target.batchTargetFolder = oldDstFolder
            target.batchSubtitleFolder = oldSubFolder
        }
        undoManager?.setActionName("Remove Episodes")
        syncMenuState()
    }

    func addEmptyBatchRow() {
        let row = EpisodeJob(
            episodeBadge: String(format: "#%02d", batchJobs.count + 1),
            matchKind: .unmatched,
            isVerified: false,
            useExternalSubtitle: batchSubtitleMode == .external
        )
        batchJobs.append(row)
        isBatchInQueueStage = true
        selectedBatchJobIDs = [row.id]
    }

    // MARK: - Manual Batch File Browser

    func chooseManualBrowserFolder() {
        guard let folder = pickFolder(title: "Choose Folder for File Browser") else { return }
        sidebar = .manualBatch
        setManualBrowserRoot(folder)
    }

    func setManualBrowserRoot(_ url: URL) {
        var resolved = url.standardizedFileURL
        if !isSeededSyntheticBrowser {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue {
                resolved = resolved.deletingLastPathComponent()
            }
        }
        let staysSynthetic = isSeededSyntheticBrowser && manualBrowserDirectoryCache[resolved.path] != nil
        if !staysSynthetic {
            isSeededSyntheticBrowser = false
            manualBrowserDirectoryCache.removeAll()
        }
        manualBrowserHistory.navigate(to: resolved)
        manualBrowserExpandedPaths.removeAll()
        manualBrowserSelection.clear()
        if !staysSynthetic {
            refreshManualBrowserDirectory(resolved)
        }
    }

    func navigateManualBrowserBack() {
        guard let target = manualBrowserHistory.goBack() else { return }
        manualBrowserExpandedPaths.removeAll()
        manualBrowserSelection.clear()
        if !isSeededSyntheticBrowser {
            refreshManualBrowserDirectory(target)
        }
    }

    func navigateManualBrowserForward() {
        guard let target = manualBrowserHistory.goForward() else { return }
        manualBrowserExpandedPaths.removeAll()
        manualBrowserSelection.clear()
        if !isSeededSyntheticBrowser {
            refreshManualBrowserDirectory(target)
        }
    }

    func navigateManualBrowserUp() {
        guard let target = manualBrowserHistory.goUp() else { return }
        manualBrowserExpandedPaths.removeAll()
        manualBrowserSelection.clear()
        if !isSeededSyntheticBrowser {
            refreshManualBrowserDirectory(target)
        }
    }

    func refreshManualBrowser() {
        guard !isSeededSyntheticBrowser, let root = manualBrowserRootURL else { return }
        manualBrowserDirectoryCache.removeAll()
        refreshManualBrowserDirectory(root)
        for expandedPath in manualBrowserExpandedPaths {
            refreshManualBrowserDirectory(URL(fileURLWithPath: expandedPath))
        }
    }

    func toggleManualBrowserExpanded(_ path: String) {
        if manualBrowserExpandedPaths.contains(path) {
            manualBrowserExpandedPaths.remove(path)
        } else {
            manualBrowserExpandedPaths.insert(path)
            if !isSeededSyntheticBrowser, manualBrowserDirectoryCache[path] == nil {
                refreshManualBrowserDirectory(URL(fileURLWithPath: path))
            }
        }
    }

    func manualBrowserChildren(of directoryURL: URL) -> [FileBrowserEntry] {
        let raw: [FileBrowserEntry]
        if let cached = manualBrowserDirectoryCache[directoryURL.path] {
            raw = cached
        } else if isSeededSyntheticBrowser {
            raw = []
        } else {
            let scanned = FileBrowserScanner.listDirectory(directoryURL)
            manualBrowserDirectoryCache[directoryURL.path] = scanned
            raw = scanned
        }

        let trimmedQuery = manualBrowserSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.filter { entry in
            if !entry.isDirectory {
                switch manualBrowserFilter {
                case .all: break
                case .video: guard entry.isMedia else { return false }
                case .subtitles: guard entry.isSubtitle else { return false }
                }
            }
            if !trimmedQuery.isEmpty && !entry.name.localizedCaseInsensitiveContains(trimmedQuery) {
                return false
            }
            return true
        }
    }

    private func refreshManualBrowserDirectory(_ directoryURL: URL) {
        manualBrowserDirectoryCache[directoryURL.path] = FileBrowserScanner.listDirectory(directoryURL)
    }

    // MARK: - Manual Batch Columns & Pure Index-Based Pairing

    func setManualSubtitleMode(_ mode: BatchSubtitleMode) {
        guard manualColumns.subtitleMode != mode else { return }
        manualColumns.subtitleMode = mode
        if mode == .embedded && selectedManualColumn == .sourceSubtitle {
            selectedManualColumn = nil
            selectedManualCellIDs.removeAll()
        }
        syncManualJobs()
    }

    private func recordManualMutation(
        actionName: String,
        undoManager: UndoManager?,
        mutate: () -> Void
    ) {
        let previousColumns = manualColumns
        let previousRow = selectedManualRowIndex
        let previousCol = selectedManualColumn
        let previousCells = selectedManualCellIDs
        mutate()
        syncManualJobs()
        undoManager?.registerUndo(withTarget: self) { target in
            target.manualColumns = previousColumns
            target.selectedManualRowIndex = previousRow
            target.selectedManualColumn = previousCol
            target.selectedManualCellIDs = previousCells
            target.syncManualJobs()
        }
        undoManager?.setActionName(actionName)
    }

    func manualInsert(
        urls: [URL],
        into column: ManualBatchColumnKind,
        at index: Int? = nil,
        expandDirectories: Bool = true,
        undoManager: UndoManager? = nil
    ) {
        guard !isRunning else { return }
        var insertedIDs: [UUID] = []
        recordManualMutation(actionName: "Add to \(column.title)", undoManager: undoManager) {
            if column == .sourceSubtitle && manualColumns.subtitleMode != .external {
                manualColumns.subtitleMode = .external
            }
            insertedIDs = manualColumns.insert(
                urls: urls,
                into: column,
                at: index,
                expandDirectories: expandDirectories
            )
            if !insertedIDs.isEmpty {
                selectedManualColumn = column
                selectedManualCellIDs = Set(insertedIDs)
                if let firstID = insertedIDs.first,
                   let rowIdx = manualColumns.cells(in: column).firstIndex(where: { $0.id == firstID }) {
                    selectedManualRowIndex = rowIdx
                }
            }
        }
    }

    func manualPickFiles(for column: ManualBatchColumnKind, at index: Int? = nil, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        let urls = pickMultipleFiles(
            title: "Add Files to \(column.title)",
            allowedExtensions: Array(column.allowedExtensions),
            initialDirectory: manualBrowserRootURL
        )
        guard !urls.isEmpty else { return }
        manualInsert(urls: urls, into: column, at: index, expandDirectories: true, undoManager: undoManager)
    }

    func manualChooseFileForCell(in column: ManualBatchColumnKind, at index: Int, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        guard let url = pickSingleFile(
            title: "Choose File for \(column.title)",
            allowedExtensions: Array(column.allowedExtensions),
            initialDirectory: manualBrowserRootURL
        ) else { return }
        recordManualMutation(actionName: "Set \(column.title) File", undoManager: undoManager) {
            let cellID = manualColumns.setFile(url, in: column, at: index)
            selectedManualColumn = column
            selectedManualCellIDs = [cellID]
            selectedManualRowIndex = index
        }
    }

    func manualInsertBlankSlot(in column: ManualBatchColumnKind, at index: Int, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        recordManualMutation(actionName: "Insert Blank Slot", undoManager: undoManager) {
            let id = manualColumns.insertBlankSlot(in: column, at: index)
            selectedManualColumn = column
            selectedManualCellIDs = [id]
            selectedManualRowIndex = index
        }
    }

    func manualMoveCell(in column: ManualBatchColumnKind, from sourceIndex: Int, to destinationIndex: Int, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        recordManualMutation(actionName: "Reorder \(column.title)", undoManager: undoManager) {
            manualColumns.moveCell(in: column, from: sourceIndex, to: destinationIndex)
            let clamped = max(0, min(sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex, manualColumns.cells(in: column).count - 1))
            if manualColumns.cells(in: column).indices.contains(clamped) {
                selectedManualColumn = column
                selectedManualCellIDs = [manualColumns.cells(in: column)[clamped].id]
                selectedManualRowIndex = clamped
            }
        }
    }

    func manualMoveCells(in column: ManualBatchColumnKind, ids: Set<UUID>, to destinationIndex: Int, undoManager: UndoManager? = nil) {
        guard !isRunning, !ids.isEmpty else { return }
        recordManualMutation(actionName: "Reorder \(column.title)", undoManager: undoManager) {
            manualColumns.moveCells(in: column, ids: ids, to: destinationIndex)
            selectedManualColumn = column
            selectedManualCellIDs = ids
            if let firstIdx = manualColumns.cells(in: column).firstIndex(where: { ids.contains($0.id) }) {
                selectedManualRowIndex = firstIdx
            }
        }
    }

    func manualMoveUp(in column: ManualBatchColumnKind, at index: Int, undoManager: UndoManager? = nil) {
        guard !isRunning, index > 0 else { return }
        recordManualMutation(actionName: "Move Up", undoManager: undoManager) {
            if manualColumns.moveUp(in: column, at: index) {
                selectedManualColumn = column
                selectedManualRowIndex = index - 1
                if let cell = manualColumns.cell(in: column, at: index - 1) {
                    selectedManualCellIDs = [cell.id]
                }
            }
        }
    }

    func manualMoveDown(in column: ManualBatchColumnKind, at index: Int, undoManager: UndoManager? = nil) {
        guard !isRunning, index + 1 < manualColumns.cells(in: column).count else { return }
        recordManualMutation(actionName: "Move Down", undoManager: undoManager) {
            if manualColumns.moveDown(in: column, at: index) {
                selectedManualColumn = column
                selectedManualRowIndex = index + 1
                if let cell = manualColumns.cell(in: column, at: index + 1) {
                    selectedManualCellIDs = [cell.id]
                }
            }
        }
    }

    func manualRemoveCell(in column: ManualBatchColumnKind, at index: Int, undoManager: UndoManager? = nil) {
        guard !isRunning, manualColumns.cells(in: column).indices.contains(index) else { return }
        let removedID = manualColumns.cells(in: column)[index].id
        recordManualMutation(actionName: "Remove from \(column.title)", undoManager: undoManager) {
            manualColumns.removeCell(in: column, at: index)
            selectedManualCellIDs.remove(removedID)
            let remaining = manualColumns.cells(in: column)
            if remaining.isEmpty {
                selectedManualCellIDs.removeAll()
                selectedManualRowIndex = manualColumns.rowCount > 0 ? min(index, manualColumns.rowCount - 1) : nil
            } else {
                let nextIdx = min(index, remaining.count - 1)
                selectedManualColumn = column
                selectedManualCellIDs = [remaining[nextIdx].id]
                selectedManualRowIndex = nextIdx
            }
        }
    }

    func manualRemoveSelectedCells(undoManager: UndoManager? = nil) {
        guard !isRunning, let col = selectedManualColumn, !selectedManualCellIDs.isEmpty else { return }
        let cells = manualColumns.cells(in: col)
        let firstRemovedIdx = cells.firstIndex(where: { selectedManualCellIDs.contains($0.id) }) ?? 0
        let idsToRemove = selectedManualCellIDs
        recordManualMutation(actionName: "Remove Items from \(col.title)", undoManager: undoManager) {
            manualColumns.removeCells(in: col, ids: idsToRemove)
            let remaining = manualColumns.cells(in: col)
            if remaining.isEmpty {
                selectedManualCellIDs.removeAll()
                selectedManualRowIndex = manualColumns.rowCount > 0 ? min(firstRemovedIdx, manualColumns.rowCount - 1) : nil
            } else {
                let nextIdx = min(firstRemovedIdx, remaining.count - 1)
                selectedManualCellIDs = [remaining[nextIdx].id]
                selectedManualRowIndex = nextIdx
            }
        }
    }

    func manualSortColumn(_ column: ManualBatchColumnKind, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        recordManualMutation(actionName: "Sort \(column.title)", undoManager: undoManager) {
            manualColumns.sortNaturally(in: column)
        }
    }

    func manualReverseColumn(_ column: ManualBatchColumnKind, undoManager: UndoManager? = nil) {
        guard !isRunning else { return }
        recordManualMutation(actionName: "Reverse \(column.title)", undoManager: undoManager) {
            manualColumns.reverse(in: column)
        }
    }

    func manualClearColumn(_ column: ManualBatchColumnKind, undoManager: UndoManager? = nil) {
        guard !isRunning, !manualColumns.cells(in: column).isEmpty else { return }
        recordManualMutation(actionName: "Clear \(column.title)", undoManager: undoManager) {
            manualColumns.clear(column: column)
            if selectedManualColumn == column {
                selectedManualCellIDs.removeAll()
            }
            if manualColumns.isEmpty {
                selectedManualRowIndex = nil
            }
        }
    }

    var manualBatchNeedsClearConfirmation: Bool {
        isRunning || manualJobs.contains(where: { $0.status == .running || ($0.hasPairedFiles && $0.status == .pending) })
    }

    func requestClearManualBatch() {
        guard !isRunning else { return }
        if manualBatchNeedsClearConfirmation && !manualColumns.isEmpty {
            sidebar = .manualBatch
            showClearManualBatchConfirmation = true
        } else {
            clearManualBatch()
        }
    }

    func clearManualBatch() {
        guard !isRunning else { return }
        manualColumns.clearAll()
        manualJobs = []
        selectedManualRowIndex = nil
        selectedManualColumn = nil
        selectedManualCellIDs = []
        highlightedLogID = nil
        highlightedLineIndex = nil
        statusNotice = "Cleared Manual Batch workspace"
        syncMenuState()
    }

    func applyManualTrackRulesToAll() {
        for job in manualJobs {
            job.applyBatchRules(srcAudio: manualSrcAudioRule, dstAudio: manualDstAudioRule, subRule: manualSubRule, force: true)
        }
        statusNotice = "Applied track rules to \(manualJobs.count) Manual Batch row(s)"
    }

    /// Reconciles `manualJobs` 1:1 with `manualColumns.rows`, preserving status, logs, warnings,
    /// probes, and track selections whenever the paired file tuple for a row is unchanged.
    func syncManualJobs() {
        let mode = manualColumns.subtitleMode
        var pool: [String: [EpisodeJob]] = [:]
        for job in manualJobs {
            let key = manualJobKey(
                src: job.sourceURL,
                dst: job.targetURL,
                sub: mode == .external ? job.externalSubtitleURL : nil,
                mode: mode
            )
            pool[key, default: []].append(job)
        }

        var nextJobs: [EpisodeJob] = []
        nextJobs.reserveCapacity(manualColumns.rowCount)

        for row in manualColumns.rows {
            let subURL = mode == .external ? row.subtitleURL : nil
            let key = manualJobKey(src: row.sourceURL, dst: row.targetURL, sub: subURL, mode: mode)
            let badge = "#\(row.index + 1)"

            if var list = pool[key], !list.isEmpty {
                let reused = list.removeFirst()
                pool[key] = list
                reused.episodeBadge = badge
                reused.useExternalSubtitle = (mode == .external)
                reused.externalSubtitleURL = subURL
                nextJobs.append(reused)
            } else {
                let job = EpisodeJob(
                    episodeBadge: badge,
                    matchKind: .exactFilename,
                    isVerified: true,
                    sourceURL: row.sourceURL,
                    targetURL: row.targetURL,
                    externalSubtitleURL: subURL,
                    useExternalSubtitle: (mode == .external)
                )
                if let src = row.sourceURL, let cached = probeCache[src.path] {
                    job.sourceProbe = cached
                }
                if let dst = row.targetURL, let cached = probeCache[dst.path] {
                    job.targetProbe = cached
                }
                job.applyBatchRules(srcAudio: manualSrcAudioRule, dstAudio: manualDstAudioRule, subRule: manualSubRule)
                nextJobs.append(job)
            }
        }

        manualJobs = nextJobs
        if let selected = selectedManualRowIndex, !nextJobs.indices.contains(selected) {
            selectedManualRowIndex = nextJobs.isEmpty ? nil : nextJobs.count - 1
        }
        syncMenuState()
        // Defer ffprobe inspection asynchronously past the drop frame so drag/reorder stays 120 fps.
        manualProbeTask?.cancel()
        manualProbeTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.probeAllManualJobs()
        }
    }

    private func manualJobKey(src: URL?, dst: URL?, sub: URL?, mode: BatchSubtitleMode) -> String {
        "\(mode.rawValue)|\(src?.path ?? "")|\(dst?.path ?? "")|\(sub?.path ?? "")"
    }

    func probeAllManualJobs() async {
        for job in manualJobs where (job.sourceURL != nil && job.sourceProbe == nil) || (job.targetURL != nil && job.targetProbe == nil) {
            await probeManualJob(job)
        }
        syncMenuState()
    }

    func probeManualJob(_ job: EpisodeJob) async {
        if let src = job.sourceURL {
            job.isProbingSource = true
            if let probe = try? await probeMediaCached(fileURL: src) {
                job.sourceProbe = probe
            }
            job.isProbingSource = false
        }
        if let dst = job.targetURL {
            job.isProbingTarget = true
            if let probe = try? await probeMediaCached(fileURL: dst) {
                job.targetProbe = probe
            }
            job.isProbingTarget = false
        }
        job.applyBatchRules(srcAudio: manualSrcAudioRule, dstAudio: manualDstAudioRule, subRule: manualSubRule)
    }

    // MARK: - Job Execution (Single, Auto Batch & Manual Batch)

    func runPrimaryAction() {
        switch sidebar {
        case .singleEpisode:
            runSingleEpisode(mode: "sync")
        case .autoBatch:
            startBatchQueue()
        case .manualBatch:
            startManualBatchQueue()
        case .dependencies:
            Task { await dependencies.installAllRequired(config: config) }
        }
    }

    func runSingleEpisode(mode: String = "sync") {
        guard !isRunning else { return }
        guard dependencies.allRequiredReady else {
            sidebar = .dependencies
            statusNotice = "Install required dependencies first."
            return
        }
        guard singleJob.hasRequiredInputs else {
            statusNotice = "Select a Source file, Target file, and subtitle before running."
            return
        }

        isRunning = true
        isPaused = false
        isCancelling = false
        cancelRequested = false
        runningTask = Task {
            defer {
                isRunning = false
                isCancelling = false
                cancelRequested = false
                activeJobID = nil
                syncMenuState()
            }
            await execute(job: singleJob, index: 1, mode: mode)
        }
    }

    func startBatchQueue() {
        guard !isRunning else {
            if isPaused { isPaused = false }
            return
        }
        guard dependencies.allRequiredReady else {
            sidebar = .dependencies
            statusNotice = "Install required dependencies first."
            return
        }
        let runnable = batchJobs.filter { $0.hasPairedFiles && ($0.status == .pending || $0.status == .cancelled) }
        guard !runnable.isEmpty else {
            statusNotice = "No ready episodes in queue. Use Retry to re-run failed or warned jobs."
            return
        }
        let skipped = batchJobs.filter { !$0.hasPairedFiles }.count
        if skipped > 0 {
            statusNotice = "Starting \(runnable.count) ready episode(s) (\(skipped) incomplete skipped)"
        }

        isRunning = true
        isPaused = false
        isCancelling = false
        cancelRequested = false
        runningTask = Task {
            defer {
                isRunning = false
                isPaused = false
                isCancelling = false
                cancelRequested = false
                activeJobID = nil
                syncMenuState()
            }
            for (idx, job) in batchJobs.enumerated() {
                if cancelRequested || Task.isCancelled { break }
                while isPaused && !cancelRequested && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if cancelRequested || Task.isCancelled { break }
                guard job.hasPairedFiles, job.status == .pending || job.status == .cancelled else { continue }
                if job.sourceProbe == nil || job.targetProbe == nil {
                    await probeBatchJob(job)
                }
                guard job.hasRequiredInputs else {
                    job.status = .failed
                    job.errorMessage = "No supported embedded or external subtitle available for this episode."
                    job.stageDetail = "Missing subtitle"
                    continue
                }
                await execute(job: job, index: idx + 1, mode: "sync")
                if cancelRequested { break }
            }
        }
    }

    func startManualBatchQueue() {
        guard !isRunning else {
            if isPaused { isPaused = false }
            return
        }
        guard dependencies.allRequiredReady else {
            sidebar = .dependencies
            statusNotice = "Install required dependencies first."
            return
        }
        let runnable = manualJobs.filter { $0.hasPairedFiles && ($0.status == .pending || $0.status == .cancelled) }
        guard !runnable.isEmpty else {
            let incomplete = manualColumns.incompleteRowCount
            if incomplete > 0 {
                statusNotice = "All \(incomplete) row(s) are incomplete. Fill every required column before starting."
            } else {
                statusNotice = "No ready pairs in Manual Batch. Use Retry Flagged to re-run failed or warned rows."
            }
            return
        }

        let skipped = manualColumns.incompleteRowCount
        if skipped > 0 {
            statusNotice = "Starting \(runnable.count) ready pair(s) (\(skipped) incomplete row(s) skipped)"
        }

        isRunning = true
        isPaused = false
        isCancelling = false
        cancelRequested = false
        runningTask = Task {
            defer {
                isRunning = false
                isPaused = false
                isCancelling = false
                cancelRequested = false
                activeJobID = nil
                syncMenuState()
            }
            for (idx, job) in manualJobs.enumerated() {
                if cancelRequested || Task.isCancelled { break }
                while isPaused && !cancelRequested && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if cancelRequested || Task.isCancelled { break }
                guard job.hasPairedFiles, job.status == .pending || job.status == .cancelled else { continue }
                if job.sourceProbe == nil || job.targetProbe == nil {
                    await probeManualJob(job)
                }
                guard job.hasRequiredInputs else {
                    job.status = .failed
                    job.errorMessage = "No supported embedded or external subtitle available for Pair #\(idx + 1)."
                    job.stageDetail = "Missing subtitle"
                    continue
                }
                await execute(job: job, index: idx + 1, mode: "sync")
                if cancelRequested { break }
            }
        }
    }

    func togglePauseQueue() {
        guard isRunning else { return }
        isPaused.toggle()
        syncMenuState()
    }

    /// Gracefully cancels the active job by signalling `worker.py` (SIGTERM) while keeping
    /// stdout streaming alive so the worker's cleanup log event appears in the Log Inspector.
    func cancelActiveJob() {
        guard isRunning, !isCancelling else { return }
        cancelRequested = true
        isCancelling = true
        if let activeID = activeJobID {
            if singleJob.id == activeID {
                singleJob.stageDetail = "Cancelling and cleaning up temporary files…"
            } else if let idx = batchJobs.firstIndex(where: { $0.id == activeID }) {
                batchJobs[idx].stageDetail = "Cancelling and cleaning up temporary files…"
            } else if let idx = manualJobs.firstIndex(where: { $0.id == activeID }) {
                manualJobs[idx].stageDetail = "Cancelling and cleaning up temporary files…"
            }
        }
        workerClient.cancelActiveJob()
        syncMenuState()
    }

    func retryFailedOrWarned() {
        switch sidebar {
        case .singleEpisode:
            if singleJob.status == .failed || singleJob.status == .warned || singleJob.status == .cancelled {
                singleJob.resetForRetry()
                runSingleEpisode(mode: "sync")
            }
        case .manualBatch:
            var count = 0
            for job in manualJobs where job.hasPairedFiles && (job.status == .failed || job.status == .warned || job.status == .cancelled) {
                job.resetForRetry()
                count += 1
            }
            if count > 0 {
                startManualBatchQueue()
            }
        case .autoBatch, .dependencies:
            var count = 0
            for job in batchJobs where job.hasPairedFiles && (job.status == .failed || job.status == .warned || job.status == .cancelled) {
                job.resetForRetry()
                count += 1
            }
            if count > 0 {
                startBatchQueue()
            }
        }
    }

    func mergeCompletedJobs() {
        guard !isRunning else { return }
        guard dependencies.isInstalled(.mkvmerge) else {
            sidebar = .dependencies
            statusNotice = "Install MKVMerge in Dependencies to merge MKV files."
            return
        }

        let targets: [EpisodeJob]
        switch sidebar {
        case .singleEpisode:
            targets = singleJob.canMergeManually ? [singleJob] : []
        case .manualBatch:
            if let idx = selectedManualRowIndex,
               manualJobs.indices.contains(idx),
               manualJobs[idx].canMergeManually {
                targets = [manualJobs[idx]]
            } else {
                targets = manualJobs.filter(\.canMergeManually)
            }
        case .autoBatch, .dependencies:
            let selected = batchJobs.filter { selectedBatchJobIDs.contains($0.id) && $0.canMergeManually }
            targets = selected.isEmpty ? batchJobs.filter(\.canMergeManually) : selected
        }

        guard !targets.isEmpty else {
            statusNotice = "No synced episodes are ready to merge yet."
            return
        }

        isRunning = true
        isCancelling = false
        cancelRequested = false
        runningTask = Task {
            defer {
                isRunning = false
                isCancelling = false
                cancelRequested = false
                activeJobID = nil
                syncMenuState()
            }
            for (idx, job) in targets.enumerated() {
                if cancelRequested || Task.isCancelled { break }
                await execute(job: job, index: idx + 1, mode: "merge")
                if cancelRequested { break }
            }
        }
    }

    private func execute(job: EpisodeJob, index: Int, mode: String) async {
        guard let srcURL = job.sourceURL, let dstURL = job.targetURL else { return }

        activeJobID = job.id
        job.status = .running
        job.progress = 0.02
        job.stageDetail = mode == "merge" ? "Preparing merge…" : "Starting Sushi worker…"
        job.errorMessage = nil
        if mode == "sync" {
            job.logs.removeAll()
            job.warnings.removeAll()
            job.metrics = nil
            job.syncedFiles.removeAll()
            job.mergedFilepath = nil
        }

        let effectiveConfig = sanitizedConfigForCapabilities(config)
        let payload = WorkerJobPayload(
            mode: mode,
            jobIndex: index,
            srcFilepath: srcURL.path,
            dstFilepath: dstURL.path,
            srcAudioStreamId: job.selectedSourceAudioID,
            dstAudioStreamId: job.selectedTargetAudioID,
            subtitleTargets: job.buildSubtitleTargets(),
            existingSyncedOutputs: job.buildExistingSyncedOutputs(),
            outputDir: effectiveConfig.effectiveOutputDirectory,
            paths: paths,
            config: effectiveConfig
        )

        var receivedResult: WorkerJobResult?
        var receivedError: String?

        do {
            let exitCode = try await workerClient.runJob(payload: payload) { [weak self, weak job] event in
                guard let self, let job else { return }
                switch event {
                case let .stage(_, detail, _):
                    if !self.cancelRequested {
                        job.stageDetail = detail
                    }
                case let .progress(fraction, _, _):
                    if !self.cancelRequested {
                        job.progress = fraction
                    }
                case let .log(source, severity, line, lineIndex, timestamp):
                    let entry = LogEntry(
                        lineIndex: lineIndex,
                        timestamp: timestamp,
                        source: source,
                        severity: severity,
                        line: line,
                        jobID: job.id
                    )
                    job.logs.append(entry)
                    self.appendGlobalLog(source: source, severity: severity, line: "[\(job.episodeBadge)] \(line)", jobID: job.id)
                case let .warning(code, summary, lineIndex, _):
                    if !job.warnings.contains(where: { $0.code == code && $0.lineIndex == lineIndex }) {
                        job.warnings.append(SyncWarning(code: code, summary: summary, lineIndex: lineIndex))
                    }
                case let .metrics(metrics, _):
                    job.metrics = metrics
                case let .jobResult(result):
                    receivedResult = result
                case let .error(code, message, _):
                    if code != "cancelled" {
                        receivedError = message
                        self.appendGlobalLog(source: "worker", severity: .error, line: "[\(job.episodeBadge)] \(message)", jobID: job.id)
                    }
                default:
                    break
                }
            }

            if cancelRequested || Task.isCancelled || exitCode == 130 || exitCode == 143 {
                job.status = .cancelled
                job.progress = 0
                job.stageDetail = "Cancelled · temporary files cleaned"
                job.errorMessage = nil
                return
            }

            if let res = receivedResult, res.ok, exitCode == 0 {
                if !res.syncedFiles.isEmpty {
                    job.syncedFiles = res.syncedFiles
                }
                if let merged = res.mergedFilepath {
                    job.mergedFilepath = merged
                }
                if let m = res.metrics {
                    job.metrics = m
                }
                job.sushiLogPath = res.sushiLogPath ?? job.sushiLogPath
                job.mergeLogPath = res.mergeLogPath ?? job.mergeLogPath

                let analyzed = warningAnalyzer.analyze(lines: job.logs.map(\.line))
                for w in analyzed.warnings {
                    if !job.warnings.contains(where: { $0.code == w.code && $0.lineIndex == w.lineIndex }) {
                        job.warnings.append(w)
                    }
                }
                if job.metrics == nil, analyzed.metrics.eventCount > 0 {
                    job.metrics = analyzed.metrics
                }

                job.progress = 1.0
                job.status = (res.hasWarnings || !job.warnings.isEmpty) ? .warned : .succeeded
                job.stageDetail = job.status == .warned ? "Completed with warnings" : "Done"
            } else {
                job.status = .failed
                job.errorMessage = receivedError ?? "Worker exited with code \(exitCode)."
                job.stageDetail = "Failed"
            }
        } catch {
            if cancelRequested {
                job.status = .cancelled
                job.progress = 0
                job.stageDetail = "Cancelled"
            } else {
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.stageDetail = "Failed"
                appendGlobalLog(source: "app", severity: .error, line: "[\(job.episodeBadge)] \(error.localizedDescription)", jobID: job.id)
            }
        }
    }

    private func sanitizedConfigForCapabilities(_ raw: AppConfiguration) -> AppConfiguration {
        var copy = raw
        if !dependencies.isInstalled(.aegisubCLI) {
            copy.merge.resampleSubsBeforeMerge = false
        }
        return copy
    }

    // MARK: - Logs & Inspector Navigation

    func appendGlobalLog(source: String, severity: LogSeverity, line: String, jobID: UUID? = nil) {
        let entry = LogEntry(
            lineIndex: globalLineCounter,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            source: source,
            severity: severity,
            line: line,
            jobID: jobID
        )
        globalLineCounter += 1
        globalLogs.append(entry)
        if globalLogs.count > 5000 {
            globalLogs.removeFirst(globalLogs.count - 5000)
        }
    }

    func activeLogEntries() -> [LogEntry] {
        let base: [LogEntry] = switch logScope {
        case .selectedJob:
            focusedJob?.logs ?? []
        case .global:
            globalLogs
        }

        let filteredBySeverity = base.filter { entry in
            switch logFilter {
            case .all: true
            case .warnings: entry.severity == .warning
            case .errors: entry.severity == .error
            }
        }

        let query = logSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filteredBySeverity }
        return filteredBySeverity.filter {
            $0.line.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query)
        }
    }

    func jumpToWarning(_ warning: SyncWarning, in job: EpisodeJob) {
        showInspector = true
        logScope = .selectedJob
        logFilter = .all
        logSearch = ""
        highlightedLineIndex = warning.lineIndex
        if let entry = job.logs.first(where: { $0.lineIndex == warning.lineIndex })
            ?? job.logs.first(where: { $0.severity == .warning }) {
            highlightedLogID = entry.id
        }
    }

    func copyCurrentLogsToPasteboard() {
        let text = activeLogEntries().map { "[\($0.source)] \($0.line)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusNotice = "Copied \(activeLogEntries().count) log line(s) to clipboard"
    }

    func exportCurrentLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        let baseName = focusedJob?.displayTitle ?? "GasStationSushi"
        panel.nameFieldStringValue = "\(baseName).log"
        if panel.runModal() == .OK, let url = panel.url {
            let text = activeLogEntries().map { "[\($0.timestamp)] [\($0.severity.rawValue.uppercased())] [\($0.source)] \($0.line)" }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            statusNotice = "Exported log to \(url.lastPathComponent)"
        }
    }

    // MARK: - File Pickers

    func openSingleSourcePanel() {
        if let url = pickSingleFile(title: "Select Source Media File", allowedExtensions: Array(EpisodePairing.mediaExtensions)) {
            sidebar = .singleEpisode
            setSingleSource(url)
        }
    }

    func openSingleTargetPanel() {
        if let url = pickSingleFile(title: "Select Target Media File", allowedExtensions: Array(EpisodePairing.mediaExtensions)) {
            sidebar = .singleEpisode
            setSingleTarget(url)
        }
    }

    func openSingleSubtitlePanel() {
        if let url = pickSingleFile(title: "Select External Subtitle File", allowedExtensions: Array(EpisodePairing.subtitleExtensions)) {
            sidebar = .singleEpisode
            setSingleExternalSubtitle(url)
        }
    }

    func pickSingleFile(title: String, allowedExtensions: [String], initialDirectory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickMultipleFiles(title: String, allowedExtensions: [String], initialDirectory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = initialDirectory
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : []
    }

    func pickFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickBinaryOverride(for id: DependencyID) {
        let panel = NSOpenPanel()
        panel.title = "Select \(id.displayName) Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url, let key = id.executableName {
            config.binaryOverrides[key] = url.path
            Task { await dependencies.refreshAll(config: config, checkRemoteUpdates: false) }
        }
    }

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Menu Synchronization

    func syncMenuState() {
        let menu = MenuState.shared
        menu.isRunning = isRunning
        menu.isPaused = isPaused
        menu.selectedBatchCount = selectedBatchJobIDs.count
        menu.hasLogs = !activeLogEntries().isEmpty
        menu.canClearSingle = !isRunning && singleJob.hasAnyStateToClear
        menu.canClearBatch = !isRunning && (isBatchInQueueStage || hasAnyStagedBatchFolder)
        menu.canClearManualBatch = !isRunning && !manualColumns.isEmpty
        menu.unverifiedBatchCount = unverifiedBatchCount

        switch sidebar {
        case .singleEpisode:
            menu.canRun = !isRunning && singleJob.hasRequiredInputs && dependencies.allRequiredReady
            menu.canRetry = !isRunning && (singleJob.status == .failed || singleJob.status == .warned || singleJob.status == .cancelled)
            menu.canMerge = !isRunning && singleJob.canMergeManually && dependencies.isInstalled(.mkvmerge)
        case .autoBatch:
            menu.canRun = !isRunning && isBatchInQueueStage && batchJobs.contains(where: { $0.hasPairedFiles && ($0.status == .pending || $0.status == .cancelled) }) && dependencies.allRequiredReady
            menu.canRetry = !isRunning && isBatchInQueueStage && batchJobs.contains(where: { $0.hasPairedFiles && ($0.status == .failed || $0.status == .warned || $0.status == .cancelled) })
            menu.canMerge = !isRunning && isBatchInQueueStage && batchJobs.contains(where: \.canMergeManually) && dependencies.isInstalled(.mkvmerge)
        case .manualBatch:
            menu.canRun = !isRunning && manualJobs.contains(where: { $0.hasPairedFiles && ($0.status == .pending || $0.status == .cancelled) }) && dependencies.allRequiredReady
            menu.canRetry = !isRunning && manualJobs.contains(where: { $0.hasPairedFiles && ($0.status == .failed || $0.status == .warned || $0.status == .cancelled) })
            menu.canMerge = !isRunning && manualJobs.contains(where: \.canMergeManually) && dependencies.isInstalled(.mkvmerge)
        case .dependencies:
            menu.canRun = !dependencies.isBusy && !dependencies.allRequiredReady
            menu.canRetry = false
            menu.canMerge = false
        }
    }
}
