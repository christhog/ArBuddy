//
//  LlamaModelDownloadService.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Download Progress

/// Progress information for model download
struct ModelDownloadProgress: Sendable {
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let progress: Double

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: bytesDownloaded)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(downloaded) / \(total)"
    }
}

// MARK: - Download Errors

enum LlamaModelDownloadError: LocalizedError {
    case invalidURL
    case downloadFailed(statusCode: Int?)
    case fileOperationFailed(String)
    case insufficientSpace
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige Download-URL"
        case .downloadFailed(let statusCode):
            if let code = statusCode {
                return "Download fehlgeschlagen (HTTP \(code))"
            }
            return "Download fehlgeschlagen"
        case .fileOperationFailed(let reason):
            return "Dateioperaton fehlgeschlagen: \(reason)"
        case .insufficientSpace:
            return "Nicht genügend Speicherplatz"
        case .cancelled:
            return "Download abgebrochen"
        }
    }
}

// MARK: - Llama Model Download Service

actor LlamaModelDownloadService {
    static let shared = LlamaModelDownloadService()

    private let cacheDirectory: URL
    private var downloadTasks: [String: Task<URL, Error>] = [:]
    private var progressContinuations: [String: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation] = [:]

    private init() {
        // Setup cache directory for LLM models
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("LlamaModels", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache Management

    /// Returns the local cache URL for a model
    func localModelURL(for model: LlamaModelInfo) -> URL {
        cacheDirectory.appendingPathComponent(model.localFileName)
    }

    /// Checks if the model is already cached locally
    func isModelCached(for model: LlamaModelInfo) -> Bool {
        let localURL = localModelURL(for: model)
        return FileManager.default.fileExists(atPath: localURL.path)
    }

    /// Checks available disk space
    func hasEnoughSpace(for model: LlamaModelInfo) -> Bool {
        do {
            let values = try cacheDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage {
                // Need model size plus 100MB buffer
                return available > model.sizeBytes + 100_000_000
            }
        } catch {
            print("Failed to check disk space: \(error)")
        }
        return true // Assume enough space if check fails
    }

    // MARK: - Download

    /// Downloads the model with progress updates
    func downloadModel(_ model: LlamaModelInfo) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let localURL = localModelURL(for: model)

                    // Already cached
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        continuation.yield(ModelDownloadProgress(
                            bytesDownloaded: model.sizeBytes,
                            totalBytes: model.sizeBytes,
                            progress: 1.0
                        ))
                        continuation.finish()
                        return
                    }

                    // Check disk space
                    guard hasEnoughSpace(for: model) else {
                        continuation.finish(throwing: LlamaModelDownloadError.insufficientSpace)
                        return
                    }

                    // Check if download is already in progress
                    if let existingTask = downloadTasks[model.id] {
                        // Wait for existing download
                        let url = try await existingTask.value
                        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? model.sizeBytes
                        continuation.yield(ModelDownloadProgress(
                            bytesDownloaded: fileSize,
                            totalBytes: model.sizeBytes,
                            progress: 1.0
                        ))
                        continuation.finish()
                        return
                    }

                    // Store continuation for progress updates
                    progressContinuations[model.id] = continuation

                    // Start download task
                    let task = Task<URL, Error> {
                        try await performDownload(model: model)
                    }
                    downloadTasks[model.id] = task

                    do {
                        _ = try await task.value
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }

                    downloadTasks[model.id] = nil
                    progressContinuations[model.id] = nil

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func performDownload(model: LlamaModelInfo) async throws -> URL {
        let localURL = localModelURL(for: model)

        print("[LlamaDownload] Starting download: \(model.name) from \(model.downloadURL)")

        // Create a download delegate for progress tracking
        let delegate = DownloadDelegate(modelId: model.id, expectedSize: model.sizeBytes) { [weak self] progress in
            Task {
                await self?.updateProgress(for: model.id, progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: model.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlamaModelDownloadError.downloadFailed(statusCode: nil)
        }

        guard httpResponse.statusCode == 200 else {
            print("[LlamaDownload] Download failed with status \(httpResponse.statusCode)")
            throw LlamaModelDownloadError.downloadFailed(statusCode: httpResponse.statusCode)
        }

        // Move to cache directory
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        print("[LlamaDownload] Model cached: \(localURL.path)")
        return localURL
    }

    private func updateProgress(for modelId: String, progress: ModelDownloadProgress) {
        progressContinuations[modelId]?.yield(progress)
    }

    /// Cancels an ongoing download
    func cancelDownload(for model: LlamaModelInfo) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        progressContinuations[model.id]?.finish(throwing: LlamaModelDownloadError.cancelled)
        progressContinuations[model.id] = nil
    }

    /// Deletes a downloaded model
    func deleteModel(_ model: LlamaModelInfo) throws {
        let localURL = localModelURL(for: model)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
            print("[LlamaDownload] Model deleted: \(model.name)")
        }
    }

    /// Returns the size of cached models in bytes
    func cacheSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for fileURL in contents {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// Clears all cached models
    func clearCache() throws {
        let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for fileURL in contents {
            try FileManager.default.removeItem(at: fileURL)
        }
        print("[LlamaDownload] Cache cleared")
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let modelId: String
    let expectedSize: Int64
    let progressHandler: (ModelDownloadProgress) -> Void

    init(modelId: String, expectedSize: Int64, progressHandler: @escaping (ModelDownloadProgress) -> Void) {
        self.modelId = modelId
        self.expectedSize = expectedSize
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        let progress = Double(totalBytesWritten) / Double(total)

        progressHandler(ModelDownloadProgress(
            bytesDownloaded: totalBytesWritten,
            totalBytes: total,
            progress: min(progress, 1.0)
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled in the async download function
    }
}
