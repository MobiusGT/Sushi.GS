import Foundation

public enum AudioEncodeCodecOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case opus
    case aac
    case eac3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: "Opus"
        case .aac: "AAC"
        case .eac3: "EAC-3"
        }
    }
}

public enum OpusEncoderOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case libopus
    case opusenc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .libopus: "libopus (FFmpeg)"
        case .opusenc: "opusenc (opus-tools)"
        }
    }
}

public enum AudioTracksToEncodeOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case syncTargetOnly
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .syncTargetOnly: "Track Used for Sync"
        case .all: "All Lossless Tracks"
        }
    }
}

public enum ChaptersModeOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case auto
    case none
    case file

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "Automatic (from Source)"
        case .none: "Ignore Chapters"
        case .file: "External Chapters File"
        }
    }
}

public enum KeyframesSourceOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case none
    case auto
    case make
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Disabled"
        case .auto: "Auto (use cached or generate)"
        case .make: "Generate Fresh Keyframes"
        case .files: "External Keyframe Files"
        }
    }
}

public enum KeyframeSnapModeOption: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case shift
    case snap

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "Shift & Snap (All)"
        case .shift: "Shift Only"
        case .snap: "Snap Only"
        }
    }
}

public struct CodecBitrates: Codable, Hashable, Sendable {
    public var mono: String
    public var stereo: String
    public var surround51: String
    public var surround71: String

    public init(mono: String, stereo: String, surround51: String, surround71: String) {
        self.mono = mono
        self.stereo = stereo
        self.surround51 = surround51
        self.surround71 = surround71
    }
}

public struct AudioCodecProfile: Codable, Hashable, Sendable {
    public var encoder: String
    public var bitrates: CodecBitrates

    public init(encoder: String, bitrates: CodecBitrates) {
        self.encoder = encoder
        self.bitrates = bitrates
    }
}

public struct AudioEncodeSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var tracksScope: AudioTracksToEncodeOption
    public var codec: AudioEncodeCodecOption
    public var opusEncoder: OpusEncoderOption
    public var opusBitrates: CodecBitrates
    public var aacBitrates: CodecBitrates
    public var eac3Bitrates: CodecBitrates

    public init(
        enabled: Bool = false,
        tracksScope: AudioTracksToEncodeOption = .syncTargetOnly,
        codec: AudioEncodeCodecOption = .opus,
        opusEncoder: OpusEncoderOption = .libopus,
        opusBitrates: CodecBitrates = CodecBitrates(mono: "64k", stereo: "128k", surround51: "320k", surround71: "448k"),
        aacBitrates: CodecBitrates = CodecBitrates(mono: "64k", stereo: "192k", surround51: "448k", surround71: "640k"),
        eac3Bitrates: CodecBitrates = CodecBitrates(mono: "96k", stereo: "224k", surround51: "448k", surround71: "768k")
    ) {
        self.enabled = enabled
        self.tracksScope = tracksScope
        self.codec = codec
        self.opusEncoder = opusEncoder
        self.opusBitrates = opusBitrates
        self.aacBitrates = aacBitrates
        self.eac3Bitrates = eac3Bitrates
    }

    public var activeBitrates: CodecBitrates {
        get {
            switch codec {
            case .opus: opusBitrates
            case .aac: aacBitrates
            case .eac3: eac3Bitrates
            }
        }
        set {
            switch codec {
            case .opus: opusBitrates = newValue
            case .aac: aacBitrates = newValue
            case .eac3: eac3Bitrates = newValue
            }
        }
    }
}

public struct SushiAdvancedArgs: Codable, Hashable, Sendable {
    public var window: Int
    public var maxWindow: Int
    public var rewindThresh: Int
    public var smoothRadius: Int
    public var maxTsDuration: Double
    public var maxTsDistance: Double

    public init(
        window: Int = 10,
        maxWindow: Int = 30,
        rewindThresh: Int = 5,
        smoothRadius: Int = 3,
        maxTsDuration: Double = 0.417,
        maxTsDistance: Double = 0.417
    ) {
        self.window = window
        self.maxWindow = maxWindow
        self.rewindThresh = rewindThresh
        self.smoothRadius = smoothRadius
        self.maxTsDuration = maxTsDuration
        self.maxTsDistance = maxTsDistance
    }
}

