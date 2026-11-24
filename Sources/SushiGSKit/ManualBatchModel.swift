import Foundation

/// Pairing column identifier in Manual Batch mode.
public enum ManualBatchColumnKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case sourceVideo
    case sourceSubtitle
    case targetVideo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sourceVideo: "Source Video"
        case .sourceSubtitle: "Source Subtitles"
        case .targetVideo: "Target Video"
        }
    }

    public var allowedExtensions: Set<String> {
        switch self {
        case .sourceVideo, .targetVideo:
            EpisodePairing.mediaExtensions
        case .sourceSubtitle:
            EpisodePairing.subtitleExtensions
        }
    }
}

/// One cell inside a Manual Batch pairing column.
/// `url == nil` represents an explicit blank alignment slot inserted by the user.
public struct ManualBatchCell: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL?

    public init(id: UUID = UUID(), url: URL? = nil) {
        self.id = id
        self.url = url
    }

    public var isBlankSlot: Bool {
        url == nil
    }
}

/// Snapshot of a single strict index-based row across Manual Batch columns.
public struct ManualBatchPairRow: Hashable, Sendable {
    public var index: Int
    public var sourceCell: ManualBatchCell?
    public var subtitleCell: ManualBatchCell?
    public var targetCell: ManualBatchCell?
    public var subtitleMode: BatchSubtitleMode

    public init(
        index: Int,
        sourceCell: ManualBatchCell?,
        subtitleCell: ManualBatchCell?,
        targetCell: ManualBatchCell?,
        subtitleMode: BatchSubtitleMode
    ) {
        self.index = index
        self.sourceCell = sourceCell
        self.subtitleCell = subtitleCell
        self.targetCell = targetCell
        self.subtitleMode = subtitleMode
    }

    public var sourceURL: URL? { sourceCell?.url }
    public var subtitleURL: URL? { subtitleCell?.url }
    public var targetURL: URL? { targetCell?.url }

    public var isComplete: Bool {
        guard sourceURL != nil, targetURL != nil else { return false }
        switch subtitleMode {
        case .embedded:
            return true
        case .external:
            return subtitleURL != nil
        }
    }
}

/// Pure, deterministic column-and-row pairing model for Manual Batch.
/// Strictly pairs by row index (#1, #2, #3...) with zero filename or regex auto-matching.
public struct ManualBatchColumns: Equatable, Hashable, Sendable {
    public var subtitleMode: BatchSubtitleMode
    public var sourceVideos: [ManualBatchCell]
    public var sourceSubtitles: [ManualBatchCell]
    public var targetVideos: [ManualBatchCell]

    public init(
        subtitleMode: BatchSubtitleMode = .embedded,
        sourceVideos: [ManualBatchCell] = [],
        sourceSubtitles: [ManualBatchCell] = [],
        targetVideos: [ManualBatchCell] = []
    ) {
        self.subtitleMode = subtitleMode
        self.sourceVideos = sourceVideos
        self.sourceSubtitles = sourceSubtitles
        self.targetVideos = targetVideos
    }

    public var activeColumns: [ManualBatchColumnKind] {
        switch subtitleMode {
        case .embedded: [.sourceVideo, .targetVideo]
        case .external: [.sourceVideo, .sourceSubtitle, .targetVideo]
        }
    }

    public var rowCount: Int {
        switch subtitleMode {
        case .embedded:
            max(sourceVideos.count, targetVideos.count)
        case .external:
            max(sourceVideos.count, sourceSubtitles.count, targetVideos.count)
        }
    }

    public var isEmpty: Bool {
        rowCount == 0
    }

    public var rows: [ManualBatchPairRow] {
        (0..<rowCount).map { row(at: $0) }
    }

    public func row(at index: Int) -> ManualBatchPairRow {
        ManualBatchPairRow(
            index: index,
            sourceCell: sourceVideos.indices.contains(index) ? sourceVideos[index] : nil,
            subtitleCell: sourceSubtitles.indices.contains(index) ? sourceSubtitles[index] : nil,
            targetCell: targetVideos.indices.contains(index) ? targetVideos[index] : nil,
            subtitleMode: subtitleMode
        )
    }

    public var completeRowCount: Int {
        rows.filter(\.isComplete).count
    }

    public var incompleteRowCount: Int {
        rowCount - completeRowCount
    }

