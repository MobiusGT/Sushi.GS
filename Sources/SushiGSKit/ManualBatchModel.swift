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

        for rawURL in urls {
            let url = ((rawURL as NSURL).filePathURL ?? rawURL).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                let scanned = EpisodePairing.scanMediaFiles(in: resolved)
                let dirFiles = (column == .sourceSubtitle ? scanned.subtitles : scanned.media)
                    .sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }
                collected.append(contentsOf: dirFiles)
            } else {
                let ext = url.pathExtension.lowercased()
                guard allowed.contains(ext) else { continue }
                if column == .sourceSubtitle && url.lastPathComponent.localizedCaseInsensitiveContains(".sushi.") {
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

public enum FileBrowserItemKind: String, Codable, Hashable, Sendable {
    case media
    case subtitle
    case folder
    case other

    /// True for file types that participate in type-locked multi-selection and drag-compatibility gating.
    public var isSelectableFileType: Bool {
        self == .media || self == .subtitle
    }

    /// True when dragging items of this kind is valid for the given Manual Batch pairing column.
    public func acceptsColumn(_ column: ManualBatchColumnKind) -> Bool {
        switch (self, column) {
        case (.media, .sourceVideo), (.media, .targetVideo):
            true
        case (.subtitle, .sourceSubtitle):
            true
        default:
            false
        }
    }
}

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
    public var kind: FileBrowserItemKind
    public var fileSizeBytes: Int64?

    public init(url: URL, isDirectory: Bool, fileSizeBytes: Int64? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        let ext = url.pathExtension.lowercased()
        let media = !isDirectory && EpisodePairing.mediaExtensions.contains(ext)
        let sub = !isDirectory && EpisodePairing.subtitleExtensions.contains(ext)
        self.isMedia = media
        self.isSubtitle = sub
        if isDirectory {
            self.kind = .folder
        } else if media {
            self.kind = .media
        } else if sub {
            self.kind = .subtitle
        } else {
            self.kind = .other
        }
        self.fileSizeBytes = isDirectory ? nil : fileSizeBytes
    }

    public var symbolName: String {
        switch kind {
        case .folder: "folder.fill"
        case .subtitle: "captions.bubble"
        case .media: "film"
        case .other: "doc"
        }
    }

    /// Compact file size (e.g. "1.4 GB", "48 KB") or file extension hint (e.g. "MKV", "ASS").
    public var subtleDetailHint: String? {
        if isDirectory { return nil }
        if let bytes = fileSizeBytes, bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? nil : ext
    }
}

/// Type-locked multi-selection state for the Manual Batch File Browser.
/// Prevents accidental mixed-type (media + subtitle) selections across Shift-click, Command-click, and Command-A.
public struct FileBrowserSelectionState: Equatable, Hashable, Sendable {
    public var selectedPaths: Set<String>
    public var anchorPath: String?
    public var anchorKind: FileBrowserItemKind?

    public init(
        selectedPaths: Set<String> = [],
        anchorPath: String? = nil,
        anchorKind: FileBrowserItemKind? = nil
    ) {
        self.selectedPaths = selectedPaths
        self.anchorPath = anchorPath
        self.anchorKind = anchorKind
    }

    public var isEmpty: Bool { selectedPaths.isEmpty }

    public mutating func clear() {
        selectedPaths.removeAll()
        anchorPath = nil
        anchorKind = nil
    }

    /// Plain single-click replaces selection with `entry` and sets the anchor and its type lock.
    public mutating func plainClick(_ entry: FileBrowserEntry) {
        selectedPaths = [entry.id]
        anchorPath = entry.id
        anchorKind = entry.kind.isSelectableFileType ? entry.kind : nil
    }

    /// Shift-click selects the contiguous range from the anchor to `entry`, keeping ONLY items
    /// matching the anchor's file kind (skipping opposite file types, folders, and unsupported files).
    public mutating func shiftClick(_ entry: FileBrowserEntry, visibleEntries: [FileBrowserEntry]) {
        guard let anchor = anchorPath,
              let anchorIdx = visibleEntries.firstIndex(where: { $0.id == anchor }),
              let clickIdx = visibleEntries.firstIndex(where: { $0.id == entry.id }) else {
            plainClick(entry)
            return
        }

        let targetKind: FileBrowserItemKind?
        if let existingLock = anchorKind, existingLock.isSelectableFileType {
            targetKind = existingLock
        } else if entry.kind.isSelectableFileType {
            targetKind = entry.kind
            anchorKind = entry.kind
        } else {
            targetKind = nil
        }

        guard let locked = targetKind else {
            plainClick(entry)
            return
        }

        let lo = min(anchorIdx, clickIdx)
        let hi = max(anchorIdx, clickIdx)
        let matching = visibleEntries[lo...hi].filter { $0.kind == locked }
        if matching.isEmpty {
            return
        }
        selectedPaths = Set(matching.map(\.id))
    }

    /// Command-click toggles an item while enforcing the anchor's file kind when adding.
    /// Opposite-type files (e.g., subtitles when anchor is media) are silently skipped.
    public mutating func commandClick(_ entry: FileBrowserEntry) {
        if selectedPaths.contains(entry.id) {
            selectedPaths.remove(entry.id)
            if selectedPaths.isEmpty {
                anchorPath = nil
                anchorKind = nil
            } else if anchorPath == entry.id {
                anchorPath = selectedPaths.sorted().first
            }
            return
        }

        if selectedPaths.isEmpty {
            plainClick(entry)
            return
        }

        if let locked = anchorKind, locked.isSelectableFileType {
            guard entry.kind == locked else { return }
            selectedPaths.insert(entry.id)
        } else if entry.kind.isSelectableFileType {
            // Previous selection was a folder or other item: switch cleanly to file selection.
            plainClick(entry)
        } else if entry.kind == .folder {
            selectedPaths.insert(entry.id)
        }
    }

    /// Command-A selects all visible files matching the existing anchor kind, or falls back to
    /// the active filter (or media-first when filter is `.all`).
    public mutating func selectAll(visibleEntries: [FileBrowserEntry], activeFilter: FileBrowserFilter) {
        let resolvedKind: FileBrowserItemKind?
        if !selectedPaths.isEmpty, let locked = anchorKind, locked.isSelectableFileType {
            resolvedKind = locked
        } else {
            switch activeFilter {
            case .video:
                resolvedKind = .media
            case .subtitles:
                resolvedKind = .subtitle
            case .all:
                if visibleEntries.contains(where: { $0.kind == .media }) {
                    resolvedKind = .media
                } else if visibleEntries.contains(where: { $0.kind == .subtitle }) {
                    resolvedKind = .subtitle
                } else {
                    resolvedKind = nil
                }
            }
        }

        guard let targetKind = resolvedKind else {
            clear()
            return
        }

        let matching = visibleEntries.filter { $0.kind == targetKind }
        guard !matching.isEmpty else {
            clear()
            return
        }
        selectedPaths = Set(matching.map(\.id))
        if let existingAnchor = anchorPath, selectedPaths.contains(existingAnchor) {
            anchorPath = existingAnchor
        } else {
            anchorPath = matching.first?.id
        }
        anchorKind = targetKind
    }

    /// Resolves the drag kind (.media or .subtitle) for dragging `draggedEntry` (or the current selection if it contains `draggedEntry`).
    public func dragPayload(for draggedEntry: FileBrowserEntry, visibleEntries: [FileBrowserEntry]) -> (urls: [URL], kind: FileBrowserItemKind?) {
        if selectedPaths.contains(draggedEntry.id) {
            let ordered = visibleEntries.filter { selectedPaths.contains($0.id) }
            if !ordered.isEmpty {
                let kind: FileBrowserItemKind?
                if let locked = anchorKind, locked.isSelectableFileType {
                    kind = locked
                } else if ordered.allSatisfy({ $0.kind == .media }) {
                    kind = .media
                } else if ordered.allSatisfy({ $0.kind == .subtitle }) {
                    kind = .subtitle
                } else {
                    kind = nil
                }
                return (ordered.map(\.url), kind)
            }
        }
        return ([draggedEntry.url], draggedEntry.kind.isSelectableFileType ? draggedEntry.kind : nil)
    }
}

/// Back / Forward / Parent-Up navigation history for the Manual Batch File Browser.
public struct FileBrowserHistory: Equatable, Hashable, Sendable {
    public private(set) var backStack: [URL]
    public private(set) var forwardStack: [URL]
    public private(set) var current: URL?

    public init(current: URL? = nil, backStack: [URL] = [], forwardStack: [URL] = []) {
        self.current = current?.standardizedFileURL
        self.backStack = backStack.map(\.standardizedFileURL)
        self.forwardStack = forwardStack.map(\.standardizedFileURL)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool {
        guard let current else { return false }
        return current.deletingLastPathComponent().path != current.path
    }

    public mutating func navigate(to url: URL) {
        let normalized = url.standardizedFileURL
        if let current {
            if current.path == normalized.path {
                return
            }
            backStack.append(current)
        }
        current = normalized
        forwardStack.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        if let current {
            forwardStack.append(current)
        }
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current {
            backStack.append(current)
        }
        current = next
        return next
    }

    @discardableResult
    public mutating func goUp() -> URL? {
        guard canGoUp, let current else { return nil }
        let parent = current.deletingLastPathComponent()
        navigate(to: parent)
        return parent
    }

    public mutating func reset(to url: URL?) {
        backStack.removeAll()
        forwardStack.removeAll()
        current = url?.standardizedFileURL
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey]
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
            let byteSize = values?.fileSize.map { Int64($0) }
            let entry = FileBrowserEntry(url: url, isDirectory: isDir, fileSizeBytes: byteSize)

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
