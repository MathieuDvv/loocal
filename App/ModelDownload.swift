import CryptoKit
import Foundation
import Observation
import UIKit

/// How a model's files are split into transfers.
///
/// Legacy (unchunked) downloads fetch each file as one stream over one connection; that's
/// what the 8B has always used, and its in-flight transfers must keep matching after an
/// update. Chunked downloads split large files into byte ranges fetched in parallel over
/// several connections; each piece is written straight into its place in the file as it
/// lands (an empty marker records it), then the whole is hash-verified. Hugging Face's CDN
/// honours `Range` across its redirect (206 Partial Content).
struct DownloadPlan: Sendable {
    static let chunkSize: Int64 = 128 * 1024 * 1024
    static let parallelConnections = 6

    let chunked: Bool

    func ranges(for file: ModelSpec.File) -> [ClosedRange<Int64>] {
        guard chunked, file.size > Self.chunkSize else { return [0...max(file.size - 1, 0)] }
        return stride(from: Int64(0), to: file.size, by: Int(Self.chunkSize)).map { $0...(min($0 + Self.chunkSize, file.size) - 1) }
    }

    func isSplit(_ file: ModelSpec.File) -> Bool { ranges(for: file).count > 1 }

    /// Task description: the file name for whole-file transfers, `name#index` for parts.
    static func task(_ name: String, part: Int?) -> String { part.map { "\(name)#\($0)" } ?? name }

    static func parse(_ description: String) -> (name: String, part: Int?) {
        guard let hash = description.lastIndex(of: "#"), let part = Int(description[description.index(after: hash)...]) else { return (description, nil) }
        return (String(description[..<hash]), part)
    }

    /// The marker for a piece: empty once the piece is written into the file. (Older builds
    /// kept the piece's own bytes here, to stitch at the end.)
    static func partURL(_ directory: URL, _ name: String, _ part: Int) -> URL {
        directory.appendingPathComponent(".parts", isDirectory: true).appendingPathComponent("\(name).\(part)")
    }

    /// The file being filled in, piece by piece.
    static func partialURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent(name + ".partial") }

    /// A file older builds stitched pieces into; complete when it has every byte.
    static func assemblingURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent(name + ".assembling") }

    /// Whether a piece is in: written into the file (empty marker) or, from an older build,
    /// waiting whole in its own part file.
    func isDone(_ directory: URL, _ name: String, _ part: Int, _ range: ClosedRange<Int64>) -> Bool {
        let size = DownloadDelegate.size(of: Self.partURL(directory, name, part))
        return size == 0 || size == Int64(range.count)
    }

    /// Every byte of `file` is on disk but it hasn't been verified and moved into place:
    /// a download cut short at its very end (iOS suspended or ended the app mid-check).
    func awaitsCompletion(_ file: ModelSpec.File, in directory: URL) -> Bool {
        if DownloadDelegate.size(of: Self.assemblingURL(directory, file.name)) == file.size { return true }
        guard isSplit(file) else { return false }
        return ranges(for: file).enumerated().allSatisfy { isDone(directory, file.name, $0.offset, $0.element) }
    }
}

