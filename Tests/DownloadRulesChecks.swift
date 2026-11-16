import Foundation

@main
struct DownloadRulesChecks {
    static func main() throws {
        let hosts: Set<String> = ["media.example.org"]
        let publicURL = URL(string: "https://media.example.org/a.mp4")!
        let privateURL = URL(string: "https://other.example.org/b.mp4?sig=1")!
        func row(_ state: DownloadState, mode: TransferMode = .web, failure: String? = nil) -> DownloadRow {
            DownloadRow(id: UUID(), mode: mode, name: "x", state: state, failure: failure)
        }

        // Enqueue gate: scheme, public source, duplicates, queue size.
        precondition(DownloadRules.enqueueRejection(URL(string: "http://media.example.org/a.mp4")!, mode: .web,
                                                    publicHosts: hosts, pending: [], rows: []) == .address)
        precondition(DownloadRules.enqueueRejection(privateURL, mode: .backgroundFile, publicHosts: hosts, pending: [], rows: []) == .untrustedSource)
        precondition(DownloadRules.enqueueRejection(privateURL, mode: .web, publicHosts: hosts, pending: [], rows: []) == nil,
                     "private web saves do not need a registered host")
        precondition(DownloadRules.enqueueRejection(publicURL, mode: .hls, publicHosts: hosts, pending: [publicURL], rows: []) == .duplicate)
        let full = (0..<20).map { _ in row(.queued) }
        precondition(DownloadRules.enqueueRejection(publicURL, mode: .web, publicHosts: hosts, pending: [], rows: full) == .busy)
        let failedOnly = (0..<20).map { _ in row(.failed, failure: "x") }
        precondition(DownloadRules.enqueueRejection(publicURL, mode: .web, publicHosts: hosts, pending: [], rows: failedOnly) == nil,
                     "failed rows do not count against the queue limit")

        // Scheduling: oldest queued first, at most two transfers, skip rows without a request.
        let newest = row(.queued), middle = row(.queued), oldest = row(.queued), orphan = row(.queued)
        let rows = [newest, middle, row(.failed, failure: "x"), orphan, oldest, row(.downloading)]
        let requested: Set<UUID> = [newest.id, middle.id, oldest.id]
        precondition(DownloadRules.startable(rows: rows, activeCount: 0, requested: requested) == [oldest.id, middle.id])
        precondition(DownloadRules.startable(rows: rows, activeCount: 1, requested: requested) == [oldest.id])
        precondition(DownloadRules.startable(rows: rows, activeCount: 2, requested: requested).isEmpty)
        precondition(DownloadRules.startable(rows: rows, activeCount: 0, requested: [orphan.id]).isEmpty)

        // Relaunch: attach only to live, unfinished, uncancelled jobs; restore the paused intent.
        precondition(DownloadRules.restoreAction(job: nil, inLibrary: false) == .cancel)
        precondition(DownloadRules.restoreAction(job: SystemJob(mode: .hls, ready: true), inLibrary: false) == .cancel)
        precondition(DownloadRules.restoreAction(job: SystemJob(mode: .hls), inLibrary: true) == .cancel)
        precondition(DownloadRules.restoreAction(job: SystemJob(mode: .hls, cancelled: true), inLibrary: false) == .cancel)
        precondition(DownloadRules.restoreAction(job: SystemJob(mode: .backgroundFile, paused: true), inLibrary: false) == .attach(paused: true))
        precondition(DownloadRules.restoreAction(job: SystemJob(mode: .backgroundFile), inLibrary: false) == .attach(paused: false))

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let jobs: [UUID: SystemJob] = [
            a: SystemJob(mode: .backgroundFile), b: SystemJob(mode: .backgroundFile),
            c: SystemJob(mode: .hls, ready: true), d: SystemJob(mode: .hls, cancelled: true)
        ]
        precondition(DownloadRules.interruptedJobs(jobs, liveTasks: [a]) == [b],
                     "ready and cancelled jobs are never marked interrupted")

        // Free-space checks every 16 MiB, HLS progress bounds, pause availability, erase gate.
        precondition(!DownloadRules.spaceCheckDue(bytes: 10 << 20, lastChecked: nil))
        precondition(DownloadRules.spaceCheckDue(bytes: 16 << 20, lastChecked: nil))
        precondition(!DownloadRules.spaceCheckDue(bytes: 30 << 20, lastChecked: 16 << 20))
        precondition(DownloadRules.spaceCheckDue(bytes: 32 << 20, lastChecked: 16 << 20))
        precondition(DownloadRules.hlsProgress(received: 30, duration: 60) == 0.5)
        precondition(DownloadRules.hlsProgress(received: 90, duration: 60) == 1)
        precondition(DownloadRules.hlsProgress(received: 5, duration: 0) == nil)
        precondition(DownloadRules.hlsProgress(received: .nan, duration: 60) == nil)
        precondition(DownloadRules.canPause(hasTask: true, job: SystemJob(mode: .hls)))
        precondition(!DownloadRules.canPause(hasTask: false, job: SystemJob(mode: .hls)))
        precondition(!DownloadRules.canPause(hasTask: true, job: SystemJob(mode: .hls, ready: true)))
        precondition(!DownloadRules.canPause(hasTask: true, job: nil))
        precondition(DownloadRules.eraseMayProceed(restoring: false, systemTasks: 0, startingWeb: 0, stoppingWeb: 0))
        precondition(!DownloadRules.eraseMayProceed(restoring: false, systemTasks: 0, startingWeb: 0, stoppingWeb: 1))
        precondition(!DownloadRules.eraseMayProceed(restoring: true, systemTasks: 0, startingWeb: 0, stoppingWeb: 0))

        // Diagnostics: newest first, bounded, and nothing but the code and mode.
        var log: [DiagnosticEntry] = []
        for _ in 0..<(DiagnosticLog.limit + 5) { log = DiagnosticLog.appending(.timeout, mode: .backgroundFile, to: log) }
        log = DiagnosticLog.appending(.authentication, mode: .hls, to: log)
        precondition(log.count == DiagnosticLog.limit)
        precondition(log.first?.code == "authentication" && log.first?.mode == .hls)
        let encoded = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        precondition(!encoded.contains("http") && !encoded.contains("example"))

        // Diagnostics file: survives a round trip and is removed with app data.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("StreamBrowser-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = MediaStore(home: home)
        let before = try store.readDiagnostics()
        precondition(before.isEmpty)
        try store.writeDiagnostics(log)
        let stored = try store.readDiagnostics()
        precondition(stored == log)
        try store.removeDiagnostics()
        let after = try store.readDiagnostics()
        precondition(after.isEmpty)

        print("Download rules checks passed")
    }
}
