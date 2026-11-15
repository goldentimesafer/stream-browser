import Foundation

struct SavedMedia: Identifiable, Codable {
    let id: UUID
    let kind: MediaKind
    let location: String
    var name: String
    let bytes: Int64?
    let date: Date
    var position: Double?
}

struct Bookmark: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: URL
}

struct LibraryData: Codable {
    var media: [SavedMedia] = []
    var bookmarks: [Bookmark] = []
    var publicHosts: Set<String> = []
    var rememberPosition = false
}

struct SystemJob: Codable {
    let mode: TransferMode
    var location: String?
    var ready = false
    var cancelled = false
    var paused: Bool?
}

struct PendingImport: Codable {
    let source: String
    let item: SavedMedia
}

struct MediaStore {
    private let fm = FileManager.default
    private let home: URL
    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) { self.home = home }
    var root: URL { home.appendingPathComponent("Library/Application Support/StreamBrowser", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    private var media: URL { root.appendingPathComponent("Media", isDirectory: true) }
    private var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var jobsURL: URL { staging.appendingPathComponent("jobs.json") }
    private var imports: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    private var backupURL: URL { root.appendingPathComponent("library-backup.json") }

    func readLibrary() throws -> LibraryData { try read(libraryURL, fallback: LibraryData()) }
    func readJobs() throws -> [UUID: SystemJob] { try read(jobsURL, fallback: [:]) }
    func writeLibrary(_ data: LibraryData) throws {
        // Mirror the new index, not the previous one: deleted metadata must not
        // survive in a rolling backup. A pending import makes either copy replayable.
        try write(data, to: backupURL, protection: .complete)
        try write(data, to: libraryURL, protection: .complete)
    }
    func writeJobs(_ jobs: [UUID: SystemJob]) throws {
        try write(jobs, to: jobsURL, protection: .completeUntilFirstUserAuthentication)
    }

    private func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return fallback }
    }

    private func write<T: Encodable>(_ value: T, to url: URL, protection: FileProtectionType) throws {
        try directory(root, protection: .completeUntilFirstUserAuthentication)
        if url == jobsURL { try directory(staging, protection: .completeUntilFirstUserAuthentication) }
        let options: Data.WritingOptions = protection == .complete ? [.atomic, .completeFileProtection] :
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try JSONEncoder().encode(value).write(to: url, options: options)
    }

    func reserve(bytes: Int64?) throws {
        try directory(root, protection: .completeUntilFirstUserAuthentication)
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        let margin: Int64 = 200 * 1024 * 1024
        let requested = max(0, bytes ?? 0)
        guard let free, Int64(free) > margin, requested <= Int64(free) - margin else { throw MediaError.storage }
    }

    func webDestination(_ id: UUID, ext: String) throws -> URL {
        let folder = staging.appendingPathComponent("Web", isDirectory: true)
        try directory(folder, protection: .complete)
        return folder.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    }

    func takeBackgroundFile(_ source: URL, id: UUID, ext: String) throws -> String {
        let folder = staging.appendingPathComponent("Public", isDirectory: true)
        try directory(folder, protection: .completeUntilFirstUserAuthentication)
        let target = folder.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
        try fm.moveItem(at: source, to: target)
        do {
            try protect(target, .completeUntilFirstUserAuthentication)
            return try reference(target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    func finalFile(_ source: URL, id: UUID) throws -> URL {
        try directory(media, protection: .complete)
        let final = media.appendingPathComponent(id.uuidString).appendingPathExtension(source.pathExtension)
        if source != final && !fm.fileExists(atPath: final.path) {
            try protect(source, .complete)
            try fm.moveItem(at: source, to: final)
        }
        try protect(final, .complete)
        return final
    }

    func prepareImport(_ source: URL, id: UUID, kind: MediaKind, name: String) throws -> PendingImport {
        let target = kind == .hls ? source : media.appendingPathComponent(id.uuidString).appendingPathExtension(source.pathExtension)
        let item = SavedMedia(id: id, kind: kind, location: try reference(target), name: name,
                              bytes: try diskUsage(source), date: Date(), position: nil)
        let pending = PendingImport(source: try reference(source), item: item)
        try directory(imports, protection: .complete)
        try write(pending, to: importURL(id), protection: .complete)
        return pending
    }

    private func importURL(_ id: UUID) -> URL { imports.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    func hasPendingImport(_ id: UUID) -> Bool { fm.fileExists(atPath: importURL(id).path) }

    func pendingImports() throws -> [PendingImport] {
        guard fm.fileExists(atPath: imports.path) else { return [] }
        return try fm.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(PendingImport.self, from: Data(contentsOf: $0)) }
    }

    func finishImport(_ pending: PendingImport, library: LibraryData) throws -> LibraryData {
        var next = library
        if !next.media.contains(where: { $0.id == pending.item.id }) {
            let source = try resolve(pending.source)
            let target = try resolve(pending.item.location)
            if pending.item.kind == .hls { try protectAsset(target) }
            else {
                let final = try finalFile(source, id: pending.item.id)
                guard final.standardizedFileURL == target.standardizedFileURL else { throw MediaError.storage }
            }
            next.media.insert(pending.item, at: 0)
            try writeLibrary(next)
        }
        // A failed marker removal is harmless: replay observes the committed ID.
        try? remove(importURL(pending.item.id))
        return next
    }

    func recoverImports(_ library: LibraryData, excluding cancelled: Set<UUID> = []) throws -> LibraryData {
        var recovered = library
        for pending in try pendingImports() where !cancelled.contains(pending.item.id) {
            recovered = try finishImport(pending, library: recovered)
        }
        return recovered
    }

    func discardImport(_ id: UUID, library: LibraryData) throws {
        guard hasPendingImport(id) else { return }
        let pending = try JSONDecoder().decode(PendingImport.self, from: Data(contentsOf: importURL(id)))
        if !library.media.contains(where: { $0.id == id }) {
            for ref in Set([pending.source, pending.item.location]) { try remove(resolve(ref)) }
        }
        try remove(importURL(id))
    }

    /// Explicit user recovery; preserve the corrupt original and all media.
    func repairLibrary() throws -> LibraryData {
        let original = try Data(contentsOf: libraryURL)
        do { return try JSONDecoder().decode(LibraryData.self, from: original) }
        catch is DecodingError { /* Recover below; never treat protected-data errors as corruption. */ }
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        try directory(recovery, protection: .complete)
        try original.write(to: recovery.appendingPathComponent(UUID().uuidString).appendingPathExtension("json"),
                           options: [.atomic, .completeFileProtection])
        var restored = (try? read(backupURL, fallback: LibraryData())) ?? LibraryData()
        if fm.fileExists(atPath: media.path) {
            for url in try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !restored.media.contains(where: { $0.id == id }) else { continue }
                restored.media.append(SavedMedia(id: id, kind: .file, location: try reference(url),
                                                name: "복구한 영상", bytes: try diskUsage(url), date: Date(), position: nil))
            }
        }
        // The caller replays pending imports after restoring this index.
        // System packages without any surviving reference remain untouched.
        try write(restored, to: libraryURL, protection: .complete)
        return restored
    }

    func reference(_ url: URL) throws -> String {
        let base = home.standardizedFileURL.resolvingSymlinksInPath().path
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.isFileURL, file.hasPrefix(base + "/") else { throw MediaError.storage }
        return String(file.dropFirst(base.count + 1))
    }

    func resolve(_ reference: String) throws -> URL {
        guard !reference.isEmpty, !reference.hasPrefix("/"),
              !reference.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw MediaError.storage
        }
        let url = home.appendingPathComponent(reference)
        guard try self.reference(url) == reference else { throw MediaError.storage }
        return url
    }

    func assetReference(_ location: URL) throws -> String {
        let path = try reference(location)
        guard location.pathExtension.lowercased() == "movpkg",
              !path.hasPrefix("Library/Application Support/StreamBrowser/") else { throw MediaError.storage }
        return path
    }

    func protectAsset(_ url: URL) throws {
        _ = try assetReference(url)
        try protect(url, .complete)
        var enumerationError: Error?
        guard let items = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                        errorHandler: { _, error in enumerationError = error; return false }) else {
            throw MediaError.storage
        }
        for case let child as URL in items {
            guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
                  try reference(child).hasPrefix(try reference(url) + "/") else { throw MediaError.storage }
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: child.path)
        }
        if let enumerationError { throw enumerationError }
    }

    func remove(_ url: URL) throws {
        let path = try reference(url)
        guard path.hasPrefix("Library/Application Support/StreamBrowser/") || (try? assetReference(url)) != nil else {
            throw MediaError.storage
        }
        do { try fm.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
    }

    func removeTemporaryFiles() throws {
        try remove(exports)
        try remove(staging.appendingPathComponent("Web", isDirectory: true))
    }

    func export(_ item: SavedMedia) throws -> URL {
        guard item.kind == .file else { throw MediaError.format }
        let original = try resolve(item.location)
        try reserve(bytes: item.bytes)
        let folder = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try directory(folder, protection: .complete)
        let target = folder.appendingPathComponent(MediaPolicy.displayName(item.name)).appendingPathExtension(original.pathExtension)
        do {
            try fm.copyItem(at: original, to: target)
            try protect(target, .complete)
            return target
        } catch { try? remove(folder); throw error }
    }

    func cleanup(_ library: LibraryData, jobs: [UUID: SystemJob]) throws {
        try remove(exports)
        let pending = try pendingImports()
        let keepFiles = Set(library.media.map(\.location)).union(jobs.values.compactMap(\.location))
            .union(pending.flatMap { [$0.source, $0.item.location] })
        for folder in [media, staging.appendingPathComponent("Public", isDirectory: true),
                       staging.appendingPathComponent("Web", isDirectory: true)] where fm.fileExists(atPath: folder.path) {
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if !keepFiles.contains(try reference(file)) { try remove(file) }
            }
        }
    }

    func usage(hlsLocations: Set<String> = []) throws -> Int64 {
        var bytes = try diskUsage(root)
        for ref in hlsLocations { bytes += try diskUsage(resolve(ref)) }
        return bytes
    }

    func diskUsage(_ url: URL) throws -> Int64 {
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true else { throw MediaError.storage }
        if info.isRegularFile == true { return Int64(info.fileSize ?? 0) }
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { files.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }

    func removeRecoveryCopies() throws {
        try remove(backupURL)
        try remove(root.appendingPathComponent("Recovery", isDirectory: true))
    }

    private func directory(_ url: URL, protection: FileProtectionType) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        try protect(url, protection)
    }

    private func protect(_ url: URL, _ protection: FileProtectionType) throws {
        try fm.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        try exclude(url)
    }

    private func exclude(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
