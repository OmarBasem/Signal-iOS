//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

public extension OWSAttachmentDownloads {

    // MARK: - Dependencies

    private class var signalService: OWSSignalService {
        return .sharedInstance()
    }

    private class var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    // MARK: -

    func downloadAttachmentPointer(_ attachmentPointer: TSAttachmentPointer,
                                   bypassPendingMessageRequest: Bool) -> Promise<TSAttachmentStream> {
        return Promise { resolver in
            self.downloadAttachmentPointer(attachmentPointer,
                                           bypassPendingMessageRequest: bypassPendingMessageRequest,
                                           success: resolver.fulfill,
                                           failure: resolver.reject)
        }.map { attachments in
            assert(attachments.count == 1)
            guard let attachment = attachments.first else {
                throw OWSAssertionError("missing attachment after download")
            }
            return attachment
        }
    }

    // We want to avoid large downloads from a compromised or buggy service.
    private static let maxDownloadSize = 150 * 1024 * 1024

    @objc
    func retrieveAttachment(job: OWSAttachmentDownloadJob,
                            attachmentPointer: TSAttachmentPointer,
                            success: @escaping (TSAttachmentStream) -> Void,
                            failure: @escaping (Error) -> Void) {
        firstly {
            Self.retrieveAttachment(job: job, attachmentPointer: attachmentPointer)
        }.done(on: .global()) { (attachmentStream: TSAttachmentStream) in
            success(attachmentStream)
        }.catch(on: .global()) { (error: Error) in
            failure(error)
        }
    }

    private class func retrieveAttachment(job: OWSAttachmentDownloadJob,
                                          attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "retrieveAttachment")

