import AVFoundation
import SwiftUI
import UIKit
import WebKit

struct HLSDownloadOptions {
    var maximumHeight = 0
    var audioLanguage = ""
    var subtitleLanguage = ""

    /// Runs on the main actor so the non-Sendable configuration never crosses an isolation boundary.
    @MainActor func configuration(for url: URL) async throws -> AVAssetDownloadConfiguration {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetHTTPCookiesKey: [HTTPCookie](),
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidRemoteReferenceToLocal.rawValue)
        ])
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: "오프라인 영상")
        if maximumHeight > 0 {
            let predicate = AVAssetVariantQualifier.predicate(forPresentationHeight: CGFloat(maximumHeight), operatorType: .lessThanOrEqualTo)
            configuration.primaryContentConfiguration.variantQualifiers = [AVAssetVariantQualifier(predicate: predicate)]
        }
        if !audioLanguage.isEmpty || !subtitleLanguage.isEmpty {
            let preferred = try await asset.load(.preferredMediaSelection)
            guard let selection = preferred.mutableCopy() as? AVMutableMediaSelection else { throw MediaError.selection }
            for (characteristic, language) in [(AVMediaCharacteristic.audible, audioLanguage), (.legible, subtitleLanguage)] where !language.isEmpty {
                guard let group = try await asset.loadMediaSelectionGroup(for: characteristic) else {
                    if language == "none" { continue }
                    throw MediaError.selection
                }
                if language == "none" {
                    guard group.allowsEmptySelection else { throw MediaError.selection }
                    selection.select(nil, in: group)
                } else {
                    guard let option = group.options.first(where: {
                        let tag = ($0.extendedLanguageTag ?? $0.locale?.identifier ?? "").lowercased()
                        return tag == language || tag.hasPrefix(language + "-") || tag.hasPrefix(language + "_")
                    }) else { throw MediaError.selection }
                    selection.select(option, in: group)
                }
            }
            configuration.primaryContentConfiguration.mediaSelections = [selection]
        }
        return configuration
    }
}

