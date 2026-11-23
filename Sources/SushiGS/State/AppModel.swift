import AppKit
import Combine
import Foundation
import Observation
import SushiGSKit
import UniformTypeIdentifiers

enum SidebarDestination: String, CaseIterable, Identifiable {
    case singleEpisode
    case batchQueue
    case dependencies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleEpisode: "Single Episode"
        case .batchQueue: "Batch Queue"
        case .dependencies: "Dependencies"
        }
    }

    var symbol: String {
        switch self {
        case .singleEpisode: "film"
        case .batchQueue: "square.stack.3d.up"
        case .dependencies: "shippingbox"
        }
    }
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
    var showInspector = true

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

    // Batch Queue two-folder intake & Stage 2 queue state
    var batchSourceFolder: URL?
    var batchTargetFolder: URL?
    var stagedSourceMedia: [URL] = []
    var stagedSourceSubtitles: [URL] = []
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
        case .batchQueue:
            if let firstID = selectedBatchJobIDs.first,
               let match = batchJobs.first(where: { $0.id == firstID }) {
                return match
            }
            if let activeID = activeJobID,
               let active = batchJobs.first(where: { $0.id == activeID }) {
                return active
            }
            return batchJobs.first
        case .dependencies:
            return singleJob.sourceURL != nil ? singleJob : batchJobs.first
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
        case .batchQueue:
            if isRunning {
                let done = batchJobs.filter { $0.status == .succeeded || $0.status == .warned }.count
                return isPaused ? "Batch Paused · \(done)/\(batchJobs.count)" : "Syncing \(done + 1) of \(batchJobs.count)…"
            }
            if !isBatchInQueueStage {
                if hasStagedSource && !hasStagedTarget {
                    return "Batch Setup · Source Ready"
                }
                if !hasStagedSource && hasStagedTarget {
                    return "Batch Setup · Target Ready"
                }
                return "Batch Queue"
            }
            let count = batchJobs.count
            return count == 0 ? "Batch Queue" : "\(count) \(count == 1 ? "Episode" : "Episodes") Queued"
        case .dependencies:
            let missing = dependencies.missingRequiredDependencies.count
            return missing == 0 ? "Dependencies Ready" : "\(missing) Required Missing"
        }
    }

    // MARK: - Batch Intake & Verification Computed Helpers

    var hasStagedSource: Bool {
        batchSourceFolder != nil || !stagedSourceMedia.isEmpty
    }

    var hasStagedTarget: Bool {
        batchTargetFolder != nil || !stagedTargetMedia.isEmpty
    }

    var unverifiedBatchCount: Int {
        batchJobs.filter { !$0.isVerified && $0.sourceURL != nil && $0.targetURL != nil }.count
    }

    var batchNeedsClearConfirmation: Bool {
        isRunning || batchJobs.contains(where: { $0.status == .pending || $0.status == .running })
    }

    func requestClearBatchQueue() {
        guard !isRunning else { return }
        if batchNeedsClearConfirmation {
            sidebar = .batchQueue
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
            let probe = try await workerClient.probeMedia(fileURL: url, config: config)
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
            let probe = try await workerClient.probeMedia(fileURL: url, config: config)
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

    // MARK: - Batch Two-Folder Intake, Stage 2 Additions & Pair Verification

    /// Stage 1 / Stage 2 intake handler.
    /// In Stage 1, staging a single side keeps the user on the intake view with a filled/ready card
    /// and transitions automatically to Stage 2 only once BOTH Source and Target have media.
    func stageBatchInput(_ urls: [URL], asSource: Bool, replaceExisting: Bool = false) {
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
                } else if EpisodePairing.subtitleExtensions.contains(ext) {
                    subs.append(url)
                }
            }
        }

        if asSource {
            if replaceExisting || !isBatchInQueueStage {
                batchSourceFolder = pickedFolder ?? (media.count == 1 ? nil : batchSourceFolder)
                stagedSourceMedia = uniqueURLs(replaceExisting ? media : (isBatchInQueueStage ? stagedSourceMedia + media : media))
                stagedSourceSubtitles = uniqueURLs(replaceExisting ? subs : (isBatchInQueueStage ? stagedSourceSubtitles + subs : subs))
            } else {
                if let pickedFolder { batchSourceFolder = pickedFolder }
                stagedSourceMedia = uniqueURLs(stagedSourceMedia + media)
                stagedSourceSubtitles = uniqueURLs(stagedSourceSubtitles + subs)
            }
        } else {
            if replaceExisting || !isBatchInQueueStage {
                batchTargetFolder = pickedFolder ?? (media.count == 1 ? nil : batchTargetFolder)
                stagedTargetMedia = uniqueURLs(replaceExisting ? media : (isBatchInQueueStage ? stagedTargetMedia + media : media))
            } else {
                if let pickedFolder { batchTargetFolder = pickedFolder }
                stagedTargetMedia = uniqueURLs(stagedTargetMedia + media)
            }
        }

        // Transition to Stage 2 ONLY once both Source and Target are populated (or if already in Stage 2).
        if isBatchInQueueStage || (hasStagedSource && hasStagedTarget) {
            rebuildBatchPairsPreservingVerification()
            isBatchInQueueStage = true
        }
        syncMenuState()
    }

    func clearBatchSourceIntake() {
        batchSourceFolder = nil
        stagedSourceMedia = []
        stagedSourceSubtitles = []
        syncMenuState()
    }

    func clearBatchTargetIntake() {
        batchTargetFolder = nil
        stagedTargetMedia = []
        syncMenuState()
    }

    func pickBatchSourceFolder(replaceExisting: Bool = false) {
        guard let folder = pickFolder(title: "Select Source Folder") else { return }
        sidebar = .batchQueue
        stageBatchInput([folder], asSource: true, replaceExisting: replaceExisting)
    }

    func pickBatchTargetFolder(replaceExisting: Bool = false) {
        guard let folder = pickFolder(title: "Select Target Folder") else { return }
        sidebar = .batchQueue
        stageBatchInput([folder], asSource: false, replaceExisting: replaceExisting)
    }

    func clearBatchQueue() {
        guard !isRunning else { return }
        batchJobs = []
        selectedBatchJobIDs = []
        batchSourceFolder = nil
        batchTargetFolder = nil
        stagedSourceMedia = []
        stagedSourceSubtitles = []
        stagedTargetMedia = []
        isBatchInQueueStage = false
        highlightedLogID = nil
        highlightedLineIndex = nil
        statusNotice = "Cleared Batch Queue"
        syncMenuState()
    }

    private func rebuildBatchPairsPreservingVerification() {
        // Preserve manual verification and already-completed state for unchanged (source, target) pairs.
        var existingByPair: [String: EpisodeJob] = [:]
        for job in batchJobs {
            if let s = job.sourceURL?.path, let t = job.targetURL?.path {
                existingByPair["\(s)|\(t)"] = job
            }
        }

        let allSources = uniqueURLs(stagedSourceMedia + batchJobs.compactMap(\.sourceURL))
        let allTargets = uniqueURLs(stagedTargetMedia + batchJobs.compactMap(\.targetURL))
        let allSubs = uniqueURLs(stagedSourceSubtitles + batchJobs.compactMap(\.externalSubtitleURL))

        let drafts = EpisodePairing.pairFiles(sources: allSources, targets: allTargets, externalSubtitles: allSubs)
        let rebuilt: [EpisodeJob] = drafts.enumerated().map { idx, draft in
            if let s = draft.sourceFile?.path, let t = draft.targetFile?.path,
               let preserved = existingByPair["\(s)|\(t)"] {
                return preserved
            }
            return EpisodeJob(
                episodeBadge: draft.episodeKey?.displayBadge ?? String(format: "#%02d", idx + 1),
                matchKind: draft.matchKind,
                isVerified: draft.isVerified,
                sourceURL: draft.sourceFile,
                targetURL: draft.targetFile,
                externalSubtitleURL: draft.externalSubtitleFile,
                useExternalSubtitle: draft.externalSubtitleFile != nil
            )
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
        if let src = job.sourceURL, let dst = job.targetURL, EpisodePairing.isExactFilenameMatch(source: src, target: dst) {
            job.matchKind = .exactFilename
        }
        syncMenuState()
    }

    func verifyAllBatchPairs() {
        var changed = 0
        for job in batchJobs where !job.isVerified && job.sourceURL != nil && job.targetURL != nil {
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
            if let probe = try? await workerClient.probeMedia(fileURL: src, config: config) {
                job.sourceProbe = probe
            }
            job.isProbingSource = false
        }
        if let dst = job.targetURL {
            job.isProbingTarget = true
            if let probe = try? await workerClient.probeMedia(fileURL: dst, config: config) {
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

    func removeBatchJobs(ids: Set<UUID>, undoManager: UndoManager?) {
        let snapshot = batchJobs
        let oldSelection = selectedBatchJobIDs
        let oldStage = isBatchInQueueStage
        let removedIndices = batchJobs.enumerated().filter { ids.contains($0.element.id) }.map(\.offset)
        batchJobs.removeAll { ids.contains($0.id) }
        if let firstIdx = removedIndices.first, !batchJobs.isEmpty {
            let nextIdx = min(firstIdx, batchJobs.count - 1)
            selectedBatchJobIDs = [batchJobs[nextIdx].id]
        } else {
            selectedBatchJobIDs = []
            if batchJobs.isEmpty {
                isBatchInQueueStage = false
                batchSourceFolder = nil
                batchTargetFolder = nil
                stagedSourceMedia = []
                stagedSourceSubtitles = []
                stagedTargetMedia = []
            }
        }

        undoManager?.registerUndo(withTarget: self) { target in
            target.batchJobs = snapshot
            target.selectedBatchJobIDs = oldSelection
            target.isBatchInQueueStage = oldStage
        }
        undoManager?.setActionName("Remove Episodes")
    }

    func addEmptyBatchRow() {
        let row = EpisodeJob(
            episodeBadge: String(format: "#%02d", batchJobs.count + 1),
            matchKind: .unmatched,
            isVerified: false
        )
        batchJobs.append(row)
        isBatchInQueueStage = true
        selectedBatchJobIDs = [row.id]
    }

    // MARK: - Job Execution (Single & Batch Queue)

    func runPrimaryAction() {
        switch sidebar {
        case .singleEpisode:
            runSingleEpisode(mode: "sync")
        case .batchQueue:
            startBatchQueue()
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
        let runnable = batchJobs.filter { $0.hasRequiredInputs && ($0.status == .pending || $0.status == .cancelled) }
        guard !runnable.isEmpty else {
            statusNotice = "No ready episodes in queue. Use Retry to re-run failed or warned jobs."
            return
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
                guard job.hasRequiredInputs, job.status == .pending || job.status == .cancelled else { continue }
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
            }
        }
        workerClient.cancelActiveJob()
        syncMenuState()
    }

    func retryFailedOrWarned() {
        if sidebar == .singleEpisode {
            if singleJob.status == .failed || singleJob.status == .warned || singleJob.status == .cancelled {
                singleJob.resetForRetry()
                runSingleEpisode(mode: "sync")
            }
            return
        }
        var count = 0
        for job in batchJobs where job.status == .failed || job.status == .warned || job.status == .cancelled {
            job.resetForRetry()
            count += 1
        }
        if count > 0 {
            startBatchQueue()
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
        if sidebar == .singleEpisode {
            targets = singleJob.canMergeManually ? [singleJob] : []
        } else {
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

    func pickSingleFile(title: String, allowedExtensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
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
        menu.canClearBatch = !isRunning && (isBatchInQueueStage || hasStagedSource || hasStagedTarget)
        menu.unverifiedBatchCount = unverifiedBatchCount

        switch sidebar {
        case .singleEpisode:
            menu.canRun = !isRunning && singleJob.hasRequiredInputs && dependencies.allRequiredReady
            menu.canRetry = !isRunning && (singleJob.status == .failed || singleJob.status == .warned || singleJob.status == .cancelled)
            menu.canMerge = !isRunning && singleJob.canMergeManually && dependencies.isInstalled(.mkvmerge)
        case .batchQueue:
            menu.canRun = !isRunning && isBatchInQueueStage && batchJobs.contains(where: { $0.hasRequiredInputs && ($0.status == .pending || $0.status == .cancelled) }) && dependencies.allRequiredReady
            menu.canRetry = !isRunning && isBatchInQueueStage && batchJobs.contains(where: { $0.status == .failed || $0.status == .warned || $0.status == .cancelled })
            menu.canMerge = !isRunning && isBatchInQueueStage && batchJobs.contains(where: \.canMergeManually) && dependencies.isInstalled(.mkvmerge)
        case .dependencies:
            menu.canRun = !dependencies.isBusy && !dependencies.allRequiredReady
            menu.canRetry = false
            menu.canMerge = false
        }
    }
}
