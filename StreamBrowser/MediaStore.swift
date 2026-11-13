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
}

struct MediaStore {
    private let fm = FileManager.default
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var root: URL { home.appendingPathComponent("Library/Application Support/StreamBrowser", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    private var media: URL { root.appendingPathComponent("Media", isDirectory: true) }
    private var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var jobsURL: URL { staging.appendingPathComponent("jobs.json") }

    func readLibrary() throws -> LibraryData { try read(libraryURL, fallback: LibraryData()) }
    func readJobs() throws -> [UUID: SystemJob] { try read(jobsURL, fallback: [:]) }
    func writeLibrary(_ data: LibraryData) throws { try write(data, to: libraryURL, protection: .complete) }
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
        try protect(source, .complete)
        try fm.moveItem(at: source, to: final)
        do { try protect(final, .complete) } catch { try? fm.removeItem(at: final); throw error }
        return final
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
        try removeTemporaryFiles()
        let keepFiles = Set(library.media.map(\.location)).union(jobs.values.compactMap(\.location))
        for folder in [media, staging.appendingPathComponent("Public", isDirectory: true)] where fm.fileExists(atPath: folder.path) {
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if !keepFiles.contains(try reference(file)) { try remove(file) }
            }
        }
    }

    func usage() throws -> Int64 {
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
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
