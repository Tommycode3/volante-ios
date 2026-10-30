import Foundation
import CryptoKit
import Observation

/// Downloads episodes before you set off.
///
/// This was the worst flaw: the app streamed the MP3 while you drove, and in
/// tunnels or on stretches with poor coverage it stopped. An episode
/// downloaded the night before doesn't have this problem — and it also
/// unlocks everything else, because only on a local file can you measure
/// loudness and route the audio through the processing chain.
@MainActor
@Observable
final class DownloadManager: NSObject {

    /// guid -> progress 0…1 while downloading
    private(set) var progress: [String: Double] = [:]
    private(set) var downloaded: Set<String> = []
    var diagnostics: Diagnostics?
    /// Called when a download finishes: that's the moment to measure loudness.
    var onFinished: ((_ guid: String, _ file: URL) -> Void)?

    @ObservationIgnored private var guidForTask: [Int: String] = [:]
    @ObservationIgnored private var urlForTask: [Int: URL] = [:]

    // The background session survives the app being closed: downloads
    // continue and are delivered on relaunch.
    @ObservationIgnored private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(
            withIdentifier: "com.tommasomaggiolo.volante.downloads")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        rescan()
        _ = session          // reattaches downloads that survived a relaunch
    }

    // MARK: - Paths

    /// File name that's stable across launches: Swift's `hashValue` isn't.
    static func fileName(for guid: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(guid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mp3"
    }

    static func fileURL(for guid: String) -> URL {
        Paths.episodes.appendingPathComponent(fileName(for: guid))
    }

    func localFile(for guid: String) -> URL? {
        let u = Self.fileURL(for: guid)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func isDownloaded(_ guid: String) -> Bool { downloaded.contains(guid) }
    func isDownloading(_ guid: String) -> Bool { progress[guid] != nil }

    /// The file name is the md5 of the guid, so you can't go back from the disk:
    /// the list of downloaded guids is kept separately and checked against the files.
    private static let listKey = "downloadedGuids"

    func rescan() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.listKey) ?? []
        downloaded = Set(saved.filter {
            FileManager.default.fileExists(atPath: Self.fileURL(for: $0).path)
        })
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(downloaded), forKey: Self.listKey)
    }

    var totalBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.episodes, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for u in files {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    var megabytes: Int { Int(totalBytes / 1_048_576) }

    // MARK: - Actions

    func download(_ episode: Episode) {
        guard !isDownloaded(episode.guid), !isDownloading(episode.guid) else { return }
        let task = session.downloadTask(with: episode.audioURL)
        guidForTask[task.taskIdentifier] = episode.guid
        urlForTask[task.taskIdentifier] = Self.fileURL(for: episode.guid)
        progress[episode.guid] = 0
        diagnostics?.log("download", "avvio \(episode.shortTitle)")
        task.resume()
    }

    func cancel(_ guid: String) {
        session.getAllTasks { tasks in
            Task { @MainActor in
                for t in tasks where self.guidForTask[t.taskIdentifier] == guid {
                    t.cancel()
                }
                self.progress[guid] = nil
            }
        }
    }

    func remove(_ guid: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: guid))
        downloaded.remove(guid)
        persist()
        Loudness.forget(guid)
        diagnostics?.log("download", "rimosso \(guid.suffix(12))")
    }

    /// Keeps only the latest N downloaded episodes.
    func prune(keeping episodes: [Episode], limit: Int) {
        let keep = Set(episodes.prefix(limit).map(\.guid))
        for g in downloaded where !keep.contains(g) { remove(g) }
    }
}

// MARK: - Delegate (runs off the main thread)

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let ratio = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            if let guid = self.guidForTask[id] { self.progress[guid] = ratio }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // Must be moved right away: the temporary file disappears when the method returns.
        let id = downloadTask.taskIdentifier
        let staged = Paths.episodes.appendingPathComponent("staged-\(id).tmp")
        try? FileManager.default.removeItem(at: staged)
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil

        Task { @MainActor in
            guard let guid = self.guidForTask[id],
                  let dest = self.urlForTask[id] else { return }
            self.guidForTask[id] = nil
            self.urlForTask[id] = nil
            self.progress[guid] = nil
            guard moved else {
                self.diagnostics?.log("download", "spostamento fallito")
                return
            }
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: staged, to: dest)
                self.downloaded.insert(guid)
                self.persist()
                self.diagnostics?.log("download", "completato \(guid.suffix(12))")
                self.onFinished?(guid, dest)
            } catch {
                self.diagnostics?.log("download", "errore: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { @MainActor in
            if let guid = self.guidForTask[id] {
                self.progress[guid] = nil
                self.guidForTask[id] = nil
                self.diagnostics?.log("download", "fallito: \(error.localizedDescription)")
            }
        }
    }
}
