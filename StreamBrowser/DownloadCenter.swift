import AVFoundation
import SwiftUI
import UIKit
import WebKit

struct DownloadRow: Identifiable {
    let id: UUID
    let mode: TransferMode
    var name: String
    var state = "대기 중"
    var progress: Double?
    var bytes: Int64 = 0
    var failure: String?
}

@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var library = LibraryData()
    @Published private(set) var rows: [DownloadRow] = []
    @Published var notice: String?
    @Published private(set) var webOffer: UUID?
    private(set) var unlocked = false
    private var opened = false
    private var foreground = false
    private var libraryLoaded = false
    private var journalLoaded = false
    private let store = MediaStore()
    private var jobs: [UUID: SystemJob] = [:]
    private var requests: [UUID: URL] = [:]
    private var systemTasks: [UUID: URLSessionTask] = [:]
    private var webTransfers: [UUID: WebTransfer] = [:]
    private var webStarters: [UUID: () -> Void] = [:]
    private var checks: [UUID: Task<Void, Never>] = [:]
    private var validations: [UUID: Task<Void, Never>] = [:]
    private var availableSpaceChecks: [UUID: Int64] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private var activeSystemSessions = Set<String>()
    private var restoring = false
    private var startingWeb = Set<UUID>()
    private let delegates = SystemTransferDelegate()
    private let fileSessionID = "local.streambrowser.files.v1"
    private let hlsSessionID = "local.streambrowser.hls.v1"

    private lazy var files = URLSession(configuration: systemConfiguration(fileSessionID), delegate: delegates,
                                        delegateQueue: .main)
    private lazy var streams = AVAssetDownloadURLSession(configuration: systemConfiguration(hlsSessionID),
                                                         assetDownloadDelegate: delegates, delegateQueue: .main)

    private func systemConfiguration(_ id: String) -> URLSessionConfiguration {
        let config = PublicSourceCheck.configuration(.background(withIdentifier: id))
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = id == hlsSessionID
        config.allowsCellularAccess = false
        return config
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value {
            if unlocked { unlock() }
        } else { stopPrivateTransfers() }
    }

    func unlock() {
        unlocked = true
        do {
            if !libraryLoaded { library = try store.readLibrary(); libraryLoaded = true }
            try loadJournal()
            if !opened {
                try store.cleanup(library, jobs: jobs)
                opened = true
                connectSessions()
            }
            processReadyJobs()
            pump()
        } catch { notice = MediaError.storage.message }
    }

    func lock() { unlocked = false }

    private func loadJournal() throws {
        guard !journalLoaded else { return }
        jobs = try store.readJobs()
        journalLoaded = true
    }

    private func persist(_ next: [UUID: SystemJob]) throws {
        try store.writeJobs(next)
        jobs = next
    }

    private func changeJob(_ id: UUID, to job: SystemJob?) throws {
        var next = jobs
        next[id] = job
        try persist(next)
    }

    func acceptSystemEvents(_ identifier: String, completion: @escaping () -> Void) {
        guard identifier == fileSessionID || identifier == hlsSessionID else { completion(); return }
        completionHandlers[identifier] = completion
        connect(identifier)
    }

    func finishedSystemEvents(_ identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }

    private func connect(_ id: String) {
        guard activeSystemSessions.insert(id).inserted else { return }
        if id == fileSessionID { _ = files } else { _ = streams }
    }

    private func connectSessions() {
        connect(fileSessionID)
        connect(hlsSessionID)
        restoring = true
        for (id, job) in jobs where !job.cancelled && !library.media.contains(where: { $0.id == id }) {
            ensureRow(id, mode: job.mode)
            update(id) { $0.state = job.ready ? "저장 확인 대기" : "시스템 작업 확인 중" }
        }
        Task {
            let fileTasks = await files.allTasks
            let streamTasks = await streams.allTasks
            let live = fileTasks + streamTasks
            for task in live {
                guard let id = jobID(task), let job = jobs[id], !job.ready,
                      !library.media.contains(where: { $0.id == id }) else { task.cancel(); continue }
                systemTasks[id] = task
                if job.cancelled { task.cancel(); continue }
                ensureRow(id, mode: job.mode)
                update(id) { $0.state = "시스템에서 다운로드 중" }
            }
            restoring = false
            processReadyJobs()
            pump()
            for (id, job) in jobs where systemTasks[id] == nil && !job.ready && !job.cancelled {
                // Keep the journal entry for any completion event already in flight.
                fail(id, .interrupted)
            }
        }
    }

    func enqueue(_ url: URL, mode: TransferMode, webView: WKWebView? = nil) {
        guard unlocked, foreground, libraryLoaded, journalLoaded else { return }
        guard MediaPolicy.secureWebURL(url) else { notice = MediaError.address.message; return }
        if mode.usesSystemSession, !MediaPolicy.publicURL(url, hosts: library.publicHosts) {
            notice = MediaError.untrustedSource.message
            return
        }
        if requests.values.contains(url) { notice = "이 주소는 이미 대기 중이거나 다운로드 중입니다."; return }
        guard rows.filter({ $0.failure == nil }).count < 20 else { notice = MediaError.busy.message; return }
        let id = UUID()
        requests[id] = url
        rows.insert(DownloadRow(id: id, mode: mode, name: MediaPolicy.displayName(url.deletingPathExtension().lastPathComponent)), at: 0)
        if mode == .web {
            guard let webView else { fail(id, .interrupted); return }
            webStarters[id] = { [weak self, weak webView] in
                guard let self, let webView else { self?.fail(id, .interrupted); return }
                webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                    self?.attachWebDownload(download, id: id, expected: url)
                }
            }
        }
        pump()
    }

    func acceptWebDownload(_ download: WKDownload, origin: URL) {
        if #available(iOS 18.2, *), !download.isUserInitiated {
            download.cancel { _ in }
            return
        }
        guard unlocked, foreground, opened,
              let url = download.originalRequest?.url, MediaPolicy.secureWebURL(url),
              url.host?.lowercased() == origin.host?.lowercased(),
              !requests.values.contains(url), activeCount < 2, !restoring else {
            download.cancel { _ in }
            notice = "저장 메뉴에서 영상 주소를 확인하고 다시 시도하세요."
            return
        }
        let id = UUID()
        requests[id] = url
        rows.insert(DownloadRow(id: id, mode: .web, name: "영상"), at: 0)
        attachWebDownload(download, id: id, expected: url, requiresConfirmation: true)
    }

    private var activeCount: Int { systemTasks.count + webTransfers.count + startingWeb.count + checks.count }

    private func pump() {
        guard unlocked, foreground, opened, !restoring else { return }
        for row in rows.reversed() where row.state == "대기 중" && row.failure == nil {
            guard activeCount < 2 else { break }
            guard let url = requests[row.id] else { continue }
            let id = row.id
            if let start = webStarters.removeValue(forKey: id) {
                startingWeb.insert(id)
                update(id) { $0.state = "응답 대기" }
                start()
            } else if row.mode.usesSystemSession {
                let hosts = library.publicHosts
                let mode = row.mode
                update(id) { $0.state = "출처 확인 중" }
                checks[id] = Task {
                    do {
                        let expectedBytes = try await PublicSourceCheck.verify(url, mode: mode, hosts: hosts)
                        try Task.checkCancellation()
                        checks[id] = nil
                        guard requests[id] != nil else { return }
                        guard foreground, unlocked else { update(id) { $0.state = "대기 중" }; return }
                        guard library.publicHosts == hosts else { fail(id, .untrustedSource); return }
                        try startSystem(id, url: url, mode: mode, expectedBytes: expectedBytes)
                    } catch is CancellationError { }
                    catch {
                        checks[id] = nil
                        if requests[id] != nil { fail(id, error as? MediaError ?? .response) }
                    }
                    pump()
                }
            }
        }
    }

    private func startSystem(_ id: UUID, url: URL, mode: TransferMode, expectedBytes: Int64?) throws {
        try store.reserve(bytes: expectedBytes)
        try changeJob(id, to: SystemJob(mode: mode))
        let task: URLSessionTask
        if mode == .hls {
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidRemoteReferenceToLocal.rawValue)
            ])
            let config = AVAssetDownloadConfiguration(asset: asset, title: "오프라인 영상")
            task = streams.makeAssetDownloadTask(downloadConfiguration: config)
        } else {
            task = files.downloadTask(with: URLRequest(url: url))
        }
        task.taskDescription = id.uuidString
        systemTasks[id] = task
        update(id) { $0.state = "시스템에서 다운로드 중" }
        task.resume()
    }

    private func jobID(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }

    func receiveFile(_ task: URLSessionDownloadTask, temporary: URL) {
        guard let id = jobID(task) else { return }
        do {
            try loadJournal()
            guard var job = jobs[id], !job.cancelled, job.mode == .backgroundFile, job.location == nil else { return }
            guard let response = task.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == task.originalRequest?.url, let ext = MediaPolicy.videoExtension(response) else {
                throw MediaError.response
            }
            let location = try store.takeBackgroundFile(temporary, id: id, ext: ext)
            job.location = location
            do { try changeJob(id, to: job) }
            catch { try? store.remove(store.resolve(location)); throw error }
        } catch { failSystem(id, error as? MediaError ?? .storage) }
    }

    func receiveAssetLocation(_ task: AVAssetDownloadTask, location: URL) {
        guard let id = jobID(task) else { return }
        do {
            try loadJournal()
            guard var job = jobs[id], job.mode == .hls else { return }
            job.location = try store.assetReference(location)
            try changeJob(id, to: job)
        } catch { failSystem(id, .storage) }
    }

    func systemCompleted(_ task: URLSessionTask, failed: Bool) {
        guard let id = jobID(task) else { return }
        systemTasks[id] = nil
        availableSpaceChecks[id] = nil
        defer { pump() }
        do {
            try loadJournal()
            guard var job = jobs[id] else { return }
            if job.cancelled { try discardJob(id); return }
            guard !job.ready else { return }
            guard !failed, job.location != nil else { failSystem(id, .interrupted); return }
            job.ready = true
            try changeJob(id, to: job)
            ensureRow(id, mode: job.mode)
            update(id) { $0.failure = nil }
            if unlocked && foreground { processReadyJobs() }
            else { update(id) { $0.state = "잠금 해제 후 저장 확인" } }
        } catch { failSystem(id, .storage) }
    }

    func updateProgress(_ task: URLSessionDownloadTask, bytes: Int64, total: Int64) {
        guard let id = jobID(task), jobs[id]?.cancelled == false else { return }
        update(id) { $0.bytes = bytes; $0.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil }
        if bytes - (availableSpaceChecks[id] ?? 0) >= 16 * 1024 * 1024 {
            availableSpaceChecks[id] = bytes
            do { try store.reserve(bytes: nil) }
            catch { cancel(id); notice = MediaError.storage.message }
        }
    }

    func refreshProgress() {
        for (id, task) in systemTasks where task is AVAssetDownloadTask {
            let progress = task.progress.fractionCompleted
            update(id) { $0.progress = progress.isFinite && progress > 0 ? min(1, progress) : nil }
        }
        for (id, transfer) in webTransfers {
            let progress = transfer.download.progress
            update(id) {
                $0.bytes = progress.completedUnitCount
                $0.progress = progress.totalUnitCount > 0 ? min(1, progress.fractionCompleted) : nil
            }
            if progress.completedUnitCount - (availableSpaceChecks[id] ?? 0) >= 16 * 1024 * 1024 {
                availableSpaceChecks[id] = progress.completedUnitCount
                do { try store.reserve(bytes: nil) }
                catch { cancel(id); notice = MediaError.storage.message }
            }
        }
    }

    private func attachWebDownload(_ download: WKDownload, id: UUID, expected: URL, requiresConfirmation: Bool = false) {
        startingWeb.remove(id)
        guard unlocked, foreground, requests[id] != nil else { download.cancel { _ in }; pump(); return }
        let transfer = WebTransfer(download: download, id: id, expected: expected, requiresConfirmation: requiresConfirmation, center: self)
        webTransfers[id] = transfer
        download.delegate = transfer
    }

    func offerWebSave(_ id: UUID) -> Bool {
        guard webOffer == nil, unlocked, foreground, requests[id] != nil else { return false }
        webOffer = id
        update(id) { $0.state = "저장 확인 대기" }
        return true
    }

    func answerWebOffer(save: Bool) {
        guard let id = webOffer else { return }
        webOffer = nil
        if save { webTransfers[id]?.approve() } else { cancel(id) }
    }

    func webDestination(_ id: UUID, response: URLResponse, suggested: String) throws -> URL {
        guard unlocked, foreground, requests[id] != nil,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let ext = MediaPolicy.videoExtension(response, suggested: suggested) else { throw MediaError.format }
        try store.reserve(bytes: response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        let name = MediaPolicy.displayName((suggested as NSString).deletingPathExtension)
        update(id) { $0.name = name; $0.state = "다운로드 중" }
        return try store.webDestination(id, ext: ext)
    }

    func webFinished(_ id: UUID, location: URL?) {
        webTransfers[id] = nil
        availableSpaceChecks[id] = nil
        guard let location, requests[id] != nil, foreground, unlocked else {
            if let location { try? store.remove(location) }
            if requests[id] != nil { fail(id, .interrupted) }
            pump()
            return
        }
        validate(id, mode: .web, location: location)
        pump()
    }

    func webFailed(_ id: UUID, location: URL?, error: MediaError) {
        if webOffer == id { webOffer = nil }
        webTransfers[id] = nil
        availableSpaceChecks[id] = nil
        if let location { try? store.remove(location) }
        if requests[id] != nil { fail(id, error) }
        pump()
    }

    private func processReadyJobs() {
        guard unlocked, foreground, libraryLoaded, journalLoaded else { return }
        for (id, job) in jobs where job.ready && !job.cancelled && validations[id] == nil {
            if library.media.contains(where: { $0.id == id }) { try? changeJob(id, to: nil); continue }
            guard let reference = job.location, let url = try? store.resolve(reference) else { failSystem(id, .storage); continue }
            ensureRow(id, mode: job.mode)
            validate(id, mode: job.mode, location: url)
        }
    }

    private func validate(_ id: UUID, mode: TransferMode, location: URL) {
        let name = rows.first(where: { $0.id == id })?.name ?? "오프라인 영상"
        update(id) { $0.state = "재생 확인 중" }
        validations[id] = Task {
            defer { validations[id] = nil }
            do {
                let asset = LocalMediaAsset.make(location, kind: mode.kind)
                if mode == .hls {
                    guard asset.assetCache?.isPlayableOffline == true else { throw MediaError.format }
                } else {
                    let handle = try FileHandle(forReadingFrom: location)
                    defer { try? handle.close() }
                    guard MediaPolicy.hasMovieHeader(try handle.read(upToCount: 16) ?? Data()),
                          try await asset.load(.isPlayable),
                          !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw MediaError.format }
                }
                try Task.checkCancellation()
                guard unlocked, foreground else {
                    if mode.usesSystemSession { update(id) { $0.state = "잠금 해제 후 저장 확인" } }
                    else { try? store.remove(location); fail(id, .interrupted) }
                    return
                }
                let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                let final: URL
                if mode == .hls { try store.protectAsset(location); final = location }
                else { final = try store.finalFile(location, id: id) }
                let saved = SavedMedia(id: id, kind: mode.kind, location: try store.reference(final), name: name,
                                       bytes: mode == .hls ? nil : size, date: Date(), position: nil)
                var next = library
                next.media.insert(saved, at: 0)
                do { try save(next) }
                catch { try? store.remove(final); throw error }
                if mode.usesSystemSession { try? changeJob(id, to: nil) }
                requests[id] = nil
                rows.removeAll { $0.id == id }
            } catch is CancellationError {
                if mode == .web { try? store.remove(location) }
            } catch {
                if mode.usesSystemSession { failSystem(id, error as? MediaError ?? .storage) }
                else { try? store.remove(location); fail(id, error as? MediaError ?? .storage) }
            }
        }
    }

    private func ensureRow(_ id: UUID, mode: TransferMode) {
        if !rows.contains(where: { $0.id == id }) { rows.insert(DownloadRow(id: id, mode: mode, name: "오프라인 영상"), at: 0) }
    }

    private func update(_ id: UUID, _ change: (inout DownloadRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    private func fail(_ id: UUID, _ error: MediaError) {
        requests[id] = nil
        startingWeb.remove(id)
        webStarters[id] = nil
        update(id) { $0.failure = error.message; $0.state = "실패" }
    }

    private func failSystem(_ id: UUID, _ error: MediaError) {
        if let job = jobs[id] { ensureRow(id, mode: job.mode) }
        if let task = systemTasks[id] {
            if var job = jobs[id] { job.cancelled = true; try? changeJob(id, to: job) }
            task.cancel()
        } else { try? discardJob(id) }
        fail(id, error)
    }

    private func discardJob(_ id: UUID) throws {
        guard let job = jobs[id] else { return }
        if let ref = job.location, !library.media.contains(where: { $0.id == id }) {
            try store.remove(store.resolve(ref))
        }
        try changeJob(id, to: nil)
    }

    func cancel(_ id: UUID) {
        if var job = jobs[id] {
            do {
                job.cancelled = true
                try changeJob(id, to: job)
                if let task = systemTasks[id] { task.cancel() }
                else if job.ready || !restoring { try discardJob(id) }
            } catch { notice = MediaError.storage.message; return }
        }
        requests[id] = nil
        if webOffer == id { webOffer = nil }
        availableSpaceChecks[id] = nil
        startingWeb.remove(id)
        webStarters[id] = nil
        checks.removeValue(forKey: id)?.cancel()
        validations[id]?.cancel()
        if let transfer = webTransfers.removeValue(forKey: id) { transfer.stop() }
        rows.removeAll { $0.id == id }
        pump()
    }

    func stopPrivateTransfers() {
        for id in rows.filter({ $0.mode == .web }).map(\.id) { cancel(id) }
    }

    private func save(_ data: LibraryData) throws {
        guard unlocked, libraryLoaded else { throw MediaError.storage }
        try store.writeLibrary(data)
        library = data
    }

    func modifyLibrary(_ update: (inout LibraryData) -> Void) {
        var next = library
        update(&next)
        do { try save(next) } catch { notice = MediaError.storage.message }
    }

    func localURL(_ item: SavedMedia) -> URL? {
        guard unlocked, let url = try? store.resolve(item.location), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func export(_ item: SavedMedia) -> URL? {
        guard unlocked else { return nil }
        do { return try store.export(item) } catch { notice = MediaError.storage.message; return nil }
    }

    func removeExport(_ url: URL) { try? store.remove(url.deletingLastPathComponent()) }

    @discardableResult
    func delete(_ ids: Set<UUID>) -> Bool {
        guard unlocked else { return false }
        var success = true
        var next = library
        for item in library.media where ids.contains(item.id) {
            do {
                try store.remove(store.resolve(item.location))
                next.media.removeAll { $0.id == item.id }
            } catch { notice = MediaError.storage.message; success = false }
        }
        do { try save(next) } catch { notice = MediaError.storage.message; success = false }
        return success
    }

    func clear() -> Bool {
        guard unlocked else { return false }
        for id in Set(rows.map(\.id)).union(jobs.keys) { cancel(id) }
        guard rows.isEmpty, jobs.values.allSatisfy(\.cancelled),
              delete(Set(library.media.map(\.id))) else { return false }
        do {
            try store.removeTemporaryFiles()
            try save(LibraryData())
            return true
        } catch {
            notice = MediaError.storage.message
            return false
        }
    }

    func usage() -> Int64 { (try? store.usage()) ?? 0 }
}

enum LocalMediaAsset {
    static func make(_ url: URL, kind: MediaKind) -> AVURLAsset {
        let restrictions: AVAssetReferenceRestrictions = kind == .hls ? .forbidLocalReferenceToRemote : .forbidAll
        return AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: restrictions.rawValue)
        ])
    }
}