public struct SyncSettings: Codable, Hashable, Sendable {
    public var useHighQualityResample: Bool
    public var enableAdvancedArgs: Bool
    public var advancedArgs: SushiAdvancedArgs
    public var grouping: Bool
    public var chaptersMode: ChaptersModeOption
    public var chaptersFile: String
    public var keyframesSource: KeyframesSourceOption
    public var srcKeyframesFile: String
    public var dstKeyframesFile: String
    public var maxKfDistance: Double
    public var kfMode: KeyframeSnapModeOption
    public var srcFps: String
    public var dstFps: String
    public var verboseLogging: Bool

    public init(
        useHighQualityResample: Bool = true,
        enableAdvancedArgs: Bool = false,
        advancedArgs: SushiAdvancedArgs = SushiAdvancedArgs(),
        grouping: Bool = true,
        chaptersMode: ChaptersModeOption = .auto,
        chaptersFile: String = "",
        keyframesSource: KeyframesSourceOption = .none,
        srcKeyframesFile: String = "",
        dstKeyframesFile: String = "",
        maxKfDistance: Double = 2.0,
        kfMode: KeyframeSnapModeOption = .all,
        srcFps: String = "",
        dstFps: String = "",
        verboseLogging: Bool = false
    ) {
        self.useHighQualityResample = useHighQualityResample
        self.enableAdvancedArgs = enableAdvancedArgs
        self.advancedArgs = advancedArgs
        self.grouping = grouping
        self.chaptersMode = chaptersMode
        self.chaptersFile = chaptersFile
        self.keyframesSource = keyframesSource
        self.srcKeyframesFile = srcKeyframesFile
        self.dstKeyframesFile = dstKeyframesFile
        self.maxKfDistance = maxKfDistance
        self.kfMode = kfMode
        self.srcFps = srcFps
        self.dstFps = dstFps
        self.verboseLogging = verboseLogging
    }
}

public struct MergeSourceSettings: Codable, Hashable, Sendable {
    public var copyAttachments: Bool
    public var copyChapters: Bool
    public var copyGlobalTags: Bool
    public var copyTrackTags: Bool

    public init(
        copyAttachments: Bool = true,
        copyChapters: Bool = false,
        copyGlobalTags: Bool = false,
        copyTrackTags: Bool = false
    ) {
        self.copyAttachments = copyAttachments
        self.copyChapters = copyChapters
        self.copyGlobalTags = copyGlobalTags
        self.copyTrackTags = copyTrackTags
    }
}

public struct MergeTargetSettings: Codable, Hashable, Sendable {
    public var onlyIncludeSyncAudioTrack: Bool
    public var copyAttachments: Bool
    public var copyChapters: Bool
    public var copySubtitles: Bool
    public var copyGlobalTags: Bool
    public var copyTrackTags: Bool

    public init(
        onlyIncludeSyncAudioTrack: Bool = false,
        copyAttachments: Bool = true,
        copyChapters: Bool = true,
        copySubtitles: Bool = true,
        copyGlobalTags: Bool = true,
        copyTrackTags: Bool = true
    ) {
        self.onlyIncludeSyncAudioTrack = onlyIncludeSyncAudioTrack
        self.copyAttachments = copyAttachments
        self.copyChapters = copyChapters
        self.copySubtitles = copySubtitles
        self.copyGlobalTags = copyGlobalTags
        self.copyTrackTags = copyTrackTags
    }
}

public struct MergeSyncedSubtitleSettings: Codable, Hashable, Sendable {
    public var setDefaultFlag: Bool
    public var setForcedFlag: Bool
    public var overrideTrackTitle: Bool
    public var customTrackTitle: String

    public init(
        setDefaultFlag: Bool = true,
        setForcedFlag: Bool = false,
        overrideTrackTitle: Bool = false,
        customTrackTitle: String = "Synced Sub"
    ) {
        self.setDefaultFlag = setDefaultFlag
        self.setForcedFlag = setForcedFlag
        self.overrideTrackTitle = overrideTrackTitle
        self.customTrackTitle = customTrackTitle
    }
}