/// The background URLSession owns transfers even while the app is suspended.
/// Hashing, stitching and moving files happen on its serial delegate queue, never the UI thread.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let spec: ModelSpec
    let directory: URL
    let plan: DownloadPlan
    let event: @Sendable (Event) -> Void
    enum Event: Sendable {
        case progress(String, Int64)
        case verified(String)
        case failure(String)
        case finishedEvents
        /// `recover` has finished whatever it could.
        case recovered
    }

    init(spec: ModelSpec, directory: URL, plan: DownloadPlan, event: @escaping @Sendable (Event) -> Void) {
        self.spec = spec
        self.directory = directory
        self.plan = plan
        self.event = event
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription else { return }
        event(.progress(description, totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription else { return }
        let (name, part) = DownloadPlan.parse(description)
        guard let file = spec.files.first(where: { $0.name == name }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        do {
            if let part {
                let ranges = plan.ranges(for: file)
                guard ranges.indices.contains(part) else { return }
                if status == 200, Self.size(of: location) == file.size {
                    // The server ignored Range and sent the whole file: use it as-is.
                    try finish(location, file: file)
                    return
                }
                guard status == 206, Self.size(of: location) == Int64(ranges[part].count) else {
                    throw IslandError.message("A piece of \(file.name) arrived incomplete. Retry to repair it.")
                }
                // Straight into its place in the file: nothing to stitch at the end.
                try Self.place(location, into: DownloadPlan.partialURL(directory, name), at: ranges[part].lowerBound)
                try Self.mark(DownloadPlan.partURL(directory, name, part))
                try completeIfReady(file)
            } else {
                guard status == 200 else { throw IslandError.message("The model server returned an error. Retry the download.") }
                try finish(location, file: file)
            }
        } catch { event(.failure(error.localizedDescription)) }
    }

    /// Once every piece of `file` is in, verify the whole and move it into place. Pieces left
    /// whole by an older build are written in first.
    func completeIfReady(_ file: ModelSpec.File) throws {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.name + ".verified").path) else { return }
        let partial = DownloadPlan.partialURL(directory, file.name)
        let assembling = DownloadPlan.assemblingURL(directory, file.name)
        // An older build finished stitching but never verified: that file is the whole thing.
        if Self.size(of: assembling) == file.size {
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            try FileManager.default.moveItem(at: assembling, to: partial)
            for (index, range) in plan.ranges(for: file).enumerated() where !plan.isDone(directory, file.name, index, range) {
                try Self.mark(DownloadPlan.partURL(directory, file.name, index))
            }
        }
        let ranges = plan.ranges(for: file)
        guard ranges.enumerated().allSatisfy({ plan.isDone(directory, file.name, $0.offset, $0.element) }) else { return }
        for (index, range) in ranges.enumerated() {
            let marker = DownloadPlan.partURL(directory, file.name, index)
            if Self.size(of: marker) == Int64(range.count) && range.count > 0 {
                try Self.place(marker, into: partial, at: range.lowerBound)
                try Self.mark(marker)
            }
        }
        try finish(partial, file: file)
    }

    /// Finishes whatever an earlier run left fully downloaded but unverified. Runs on the
    /// session's delegate queue, so it never overlaps a transfer's own completion.
    func recover() {
        for file in spec.files where plan.awaitsCompletion(file, in: directory) {
            do { try completeIfReady(file) } catch { event(.failure(error.localizedDescription)) }
        }
        event(.recovered)
    }

    /// Verify size and hash, move into place, then write the receipt. A big file's check
    /// reads it all, which can outlast a background wake: extra time is asked for, and if iOS
    /// stops the app anyway, the next launch finishes it (`recover`).
    private func finish(_ source: URL, file: ModelSpec.File) throws {
        let background = DispatchQueue.main.sync { UIApplication.shared.beginBackgroundTask(withName: "Verify \(file.name)") }
        defer { if background != .invalid { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(background) } } }
        do { try Self.verify(source, file: file) } catch {
            // Bad bytes somewhere: start this file over.
            try? FileManager.default.removeItem(at: source)
            clearPieces(file)
            throw error
        }
        let destination = directory.appendingPathComponent(file.name)
        // Picture models keep their parts in subfolders (unet/, vae/…).
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        // A receipt is written only after integrity validation succeeds.
        try Data(spec.revision.utf8).write(to: directory.appendingPathComponent(file.name + ".verified"), options: .atomic)
        clearPieces(file)
        event(.verified(file.name))
    }

    private func clearPieces(_ file: ModelSpec.File) {
        for index in plan.ranges(for: file).indices { try? FileManager.default.removeItem(at: DownloadPlan.partURL(directory, file.name, index)) }
        try? FileManager.default.removeItem(at: DownloadPlan.partialURL(directory, file.name))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { event(.failure(error.localizedDescription)) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { event(.finishedEvents) }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }

    /// Write `source` into `target` at `offset`, creating `target` if needed.
    static func place(_ source: URL, into target: URL, at offset: Int64) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 8 * 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
    }

    /// Record a piece as written into the file: an empty marker.
    static func mark(_ marker: URL) throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    static func verify(_ url: URL, file: ModelSpec.File) throws {
        guard size(of: url) == file.size else { throw IslandError.message("Incomplete download: \(file.name). Retry to repair it.") }
        if let expected = file.sha256 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw IslandError.message("Integrity check failed: \(file.name). Retry to repair it.") }
        }
    }
}

