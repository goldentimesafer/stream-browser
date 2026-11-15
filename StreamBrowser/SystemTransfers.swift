import AVFoundation
import Foundation

final class SystemTransferDelegate: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        completionHandler(method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

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