    public func cells(in column: ManualBatchColumnKind) -> [ManualBatchCell] {
        switch column {
        case .sourceVideo: sourceVideos
        case .sourceSubtitle: sourceSubtitles
        case .targetVideo: targetVideos
        }
    }

    public func cell(in column: ManualBatchColumnKind, at index: Int) -> ManualBatchCell? {
        let list = cells(in: column)
        return list.indices.contains(index) ? list[index] : nil
    }

    public func fileCount(in column: ManualBatchColumnKind) -> Int {
        cells(in: column).filter { !$0.isBlankSlot }.count
    }

    private mutating func modifyColumn(_ column: ManualBatchColumnKind, _ transform: (inout [ManualBatchCell]) -> Void) {
        switch column {
        case .sourceVideo: transform(&sourceVideos)
        case .sourceSubtitle: transform(&sourceSubtitles)
        case .targetVideo: transform(&targetVideos)
        }
    }

    /// Expands any dropped directories into supported files sorted in natural Finder order,
    /// filtering out unsupported file extensions and hidden dotfiles.
    public static func expandDroppedURLs(_ urls: [URL], for column: ManualBatchColumnKind) -> [URL] {
        let fm = FileManager.default
        let allowed = column.allowedExtensions
        var collected: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let scanned = EpisodePairing.scanMediaFiles(in: url)
                let dirFiles = (column == .sourceSubtitle ? scanned.subtitles : scanned.media)
                    .sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }
                collected.append(contentsOf: dirFiles)
            } else {
                let ext = url.pathExtension.lowercased()
                guard allowed.contains(ext) else { continue }
                if column == .sourceSubtitle && url.lastPathComponent.contains(".sushi.") {
                    continue
                }
                collected.append(url)
            }
        }
        return collected
    }

    /// Inserts files into a single column at an optional row index without touching other columns.
    /// When dropping directly onto an explicit blank alignment slot, fills that slot first.
    @discardableResult
    public mutating func insert(
        urls: [URL],
        into column: ManualBatchColumnKind,
        at index: Int? = nil,
        expandDirectories: Bool = true
    ) -> [UUID] {
        let resolved: [URL]
        if expandDirectories {
            resolved = Self.expandDroppedURLs(urls, for: column)
        } else {
            let allowed = column.allowedExtensions
            resolved = urls.filter { url in
                allowed.contains(url.pathExtension.lowercased())
            }
        }
        guard !resolved.isEmpty else { return [] }

        let newCells = resolved.map { ManualBatchCell(url: $0) }
        modifyColumn(column) { list in
            if let index, list.indices.contains(index), list[index].isBlankSlot {
                list.replaceSubrange(index...index, with: newCells)
            } else if let index, index >= 0, index <= list.count {
                list.insert(contentsOf: newCells, at: index)
            } else {
                list.append(contentsOf: newCells)
            }
        }
        return newCells.map(\.id)
    }

    /// Sets or replaces the file at a specific row index in a column, padding with blank slots if needed.
    @discardableResult
    public mutating func setFile(_ url: URL, in column: ManualBatchColumnKind, at index: Int) -> UUID {
        let safeIndex = max(0, index)
        var assignedID = UUID()
        modifyColumn(column) { list in
            while list.count < safeIndex {
                list.append(ManualBatchCell(url: nil))
            }
            if safeIndex < list.count {
                list[safeIndex].url = url
                assignedID = list[safeIndex].id
            } else {
                let cell = ManualBatchCell(id: assignedID, url: url)
                list.append(cell)
            }
        }
        return assignedID
    }

    /// Inserts an explicit blank alignment slot at `index` in a single column, pushing lower items down by one row.
    @discardableResult
    public mutating func insertBlankSlot(in column: ManualBatchColumnKind, at index: Int) -> UUID {
        let safeIndex = max(0, index)
        let slot = ManualBatchCell(url: nil)
        modifyColumn(column) { list in
            while list.count < safeIndex {
                list.append(ManualBatchCell(url: nil))
            }
            list.insert(slot, at: safeIndex)
        }
        return slot.id
    }

    /// Reorders a single cell within its column.
    public mutating func moveCell(in column: ManualBatchColumnKind, from sourceIndex: Int, to destinationIndex: Int) {
        modifyColumn(column) { list in
            guard list.indices.contains(sourceIndex) else { return }
            let clampedDest = max(0, min(destinationIndex, list.count))
            guard sourceIndex != clampedDest else { return }
            let item = list.remove(at: sourceIndex)
            let adjustedDest = sourceIndex < clampedDest ? clampedDest - 1 : clampedDest
            let finalIndex = max(0, min(adjustedDest, list.count))
            list.insert(item, at: finalIndex)
        }
    }

    /// Reorders one or more selected cells within their column while preserving relative order.
    public mutating func moveCells(in column: ManualBatchColumnKind, ids: Set<UUID>, to destinationIndex: Int) {
        guard !ids.isEmpty else { return }
        modifyColumn(column) { list in
            let clampedDest = max(0, min(destinationIndex, list.count))
            let moving = list.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { return }
            let removedBeforeDest = list.prefix(clampedDest).filter { ids.contains($0.id) }.count
            list.removeAll { ids.contains($0.id) }
            let insertionIndex = max(0, min(clampedDest - removedBeforeDest, list.count))
            list.insert(contentsOf: moving, at: insertionIndex)
        }
    }

    @discardableResult
    public mutating func moveUp(in column: ManualBatchColumnKind, at index: Int) -> Bool {
        var moved = false
        modifyColumn(column) { list in
            guard index > 0, index < list.count else { return }
            list.swapAt(index, index - 1)
            moved = true
        }
        return moved
    }

    @discardableResult
    public mutating func moveDown(in column: ManualBatchColumnKind, at index: Int) -> Bool {
        var moved = false
        modifyColumn(column) { list in
            guard index >= 0, index + 1 < list.count else { return }
            list.swapAt(index, index + 1)
            moved = true
        }
        return moved
    }

    public mutating func removeCell(in column: ManualBatchColumnKind, at index: Int) {
        modifyColumn(column) { list in
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
        }
    }

    public mutating func removeCells(in column: ManualBatchColumnKind, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        modifyColumn(column) { list in
            list.removeAll { ids.contains($0.id) }
        }
    }

    /// Sorts files in natural Finder order (`localizedStandardCompare`) and compacts blank slots.
    public mutating func sortNaturally(in column: ManualBatchColumnKind) {
        modifyColumn(column) { list in
            let files = list.filter { !$0.isBlankSlot }.sorted { lhs, rhs in
                let lName = lhs.url?.lastPathComponent ?? ""
                let rName = rhs.url?.lastPathComponent ?? ""
                return lName.localizedStandardCompare(rName) == .orderedAscending
            }
            list = files
        }
    }

    /// Reverses the order of items in a single column.
    public mutating func reverse(in column: ManualBatchColumnKind) {
        modifyColumn(column) { list in
            list.reverse()
        }
    }

    public mutating func clear(column: ManualBatchColumnKind) {
        modifyColumn(column) { list in
            list.removeAll()
        }
    }

    public mutating func clearAll() {
        sourceVideos.removeAll()
        sourceSubtitles.removeAll()
        targetVideos.removeAll()
    }
}