@MainActor
private final class WebTransfer: NSObject, WKDownloadDelegate {
    let download: WKDownload
    let id: UUID
    let expected: URL
    let requiresConfirmation: Bool
    weak var center: DownloadCenter?
    private var location: URL?
    private var proposedDestination: ((Bool) -> Void)?

    init(download: WKDownload, id: UUID, expected: URL, requiresConfirmation: Bool, center: DownloadCenter) {
        self.download = download; self.id = id; self.expected = expected
        self.requiresConfirmation = requiresConfirmation; self.center = center
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        if requiresConfirmation {
            guard center?.offerWebSave(id) == true else { completionHandler(nil); center?.webFailed(id, location: nil, error: .busy); return }
            proposedDestination = { [weak self] approved in
                guard approved, let self else { completionHandler(nil); return }
                self.chooseDestination(response, suggestedFilename, completionHandler)
            }
        } else { chooseDestination(response, suggestedFilename, completionHandler) }
    }

    private func chooseDestination(_ response: URLResponse, _ suggestedFilename: String, _ complete: (URL?) -> Void) {
        do {
            guard let actual = response.url, sameOrigin(actual) else { throw MediaError.redirect }
            location = try center?.webDestination(id, response: response, suggested: suggestedFilename)
            complete(location)
        } catch {
            complete(nil)
            center?.webFailed(id, location: location, error: error as? MediaError ?? .storage)
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(request.url.map(sameOrigin) == true ? .allow : .cancel)
    }

    private func sameOrigin(_ url: URL) -> Bool {
        MediaPolicy.secureWebURL(url) && url.host?.lowercased() == expected.host?.lowercased() &&
            (url.port ?? 443) == (expected.port ?? 443)
    }

    func downloadDidFinish(_ download: WKDownload) { center?.webFinished(id, location: location) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let pending = proposedDestination
        proposedDestination = nil
        pending?(false)
        center?.webFailed(id, location: location, error: .response)
    }

    func approve() {
        let pending = proposedDestination
        proposedDestination = nil
        pending?(true)
    }

    func stop() {
        let pending = proposedDestination
        proposedDestination = nil
        pending?(false)
        let location = location
        download.cancel { _ in if let location { try? MediaStore().remove(location) } }
    }
}
