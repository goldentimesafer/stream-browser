import Foundation

/// Where a download is in its life cycle. The queue logic switches on these cases;
/// `label` is only for display, so wording changes cannot break the state machine.
enum DownloadState: Equatable {
    case queued, awaitingResponse, checkingSource, reconnecting, systemDownloading, paused
    case downloading, awaitingImport, awaitingUnlock, awaitingRecovery, validating, failed

    var label: String {
        switch self {
        case .queued: "대기 중"
        case .awaitingResponse: "응답 대기"
        case .checkingSource: "출처 확인 중"
        case .reconnecting: "시스템 작업 확인 중"
        case .systemDownloading: "시스템에서 다운로드 중"
        case .paused: "일시정지"
        case .downloading: "다운로드 중"
        case .awaitingImport: "저장 확인 대기"
        case .awaitingUnlock: "잠금 해제 후 저장 확인"
        case .awaitingRecovery: "저장 복구 대기"
        case .validating: "재생 확인 중"
        case .failed: "실패"
        }
    }
}

struct DownloadRow: Identifiable, Equatable {
    let id: UUID
    let mode: TransferMode
    var name: String
    var state = DownloadState.queued
    var progress: Double?
    var bytes: Int64 = 0
    var failure: String?
    var paused = false
}

/// Pure decisions of the download manager. They depend only on Foundation so the
/// macOS command-line checks can exercise them without WebKit or AVFoundation.
enum DownloadRules {
    static let maxConcurrent = 2
    static let maxQueued = 20
    /// Re-check free space after this many more bytes have arrived.
    static let spaceCheckStride: Int64 = 16 * 1024 * 1024

    enum EnqueueRejection: Equatable { case address, untrustedSource, duplicate, busy }

    /// Why a new request must be refused, or nil when it may join the queue.
    static func enqueueRejection(_ url: URL, mode: TransferMode, publicHosts: Set<String>,
                                 pending: some Collection<URL>, rows: [DownloadRow]) -> EnqueueRejection? {
        guard MediaPolicy.secureWebURL(url) else { return .address }
        if mode.usesSystemSession, !MediaPolicy.publicURL(url, hosts: publicHosts) { return .untrustedSource }
        if pending.contains(url) { return .duplicate }
        guard rows.filter({ $0.failure == nil }).count < maxQueued else { return .busy }
        return nil
    }

    /// Queued rows to start now, oldest first, limited to the free transfer slots.
    static func startable(rows: [DownloadRow], activeCount: Int, requested: Set<UUID>) -> [UUID] {
        var slots = maxConcurrent - activeCount
        var result: [UUID] = []
        for row in rows.reversed() where row.state == .queued && row.failure == nil {
            guard slots > 0 else { break }
            guard requested.contains(row.id) else { continue }
            result.append(row.id)
            slots -= 1
        }
        return result
    }

    enum RestoreAction: Equatable { case cancel, attach(paused: Bool) }

    /// What to do with a system task found alive after the app relaunches.
    static func restoreAction(job: SystemJob?, inLibrary: Bool) -> RestoreAction {
        guard let job, !job.ready, !inLibrary, !job.cancelled else { return .cancel }
        return .attach(paused: job.paused == true)
    }

    /// Journal entries whose system task no longer exists and that never finished.
    static func interruptedJobs(_ jobs: [UUID: SystemJob], liveTasks: Set<UUID>) -> Set<UUID> {
        Set(jobs.filter { id, job in !liveTasks.contains(id) && !job.ready && !job.cancelled }.keys)
    }

    static func spaceCheckDue(bytes: Int64, lastChecked: Int64?) -> Bool {
        bytes - (lastChecked ?? 0) >= spaceCheckStride
    }

    /// Fraction of an HLS asset received, or nil when the expected duration is unknown.
    static func hlsProgress(received: Double, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, received.isFinite else { return nil }
        return min(1, max(0, received / duration))
    }

    static func canPause(hasTask: Bool, job: SystemJob?) -> Bool {
        hasTask && job?.ready == false && job?.cancelled == false
    }

    /// Erasing app data may only claim completion once nothing can still write files.
    static func eraseMayProceed(restoring: Bool, systemTasks: Int, startingWeb: Int, stoppingWeb: Int) -> Bool {
        !restoring && systemTasks == 0 && startingWeb == 0 && stoppingWeb == 0
    }
}

enum DiagnosticLog {
    static let limit = 50

    static func appending(_ error: MediaError, mode: TransferMode, to entries: [DiagnosticEntry], now: Date = Date()) -> [DiagnosticEntry] {
        var next = entries
        next.insert(DiagnosticEntry(id: UUID(), date: now, mode: mode, code: error.rawValue), at: 0)
        if next.count > limit { next.removeLast(next.count - limit) }
        return next
    }
}