// MARK: - Lightweight Native File Browser Model

public enum FileBrowserFilter: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case video
    case subtitles

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .subtitles: "Subtitles"
        }
    }
}

public struct FileBrowserEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var isMedia: Bool
    public var isSubtitle: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        let ext = url.pathExtension.lowercased()
        self.isMedia = !isDirectory && EpisodePairing.mediaExtensions.contains(ext)
        self.isSubtitle = !isDirectory && EpisodePairing.subtitleExtensions.contains(ext)
    }

    public var symbolName: String {
        if isDirectory { return "folder.fill" }
        if isSubtitle { return "captions.bubble" }
        if isMedia { return "film" }
        return "doc"
    }
}

public enum FileBrowserScanner {
    /// Lightweight single-directory enumeration ignoring hidden dotfiles (`.DS_Store`, etc.),
    /// sorted naturally like macOS Finder with folders first.
    public static func listDirectory(
        _ directory: URL,
        filter: FileBrowserFilter = .all,
        searchQuery: String = ""
    ) -> [FileBrowserEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(urls.count)

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                continue
            }
            let isPackage = values?.isPackage == true
            let isDir = (values?.isDirectory == true) && !isPackage
            let entry = FileBrowserEntry(url: url, isDirectory: isDir)

            if !isDir {
                switch filter {
                case .all:
                    break
                case .video:
                    guard entry.isMedia else { continue }
                case .subtitles:
                    guard entry.isSubtitle else { continue }
                }
            }

            if !trimmedQuery.isEmpty && !entry.name.localizedCaseInsensitiveContains(trimmedQuery) {
                continue
            }

            entries.append(entry)
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