@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var library = LibraryData()
    @Published private(set) var rows: [DownloadRow] = []
    @Published var notice: String?
    @Published private(set) var webOffer: UUID?
    /// Host of the pending web save, shown in the confirmation so the user can see which site is downloading.
    var webOfferHost: String? { webOffer.flatMap { requests[$0]?.host } }
    /// File name, format and size of the pending web save, from the server response.
    @Published private(set) var webOfferDetails: String?
    @Published private(set) var libraryRecoveryRequired = false
    @Published private(set) var isErasing = false
    /// Recent download failures (code and mode only), newest first.
    @Published private(set) var diagnostics: [DiagnosticEntry] = []
    private var diagnosticsLoaded = false
    private(set) var unlocked = false
    private var opened = false
    private var foreground = false
    private var libraryLoaded = false
    private var journalLoaded = false
    private let store = MediaStore()
    private var jobs: [UUID: SystemJob] = [:]
    private var requests: [UUID: URL] = [:]
    private var hlsOptions: [UUID: HLSDownloadOptions] = [:]
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
    private var stoppingWeb = Set<UUID>()
    private var monitor: Task<Void, Never>?
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
        } else {
            monitor?.cancel()
            for task in validations.values { task.cancel() }
            stopPrivateTransfers()
        }
    }

    func unlock() {
        unlocked = true
        do {
            if !libraryLoaded {
                do { library = try store.readLibrary(); libraryLoaded = true; libraryRecoveryRequired = false }
                catch is DecodingError {
                    libraryRecoveryRequired = true
                    notice = "저장 목록이 손상되었습니다. 설정의 저장 목록 복구를 사용하세요. 영상 원본은 유지됩니다."
                    return
                }
            }
            try loadJournal()
            loadDiagnostics()
            reconcileCancelledJobs()
            try store.recoverImports(&library, excluding: Set(jobs.filter { $0.value.cancelled }.keys))
            for id in library.media.map(\.id) {
                rows.removeAll { $0.id == id }
                requests[id] = nil
            }
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

    func repairLibrary() {
        guard unlocked, foreground, libraryRecoveryRequired else { return }
        do {
            library = try store.repairLibrary()
            libraryLoaded = true
            libraryRecoveryRequired = false
            unlock()
            notice = "저장 목록을 복구했습니다. 일부 이름이나 북마크는 백업 시점으로 돌아갈 수 있습니다."
        } catch { notice = "목록을 복구하지 못했습니다. 원본은 보존되어 있습니다. 저장공간과 기기 잠금 상태를 확인하세요." }
    }

    private func loadDiagnostics() {
        guard !diagnosticsLoaded, let stored = try? store.readDiagnostics() else { return }
        diagnostics = stored
        diagnosticsLoaded = true
    }

    private func recordFailure(_ error: MediaError, mode: TransferMode) {
        loadDiagnostics()
        diagnostics = DiagnosticLog.appending(error, mode: mode, to: diagnostics)
        // Best effort: a full disk must not turn a recorded failure into a second one.
        try? store.writeDiagnostics(diagnostics)
    }

    func clearDiagnostics() {
        diagnostics = []
        diagnosticsLoaded = true
        do { try store.removeDiagnostics() } catch { notice = MediaError.storage.message }
    }

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
            update(id) { $0.state = job.ready ? .awaitingImport : .reconnecting }
        }
        Task {
            let fileTasks = await files.allTasks
            let streamTasks = await streams.allTasks
            let live = fileTasks + streamTasks
            for task in live {
                guard let id = jobID(task) else { task.cancel(); continue }
                let job = jobs[id]
                let inLibrary = library.media.contains { $0.id == id }
                let action = DownloadRules.restoreAction(job: job, inLibrary: inLibrary)
                // A cancelled job keeps its task registered so the completion callback can discard it.
                if let job, !job.ready, !inLibrary { systemTasks[id] = task }
                guard case .attach(let paused) = action, let job else { task.cancel(); continue }
                ensureRow(id, mode: job.mode)
                if paused && task.state == .running { task.suspend() }
                if !paused && task.state == .suspended { task.resume() }
                update(id) { $0.paused = paused; $0.state = paused ? .paused : .systemDownloading }
            }
            restoring = false
            reconcileCancelledJobs()
            processReadyJobs()
            pump()
            for id in DownloadRules.interruptedJobs(jobs, liveTasks: Set(systemTasks.keys)) {
                // Keep the journal entry for any completion event already in flight.
                fail(id, .interrupted)
            }
        }
    }

    func enqueue(_ url: URL, mode: TransferMode, webView: WKWebView? = nil, options: HLSDownloadOptions = HLSDownloadOptions()) {
        guard unlocked, foreground, libraryLoaded, journalLoaded, !isErasing else { return }
        switch DownloadRules.enqueueRejection(url, mode: mode, publicHosts: library.publicHosts, pending: requests.values, rows: rows) {
        case .address: notice = MediaError.address.message; return
        case .untrustedSource: notice = MediaError.untrustedSource.message; return
        case .duplicate: notice = "이 주소는 이미 대기 중이거나 다운로드 중입니다."; return
        case .busy: notice = MediaError.busy.message; return
        case nil: break
        }
        let id = UUID()
        requests[id] = url
        if mode == .hls { hlsOptions[id] = options }
        // Background transfers can finish while the app is closed; ask once so completion can be announced.
        if mode.usesSystemSession { DownloadNotifier.requestPermission() }
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
              !requests.values.contains(url), activeCount < DownloadRules.maxConcurrent, !restoring else {
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
        guard unlocked, foreground, opened, !restoring, !isErasing else { return }
        for id in DownloadRules.startable(rows: rows, activeCount: activeCount, requested: Set(requests.keys)) {
            guard let url = requests[id], let row = rows.first(where: { $0.id == id }) else { continue }
            if let start = webStarters.removeValue(forKey: id) {
                startingWeb.insert(id)
                update(id) { $0.state = .awaitingResponse }
                start()
            } else if row.mode.usesSystemSession {
                let hosts = library.publicHosts
                let mode = row.mode
                update(id) { $0.state = .checkingSource }
                checks[id] = Task {
                    do {
                        let expectedBytes = try await PublicSourceCheck.verify(url, mode: mode, hosts: hosts)
                        let configuration: AVAssetDownloadConfiguration?
                        if mode == .hls { configuration = try await (hlsOptions[id] ?? HLSDownloadOptions()).configuration(for: url) }
                        else { configuration = nil }
                        try Task.checkCancellation()
                        checks[id] = nil
                        guard requests[id] != nil else { return }
                        guard foreground, unlocked else { update(id) { $0.state = .queued }; return }
                        guard library.publicHosts == hosts else { fail(id, .untrustedSource); return }
                        try startSystem(id, url: url, mode: mode, expectedBytes: expectedBytes, configuration: configuration)
                    } catch is CancellationError { }
                    catch {
                        checks[id] = nil
                        if requests[id] != nil { fail(id, MediaError.classify(error)) }
                    }
                    pump()
                }
            }
        }
        startMonitoring()
    }

    private func startSystem(_ id: UUID, url: URL, mode: TransferMode, expectedBytes: Int64?, configuration: AVAssetDownloadConfiguration?) throws {
        try store.reserve(bytes: expectedBytes)
        try changeJob(id, to: SystemJob(mode: mode))
        let task: URLSessionTask
        if mode == .hls {
            guard let configuration else { throw MediaError.hls }
            task = streams.makeAssetDownloadTask(downloadConfiguration: configuration)
        } else {
            task = files.downloadTask(with: URLRequest(url: url))
        }
        task.taskDescription = id.uuidString
        systemTasks[id] = task
        update(id) { $0.state = .systemDownloading }
        task.resume()
    }

    private func jobID(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }

    func receiveFile(_ task: URLSessionDownloadTask, temporary: URL) {
        guard let id = jobID(task) else { return }
        do {
            try loadJournal()
            guard var job = jobs[id], !job.cancelled, job.mode == .backgroundFile, job.location == nil else { return }
            if let response = task.response as? HTTPURLResponse, let error = MediaError.httpStatus(response.statusCode) { throw error }
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
            guard var job = jobs[id], job.mode == .hls else {
                try store.remove(location)
                task.cancel()
                return
            }
            job.location = try store.assetReference(location)
            try changeJob(id, to: job)
        } catch { failSystem(id, .storage) }
    }

    func systemCompleted(_ task: URLSessionTask, error: Error?) {
        guard let id = jobID(task) else { return }
        systemTasks[id] = nil
        availableSpaceChecks[id] = nil
        defer { pump() }
        do {
            try loadJournal()
            guard var job = jobs[id] else { return }
            if job.cancelled { try discardJob(id); return }
            guard !job.ready else { return }
            if let error { failSystem(id, MediaError.classify(error)); return }
            guard job.location != nil else { failSystem(id, .interrupted); return }
            job.ready = true
            try changeJob(id, to: job)
            if !foreground { DownloadNotifier.post(success: true) }
            ensureRow(id, mode: job.mode)
            update(id) { $0.failure = nil }
            if unlocked && foreground { processReadyJobs() }
            else { update(id) { $0.state = .awaitingUnlock } }
        } catch { failSystem(id, .storage) }
    }

    func updateProgress(_ task: URLSessionDownloadTask, bytes: Int64, total: Int64) {
        guard let id = jobID(task), jobs[id]?.cancelled == false else { return }
        update(id) { $0.bytes = bytes; $0.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil }
        if DownloadRules.spaceCheckDue(bytes: bytes, lastChecked: availableSpaceChecks[id]) {
            availableSpaceChecks[id] = bytes
            do { try store.reserve(bytes: nil) }
            catch { cancel(id); notice = MediaError.storage.message }
        }
    }

    func refreshProgress() {
        for (id, transfer) in webTransfers {
            let progress = transfer.download.progress
            update(id) {
                $0.bytes = progress.completedUnitCount
                $0.progress = progress.totalUnitCount > 0 ? min(1, progress.fractionCompleted) : nil
            }
            if DownloadRules.spaceCheckDue(bytes: progress.completedUnitCount, lastChecked: availableSpaceChecks[id]) {
                availableSpaceChecks[id] = progress.completedUnitCount
                do { try store.reserve(bytes: nil) }
                catch { cancel(id); notice = MediaError.storage.message }
            }
        }
        if !systemTasks.isEmpty || !webTransfers.isEmpty { enforceSpaceBudget() }
    }

    private func startMonitoring() {
        guard monitor == nil, foreground, activeCount > 0 else { return }
        monitor = Task { [weak self] in
            defer {
                self?.monitor = nil
                self?.startMonitoring()
            }
            while !Task.isCancelled {
                guard let self, self.foreground, self.activeCount > 0 else { return }
                self.refreshProgress()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func updateHLSProgress(_ task: AVAssetDownloadTask, loaded: [NSValue], expected: CMTimeRange) {
        guard let id = jobID(task), jobs[id]?.cancelled == false else { return }
        let duration = expected.duration.seconds
        let received = loaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        update(id) { $0.progress = DownloadRules.hlsProgress(received: received, duration: duration) }
        enforceSpaceBudget()
    }

    private func enforceSpaceBudget() {
        do { try store.reserve(bytes: nil) }
        catch {
            for id in Set(systemTasks.keys).union(webTransfers.keys) { cancel(id) }
            notice = "남은 저장공간이 부족해 전송을 중단했습니다. 공간을 확보한 뒤 다시 시작하세요."
        }
    }

    func togglePause(_ id: UUID) {
        guard unlocked, foreground, let task = systemTasks[id], var job = jobs[id], !job.cancelled, !job.ready else { return }
        do {
            job.paused = !(job.paused ?? false)
            try changeJob(id, to: job)
            if job.paused == true { task.suspend() } else { task.resume() }
            update(id) { $0.paused = job.paused == true; $0.state = $0.paused ? .paused : .systemDownloading }
        } catch { notice = MediaError.storage.message }
    }

    func canPause(_ id: UUID) -> Bool {
        DownloadRules.canPause(hasTask: systemTasks[id] != nil, job: jobs[id])
    }

    private func attachWebDownload(_ download: WKDownload, id: UUID, expected: URL, requiresConfirmation: Bool = false) {
        startingWeb.remove(id)
        guard unlocked, foreground, requests[id] != nil else { download.cancel { _ in }; pump(); return }
        let transfer = WebTransfer(download: download, id: id, expected: expected, requiresConfirmation: requiresConfirmation, center: self)
        webTransfers[id] = transfer
        download.delegate = transfer
        startMonitoring()
    }

    func offerWebSave(_ id: UUID, response: URLResponse, suggested: String) -> Bool {
        guard webOffer == nil, unlocked, foreground, requests[id] != nil else { return false }
        webOffer = id
        webOfferDetails = Self.fileSummary(name: suggested, ext: MediaPolicy.videoExtension(response, suggested: suggested),
                                           bytes: response.expectedContentLength)
        update(id) { $0.state = .awaitingImport }
        return true
    }

    /// "name · MP4 · 128 MB" for confirmation screens; unknown parts say so instead of guessing.
    static func fileSummary(name: String, ext: String?, bytes: Int64?) -> String {
        let size = (bytes ?? -1) > 0 ? ByteCountFormatter.string(fromByteCount: bytes!, countStyle: .file) : "크기 알 수 없음"
        return "\(MediaPolicy.displayName((name as NSString).deletingPathExtension)) · \(ext?.uppercased() ?? "형식 미확인") · \(size)"
    }

    func answerWebOffer(save: Bool) {
        guard let id = webOffer else { return }
        webOffer = nil
        webOfferDetails = nil
        if save { webTransfers[id]?.approve() } else { cancel(id) }
    }

    func webDestination(_ id: UUID, response: URLResponse, suggested: String) throws -> URL {
        if let response = response as? HTTPURLResponse, let error = MediaError.httpStatus(response.statusCode) { throw error }
        guard unlocked, foreground, requests[id] != nil,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let ext = MediaPolicy.videoExtension(response, suggested: suggested) else { throw MediaError.format }
        try store.reserve(bytes: response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        let name = MediaPolicy.displayName((suggested as NSString).deletingPathExtension)
        update(id) { $0.name = name; $0.state = .downloading }
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
            if store.hasPendingImport(id) { continue }
            guard let reference = job.location, let url = try? store.resolve(reference) else { failSystem(id, .storage); continue }
            ensureRow(id, mode: job.mode)
            validate(id, mode: job.mode, location: url)
        }
    }

    private func validate(_ id: UUID, mode: TransferMode, location: URL) {
        let name = rows.first(where: { $0.id == id })?.name ?? "오프라인 영상"
        update(id) { $0.state = .validating }
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
                    if mode.usesSystemSession { update(id) { $0.state = .awaitingUnlock } }
                    else { try? store.remove(location); fail(id, .interrupted) }
                    return
                }
                let pending = try store.prepareImport(location, id: id, kind: mode.kind, name: name)
                library = try store.finishImport(pending, library: library)
                if mode.usesSystemSession { try? changeJob(id, to: nil) }
                requests[id] = nil
                hlsOptions[id] = nil
                rows.removeAll { $0.id == id }
            } catch is CancellationError {
                if mode == .web && !store.hasPendingImport(id) { try? store.remove(location) }
            } catch {
                if Task.isCancelled || !foreground || !unlocked {
                    update(id) { $0.state = .awaitingUnlock }
                    return
                }
                if store.hasPendingImport(id) {
                    update(id) { $0.state = .awaitingRecovery }
                    notice = "영상을 보존했습니다. 저장공간을 확보한 뒤 설정에서 저장 작업 복구를 누르세요."
                    return
                }
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
        if let mode = rows.first(where: { $0.id == id })?.mode ?? jobs[id]?.mode { recordFailure(error, mode: mode) }
        requests[id] = nil
        hlsOptions[id] = nil
        startingWeb.remove(id)
        webStarters[id] = nil
        update(id) { $0.failure = error.message; $0.state = .failed }
    }

    private func failSystem(_ id: UUID, _ error: MediaError) {
        if !foreground, jobs[id]?.cancelled == false { DownloadNotifier.post(success: false) }
        if let job = jobs[id] { ensureRow(id, mode: job.mode) }
        if let task = systemTasks[id] {
            if var job = jobs[id] { job.cancelled = true; try? changeJob(id, to: job) }
            task.cancel()
        } else { try? discardJob(id) }
        fail(id, error)
    }

    private func discardJob(_ id: UUID) throws {
        guard let job = jobs[id] else { return }
        try store.discardImport(id, library: library)
        if let ref = job.location, !library.media.contains(where: { $0.id == id }) {
            try store.remove(store.resolve(ref))
        }
        try changeJob(id, to: nil)
    }

    private func reconcileCancelledJobs() {
        guard journalLoaded, opened, !restoring, unlocked, foreground else { return }
        for (id, job) in jobs where job.cancelled && systemTasks[id] == nil {
            do { try discardJob(id); rows.removeAll { $0.id == id } }
            catch { notice = "취소한 파일의 정리가 남아 있습니다. 잠금 해제와 저장공간을 확인한 뒤 다시 시도하세요." }
        }
    }

    func cancel(_ id: UUID) {
        if var job = jobs[id] {
            do {
                job.cancelled = true
                try changeJob(id, to: job)
                if let task = systemTasks[id] { task.cancel() }
                else if job.ready || !restoring { try discardJob(id) }
            } catch {
                // A full disk must not prevent the user from stopping network I/O.
                jobs[id] = job
                systemTasks[id]?.cancel()
                validations[id]?.cancel()
                notice = "전송은 중단 요청했지만 취소 기록을 저장하지 못했습니다. 공간 확보 후 다시 정리하세요."
                return
            }
        }
        do { try store.discardImport(id, library: library) }
        catch { notice = MediaError.storage.message; return }
        requests[id] = nil
        hlsOptions[id] = nil
        if webOffer == id { webOffer = nil }
        availableSpaceChecks[id] = nil
        startingWeb.remove(id)
        webStarters[id] = nil
        checks.removeValue(forKey: id)?.cancel()
        validations[id]?.cancel()
        if let transfer = webTransfers.removeValue(forKey: id) {
            stoppingWeb.insert(id)
            transfer.stop()
        }
        rows.removeAll { $0.id == id }
        pump()
    }

    func stopPrivateTransfers() {
        for id in rows.filter({ $0.mode == .web }).map(\.id) { cancel(id) }
    }

    func webCancellationFinished(_ id: UUID) { stoppingWeb.remove(id) }

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

    func clear() async -> Bool {
        guard unlocked, foreground, libraryLoaded, journalLoaded, !isErasing else { return false }
        isErasing = true
        defer { isErasing = false }
        for id in Set(rows.map(\.id)).union(jobs.keys) { cancel(id) }
        // Cancellation completion owns the final system package location.
        // Do not claim erasure while a system transfer can still write files.
        for _ in 0..<25 {
            if DownloadRules.eraseMayProceed(restoring: restoring, systemTasks: systemTasks.count,
                                             startingWeb: startingWeb.count, stoppingWeb: stoppingWeb.count) { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
        }
        reconcileCancelledJobs()
        guard unlocked, foreground, !restoring, systemTasks.isEmpty, stoppingWeb.isEmpty, jobs.isEmpty, rows.isEmpty else {
            notice = "다운로드 취소·정리가 아직 끝나지 않았습니다. 잠시 후 앱 데이터 삭제를 다시 실행하세요."
            return false
        }
        guard
              delete(Set(library.media.map(\.id))) else { return false }
        do {
            for pending in try store.pendingImports() { try store.discardImport(pending.item.id, library: library) }
            try store.removeTemporaryFiles()
            try save(LibraryData())
            try store.removeRecoveryCopies()
            try store.removeDiagnostics()
            diagnostics = []
            return true
        } catch {
            notice = MediaError.storage.message
            return false
        }
    }

    func usage() -> Int64 {
        let locations = Set(library.media.filter { $0.kind == .hls }.map(\.location))
            .union(jobs.values.filter { $0.mode == .hls }.compactMap(\.location))
        return (try? store.usage(hlsLocations: locations)) ?? 0
    }
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
            guard center?.offerWebSave(id, response: response, suggested: suggestedFilename) == true else {
                completionHandler(nil); center?.webFailed(id, location: nil, error: .busy); return
            }
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
        center?.webFailed(id, location: location, error: MediaError.classify(error))
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
        let id = id
        let center = center
        download.cancel { _ in
            if let location { try? MediaStore().remove(location) }
            Task { @MainActor in center?.webCancellationFinished(id) }
        }
    }
}