        return firstly(on: .global()) { () -> Promise<URL> in
            if attachmentPointer.serverId < 100 {
                Logger.warn("Suspicious attachment id: \(attachmentPointer.serverId)")
            }
            return Self.download(job: job, attachmentPointer: attachmentPointer)
        }.then(on: .global()) { (encryptedFileUrl: URL) -> Promise<TSAttachmentStream> in
            Self.decrypt(encryptedFileUrl: encryptedFileUrl,
                         attachmentPointer: attachmentPointer)
        }.ensure(on: .global()) {
            guard backgroundTask != nil else {
                owsFailDebug("Missing backgroundTask.")
                return
            }
            backgroundTask = nil
        }
    }

    private class DownloadState {
        let job: OWSAttachmentDownloadJob
        let attachmentPointer: TSAttachmentPointer

        let tempFileUrl: URL

        required init(job: OWSAttachmentDownloadJob, attachmentPointer: TSAttachmentPointer) {
            self.job = job
            self.attachmentPointer = attachmentPointer

            tempFileUrl = OWSFileSystem.temporaryFileUrl(isAvailableWhileDeviceLocked: true)
        }
    }

    func test() {}

    private class func download(job: OWSAttachmentDownloadJob,
                                attachmentPointer: TSAttachmentPointer) -> Promise<URL> {

        let downloadState = DownloadState(job: job, attachmentPointer: attachmentPointer)

        return firstly(on: .global()) { () -> Promise<Void> in
            Self.downloadAttempt(downloadState: downloadState)
        }.map(on: .global()) { () -> URL in
            downloadState.tempFileUrl
        }.recover(on: .global()) { (error: Error) -> Promise<URL> in
            do {
                try OWSFileSystem.deleteFileIfExists(url: downloadState.tempFileUrl)
            } catch {
                owsFailDebug("Error: \(error)")
            }

            throw error
        }
    }

    private class func downloadAttempt(downloadState: DownloadState,
                                       resumeData: Data? = nil,
                                       attemptIndex: UInt = 0) -> Promise<Void> {

        return firstly(on: .global()) { () -> Promise<Void> in
            let attachmentPointer = downloadState.attachmentPointer
            let tempFileUrl = downloadState.tempFileUrl

            let promise: Promise<Void> = firstly(on: .global()) { () -> Promise<URL> in
                let sessionManager = self.signalService.cdnSessionManager(forCdnNumber: attachmentPointer.cdnNumber)
                sessionManager.completionQueue = .global()

                let url = try Self.url(for: downloadState, sessionManager: sessionManager)
                let headers: [String: String] = [
                    "Content-Type": OWSMimeTypeApplicationOctetStream
                ]

                let progress = { (progress: Progress, task: URLSessionDownloadTask) in
                    Self.handleDownloadProgress(downloadState: downloadState,
                                                task: task,
                                                progress: progress)
                }

                if let resumeData = resumeData {
                    return sessionManager.resumeDownloadTaskPromise(resumeData: resumeData,
                                                                    dstFileUrl: tempFileUrl,
                                                                    progress: progress)
                } else {
                    return sessionManager.downloadTaskPromise(url.absoluteString,
                                                              verb: .get,
                                                              headers: headers,
                                                              dstFileUrl: tempFileUrl,
                                                              progress: progress)
                }
            }.map(on: .global()) { (completionUrl: URL) in
                if tempFileUrl != completionUrl {
                    throw OWSAssertionError("Unexpected temp file path.")
                }
                guard let fileSize = OWSFileSystem.fileSize(of: tempFileUrl) else {
                    throw OWSAssertionError("Could not determine attachment file size.")
                }
                guard fileSize.int64Value <= Self.maxDownloadSize else {
                    throw OWSAssertionError("Attachment download length exceeds max size.")
                }
            }.recover(on: .global()) { (error: Error) -> Promise<Void> in
                Logger.warn("Error: \(error)")

                let maxAttemptCount = 16
                if IsNetworkConnectivityFailure(error),
                    attemptIndex < maxAttemptCount {

                    return firstly {
                        // Wait briefly before retrying.
                        after(seconds: 0.25)
                    }.then { () -> Promise<Void> in
                        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                            !resumeData.isEmpty {
                            return self.downloadAttempt(downloadState: downloadState, resumeData: resumeData, attemptIndex: attemptIndex + 1)
                        } else {
                            return self.downloadAttempt(downloadState: downloadState, attemptIndex: attemptIndex + 1)
                        }
                    }
                } else {
                    throw error
                }
            }

            promise.catch(on: .global()) { (error: Error) in
                if let statusCode = HTTPStatusCodeForError(error),
                    attachmentPointer.serverId < 100 {
                    // This looks like the symptom of the "frequent 404
                    // downloading attachments with low server ids".
                    owsFailDebug("\(statusCode) Failure with suspicious attachment id: \(attachmentPointer.serverId), \(error)")
                }
            }

            return promise
        }
    }

    private class func url(for downloadState: DownloadState,
                           sessionManager: AFHTTPSessionManager) throws -> URL {

        let attachmentPointer = downloadState.attachmentPointer
        let urlPath: String
        if attachmentPointer.cdnKey.count > 0 {
            guard let encodedKey = attachmentPointer.cdnKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw OWSAssertionError("Invalid cdnKey.")
            }
            urlPath = "attachments/\(encodedKey)"
        } else {
            urlPath = String(format: "attachments/%llu", attachmentPointer.serverId)
        }
        guard let url = URL(string: urlPath, relativeTo: sessionManager.baseURL) else {
            throw OWSAssertionError("Invalid URL.")
        }
        return url
    }

    private class func handleDownloadProgress(downloadState: DownloadState,
                                              task: URLSessionDownloadTask,
                                              progress: Progress) {
        // Don't do anything until we've received at least one byte of data.
        guard progress.completedUnitCount > 0 else {
            return
        }

        guard progress.totalUnitCount <= maxDownloadSize,
            progress.completedUnitCount <= maxDownloadSize else {
                // A malicious service might send a misleading content length header,
                // so....
                //
                // If the current downloaded bytes or the expected total byes
                // exceed the max download size, abort the download.
                owsFailDebug("Attachment download exceed expected content length: \(progress.totalUnitCount), \(progress.completedUnitCount).")
                task.cancel()
                return
        }

        downloadState.job.progress = CGFloat(progress.fractionCompleted)

        // Use a slightly non-zero value to ensure that the progress
        // indicator shows up as quickly as possible.
        let progressTheta: Double = 0.001
        Self.fireProgressNotification(progress: max(progressTheta, progress.fractionCompleted),
                                      attachmentId: downloadState.attachmentPointer.uniqueId)
    }

    // MARK: -

    private static let decryptQueue = DispatchQueue(label: "OWSAttachmentDownloads.decryptQueue")

    private class func decrypt(encryptedFileUrl: URL,
                               attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        // Use decryptQueue to ensure that we only load into memory
        // & decrypt a single attachment at a time.
        return firstly(on: decryptQueue) { () -> TSAttachmentStream in
            return try autoreleasepool { () -> TSAttachmentStream in
                let cipherText = try Data(contentsOf: encryptedFileUrl)
                return try Self.decrypt(cipherText: cipherText,
                                        attachmentPointer: attachmentPointer)
            }
        }.ensure(on: .global()) {
            do {
                try OWSFileSystem.deleteFileIfExists(url: encryptedFileUrl)
            } catch {
                owsFailDebug("Error: \(error).")
            }
        }
    }

    private class func decrypt(cipherText: Data,
                               attachmentPointer: TSAttachmentPointer) throws -> TSAttachmentStream {

        guard let encryptionKey = attachmentPointer.encryptionKey else {
            throw OWSAssertionError("Missing encryptionKey.")
        }
        let plaintext: Data = try Cryptography.decryptAttachment(cipherText,
                                                                 withKey: encryptionKey,
                                                                 digest: attachmentPointer.digest,
                                                                 unpaddedSize: attachmentPointer.byteCount)

        let attachmentStream = databaseStorage.read { transaction in
            TSAttachmentStream(pointer: attachmentPointer, transaction: transaction)
        }
        try attachmentStream.write(plaintext)
        return attachmentStream
    }

    // MARK: -

    @objc
    static let attachmentDownloadProgressNotification = Notification.Name("AttachmentDownloadProgressNotification")
    @objc
    static let attachmentDownloadProgressKey = "attachmentDownloadProgressKey"
    @objc
    static let attachmentDownloadAttachmentIDKey = "attachmentDownloadAttachmentIDKey"

    private class func fireProgressNotification(progress: Double, attachmentId: String) {
        NotificationCenter.default.postNotificationNameAsync(attachmentDownloadProgressNotification,
                                                             object: nil,
                                                             userInfo: [
                                                                attachmentDownloadProgressKey: NSNumber(value: progress),
                                                                attachmentDownloadAttachmentIDKey: attachmentId
        ])
    }
}
