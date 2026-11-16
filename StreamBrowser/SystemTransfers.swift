import AVFoundation
import Foundation
import UserNotifications

final class SystemTransferDelegate: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    // No urlSession(_:task:didReceive:completionHandler:) override: the iOS 18.5 and iOS 26 SDKs
    // disagree on its closure's sendability and the warning is fatal under warnings-as-errors.
    // Default handling gives the same result because the sessions are built with
    // urlCredentialStorage = nil (PublicSourceCheck.configuration): TLS challenges go through
    // system trust evaluation and credential challenges fail with 401, which is reported as
    // MediaError.authentication. The app never supplies a credential either way.

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { DownloadCenter.shared.receiveFile(downloadTask, temporary: location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        MainActor.assumeIsolated { DownloadCenter.shared.receiveAssetLocation(assetDownloadTask, location: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { DownloadCenter.shared.systemCompleted(task, error: error) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        MainActor.assumeIsolated {
            DownloadCenter.shared.updateHLSProgress(assetDownloadTask, loaded: loadedTimeRanges, expected: timeRangeExpectedToLoad)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            DownloadCenter.shared.updateProgress(downloadTask, bytes: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        MainActor.assumeIsolated { DownloadCenter.shared.finishedSystemEvents(identifier) }
    }
}

/// Tells the user when a background transfer ends while the app is not on screen.
/// The text never names the video or its source, because it can appear on the lock screen.
@MainActor
enum DownloadNotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(success: Bool) {
        let content = UNMutableNotificationContent()
        content.title = success ? "영상 다운로드 완료" : "영상 다운로드 실패"
        content.body = success ? "앱을 열면 저장함에 추가됩니다." : "앱에서 다운로드 상태를 확인하세요."
        content.sound = .default
        content.threadIdentifier = "downloads"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