@MainActor @Observable
final class ModelDownload {
    static let sessionID = "local.islandai.app.model-download"
    let spec: ModelSpec
    let directory: URL
    let sessionID: String
    let plan: DownloadPlan
    var isDownloading = false
    var error: String?
    var isReady: Bool { verifiedNames.count == spec.files.count }
    var progress: Double {
        let bytes = spec.files.reduce(Int64(0)) { result, file in
            guard !verifiedNames.contains(file.name) else { return result + file.size }
            let count = plan.ranges(for: file).count
            let parts: Int64 = plan.isSplit(file)
                ? (0..<count).reduce(0) { $0 + (received[DownloadPlan.task(file.name, part: $1)] ?? 0) }
                : received[file.name] ?? 0
            return result + min(parts, file.size)
        }
        return Double(bytes) / Double(max(spec.totalBytes, 1))
    }
    private var verifiedNames = Set<String>()
    private var received: [String: Int64] = [:]
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var delegate: DownloadDelegate!
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    init(spec: ModelSpec, directory: URL, sessionID: String = ModelDownload.sessionID, chunked: Bool = false) {
        self.spec = spec
        self.directory = directory
        self.sessionID = sessionID
        self.plan = DownloadPlan(chunked: chunked)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refreshReceipts()
        delegate = DownloadDelegate(spec: spec, directory: directory, plan: plan) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = chunked ? DownloadPlan.parallelConnections : 1
        config.allowsCellularAccess = false
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in self?.isDownloading = !tasks.isEmpty || self?.recovering == true }
        }
        finishLeftovers()
    }

    /// A download an earlier run took to its last byte but didn't get to verify (iOS ended
    /// or suspended the app mid-check) is finished now, without fetching anything again.
    private var recovering = false
    private func finishLeftovers() {
        guard !recovering, spec.files.contains(where: { !verifiedNames.contains($0.name) && plan.awaitsCompletion($0, in: directory) }) else { return }
        recovering = true
        isDownloading = true
        error = nil
        let delegate = delegate!
        session.delegateQueue.addOperation { delegate.recover() }
    }

    private func refreshReceipts() {
        verifiedNames = Set(spec.files.compactMap { file in
            let url = directory.appendingPathComponent(file.name)
            let receipt = try? String(contentsOf: directory.appendingPathComponent(file.name + ".verified"), encoding: .utf8)
            return receipt == spec.revision && DownloadDelegate.size(of: url) == file.size ? file.name : nil
        })
        // Finished pieces on disk count toward progress and are never fetched again.
        for file in spec.files where plan.isSplit(file) && !verifiedNames.contains(file.name) {
            let whole = plan.awaitsCompletion(file, in: directory)
            for (index, range) in plan.ranges(for: file).enumerated() where whole || plan.isDone(directory, file.name, index, range) {
                received[DownloadPlan.task(file.name, part: index)] = Int64(range.count)
            }
        }
    }

    func start() {
        #if targetEnvironment(simulator)
        error = "Run Loocal on a physical iPhone to download and use the model. The simulator is for interface previews."
        return
        #else
        guard !isDownloading, !isReady else { return }
        error = nil
        received = [:]
        refreshReceipts()
        finishLeftovers()
        do {
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            // Only what's still to come: pieces already written (or a file awaiting its check) are on disk.
            let remaining = Int64(Double(spec.totalBytes) * (1 - progress))
            guard available > remaining + 1_000_000_000 else { throw IslandError.message("Free at least \(ByteCountFormatter.string(fromByteCount: remaining + 1_000_000_000, countStyle: .file)) to install this model.") }
            isDownloading = true
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    let active = Set(tasks.compactMap(\.taskDescription))
                    // Biggest files first so the long transfers start immediately.
                    for file in self.spec.files.sorted(by: { $0.size > $1.size }) where !self.verifiedNames.contains(file.name) {
                        let url = URL(string: "https://huggingface.co/\(self.spec.repository)/resolve/\(self.spec.revision)/\(file.name)")!
                        let ranges = self.plan.ranges(for: file)
                        guard self.plan.isSplit(file) else {
                            if !active.contains(file.name) { self.schedule(URLRequest(url: url), as: file.name) }
                            continue
                        }
                        for (index, range) in ranges.enumerated() {
                            let name = DownloadPlan.task(file.name, part: index)
                            guard !active.contains(name), self.received[name] != Int64(range.count) else { continue }
                            var request = URLRequest(url: url)
                            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                            self.schedule(request, as: name)
                        }
                    }
                }
            }
        } catch { self.error = error.localizedDescription; isDownloading = false }
        #endif
    }

    /// A folder holding links to exactly this model's files, for loading.
    ///
    /// MLX's loader reads every `.safetensors` file under the folder it's given, including
    /// subfolders. The 8B lives at the root of the models folder, where the other models and
    /// the Kokoro voice engine have their own subfolders, so loading straight from there mixed
    /// their weights in ("Unhandled keys … bert"). Links cost nothing and move no data.
    ///
    /// Several replies can start at once, and one may be loading the model from this folder
    /// while another asks for it: an intact folder is reused, never pulled out from under it.
    func loadingDirectory() throws -> URL {
        let fileManager = FileManager.default
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent == "Model" ? ".load-root" : ".load-" + directory.lastPathComponent, isDirectory: true)
        let intact = spec.files.allSatisfy { file in
            (try? fileManager.destinationOfSymbolicLink(atPath: staging.appendingPathComponent(file.name).path)) == directory.appendingPathComponent(file.name).path
        }
        if intact, let names = try? fileManager.contentsOfDirectory(atPath: staging.path), names.count == spec.files.count { return staging }
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in spec.files {
            try fileManager.createDirectory(at: staging.appendingPathComponent(file.name).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: staging.appendingPathComponent(file.name), withDestinationURL: directory.appendingPathComponent(file.name))
        }
        return staging
    }

    /// Stops any transfer and deletes the model's files, for a shared model being removed.
    /// The session is let go too, so the model can be shared again later.
    func remove() {
        session.invalidateAndCancel()
        isDownloading = false
        verifiedNames = []
        received = [:]
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try? fileManager.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent(".load-" + directory.lastPathComponent, isDirectory: true))
    }

    private func schedule(_ request: URLRequest, as name: String) {
        let task = session.downloadTask(with: request)
        task.taskDescription = name
        task.resume()
    }

    private func handle(_ event: DownloadDelegate.Event) {
        switch event {
        case .progress(let name, let bytes): received[name] = bytes
        case .verified(let name):
            verifiedNames.insert(name)
            received = received.filter { DownloadPlan.parse($0.key).name != name }
            if isReady { isDownloading = false; error = nil }
        case .failure(let message):
            error = message
            isDownloading = false
            // Finished pieces stay on disk; Retry fetches only what's missing.
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        case .finishedEvents:
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
        case .recovered:
            recovering = false
            refreshReceipts()
            if isReady { isDownloading = false; error = nil; return }
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in self?.isDownloading = !tasks.isEmpty }
            }
        }
    }
}