public struct MergeSettings: Codable, Hashable, Sendable {
    public var autoMergeOnSync: Bool
    public var resampleSubsBeforeMerge: Bool
    public var deleteGeneratedFilesAfterMerge: Bool
    public var source: MergeSourceSettings
    public var target: MergeTargetSettings
    public var syncedSubtitle: MergeSyncedSubtitleSettings

    public init(
        autoMergeOnSync: Bool = false,
        resampleSubsBeforeMerge: Bool = false,
        deleteGeneratedFilesAfterMerge: Bool = false,
        source: MergeSourceSettings = MergeSourceSettings(),
        target: MergeTargetSettings = MergeTargetSettings(),
        syncedSubtitle: MergeSyncedSubtitleSettings = MergeSyncedSubtitleSettings()
    ) {
        self.autoMergeOnSync = autoMergeOnSync
        self.resampleSubsBeforeMerge = resampleSubsBeforeMerge
        self.deleteGeneratedFilesAfterMerge = deleteGeneratedFilesAfterMerge
        self.source = source
        self.target = target
        self.syncedSubtitle = syncedSubtitle
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    public var saveSushiLogs: Bool
    public var saveMergeLogs: Bool
    public var useCustomOutputDirectory: Bool
    public var customOutputDirectory: String
    public var sushiBatchGitRef: String

    public init(
        saveSushiLogs: Bool = true,
        saveMergeLogs: Bool = true,
        useCustomOutputDirectory: Bool = false,
        customOutputDirectory: String = "",
        sushiBatchGitRef: String = ""
    ) {
        self.saveSushiLogs = saveSushiLogs
        self.saveMergeLogs = saveMergeLogs
        self.useCustomOutputDirectory = useCustomOutputDirectory
        self.customOutputDirectory = customOutputDirectory
        self.sushiBatchGitRef = sushiBatchGitRef
    }
}

public struct AppConfiguration: Codable, Hashable, Sendable {
    public var general: GeneralSettings
    public var sync: SyncSettings
    public var merge: MergeSettings
    public var audioEncode: AudioEncodeSettings
    public var binaryOverrides: [String: String]

    public init(
        general: GeneralSettings = GeneralSettings(),
        sync: SyncSettings = SyncSettings(),
        merge: MergeSettings = MergeSettings(),
        audioEncode: AudioEncodeSettings = AudioEncodeSettings(),
        binaryOverrides: [String: String] = [:]
    ) {
        self.general = general
        self.sync = sync
        self.merge = merge
        self.audioEncode = audioEncode
        self.binaryOverrides = binaryOverrides
    }

    public var effectiveOutputDirectory: String? {
        guard general.useCustomOutputDirectory else { return nil }
        let trimmed = general.customOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }
}

public struct JobPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sync: SyncSettings
    public var merge: MergeSettings
    public var audioEncode: AudioEncodeSettings
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sync: SyncSettings,
        merge: MergeSettings,
        audioEncode: AudioEncodeSettings,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sync = sync
        self.merge = merge
        self.audioEncode = audioEncode
        self.isBuiltIn = isBuiltIn
    }

    public static let builtInPresets: [JobPreset] = [
        JobPreset(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111101")!,
            name: "Standard Sync Only",
            sync: SyncSettings(useHighQualityResample: true),
            merge: MergeSettings(autoMergeOnSync: false),
            audioEncode: AudioEncodeSettings(enabled: false),
            isBuiltIn: true
        ),
        JobPreset(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111102")!,
            name: "Sync & Merge MKV",
            sync: SyncSettings(useHighQualityResample: true),
            merge: MergeSettings(autoMergeOnSync: true, deleteGeneratedFilesAfterMerge: false),
            audioEncode: AudioEncodeSettings(enabled: false),
            isBuiltIn: true
        ),
        JobPreset(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111103")!,
            name: "Blu-ray Sync + Opus + Merge",
            sync: SyncSettings(useHighQualityResample: true),
            merge: MergeSettings(autoMergeOnSync: true, deleteGeneratedFilesAfterMerge: true),
            audioEncode: AudioEncodeSettings(enabled: true, tracksScope: .syncTargetOnly, codec: .opus),
            isBuiltIn: true
        ),
    ]
}
