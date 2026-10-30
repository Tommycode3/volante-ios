import Foundation
import Observation

/// Talks to the Claude Code running on the Mac.
///
/// Division of labour: the API on the phone answers in a second and a half
/// and costs fractions of a cent, but knows nothing about the projects and has
/// no integrations. The Mac has Slack, Gmail, Calendar, Notion, Drive connected
/// via MCP, sees the repositories, and runs on the subscription — but takes
/// minutes. So: quick questions to the API, real work to the Mac,
/// asynchronously.
@MainActor
@Observable
final class MacBridge {

    struct Job: Identifiable, Hashable, Codable {
        let id: String
        var prompt: String
        var project: String
        var status: String       // queued | running | done | error
        var voice: String
        var result: String
        var isFinished: Bool { status == "done" || status == "error" }
    }

    private(set) var jobs: [Job] = []
    private(set) var lastError: String?
    var isReachable: Bool?

    var settings: AppSettings?
    var diagnostics: Diagnostics?
    /// Called when a job finishes: the sentence to speak and the full text.
    var onCompleted: ((Job) -> Void)?

    private var timer: Timer?

    var pendingCount: Int { jobs.filter { !$0.isFinished }.count }

    // MARK: - Persistence
    //
    // Mac jobs can take minutes: if they lived only in memory, closing the app
    // would mean never receiving the result.

    private var storeURL: URL { Paths.support.appendingPathComponent("mac-jobs.json") }

    private func persist() {
        guard let d = try? JSONEncoder().encode(Array(jobs.prefix(40))) else { return }
        try? d.write(to: storeURL)
    }

    /// Picks up where it left off, and if something was still running it starts
    /// asking the Mac how it went again.
    func restore() {
        guard let d = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Job].self, from: d) else { return }
        jobs = saved
        if pendingCount > 0 {
            diagnostics?.log("mac", "\(pendingCount) lavori ancora aperti, riprendo a controllare")
            startPolling()
        }
    }

    // MARK: - Network

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) throws -> URLRequest {
        guard let base = settings?.bridgeURL, !base.isEmpty,
              let url = URL(string: base.hasSuffix("/") ? base + path.dropFirst() : base + path) else {
            throw NSError(domain: "MacBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Indirizzo del ponte non configurato"])
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(settings?.bridgeToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    func checkHealth() async {
        do {
            let (data, _) = try await URLSession.shared.data(for: try request("/health"))
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            isReachable = (obj?["ok"] as? Bool) ?? false
            if let p = obj?["projects"] as? [String] {
                diagnostics?.log("mac", "raggiungibile — progetti: \(p.joined(separator: ", "))")
            }
        } catch {
            isReachable = false
            diagnostics?.log("mac", "non raggiungibile: \(error.localizedDescription)")
        }
    }

    /// Downloads the memory index of Claude Code on the Mac: it's what tells what
    /// the user works on. It's fetched once and stays on the phone, so the
    /// assistant knows the same things even with the Mac off.
    func fetchContext() async -> String? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: try request("/context"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["context"] as? String, !text.isEmpty else {
                diagnostics?.log("mac", "contesto vuoto o non leggibile")
                return nil
            }
            diagnostics?.log("mac", "contesto scaricato: \(text.count) caratteri")
            return text
        } catch {
            diagnostics?.log("mac", "contesto non scaricato: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sends a job and returns immediately: in the car you don't wait a minute in silence.
    func submit(prompt: String, project: String?) async -> String {
        do {
            var body: [String: Any] = ["prompt": prompt]
            if let project, !project.isEmpty { body["project"] = project }
            let (data, response) = try await URLSession.shared.data(
                for: try request("/task", method: "POST", body: body))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return "Il Mac ha rifiutato la richiesta (codice \(code)). Controlla ponte e token."
            }
            let name = (obj["project"] as? String) ?? "home"
            jobs.insert(Job(id: id, prompt: prompt, project: name,
                            status: "queued", voice: "", result: ""), at: 0)
            persist()
            diagnostics?.log("mac", "inviato \(id) su \(name): \(prompt.prefix(80))")
            startPolling()
            return "Mandato al Mac, progetto \(name). Avviso io quando ha finito."
        } catch {
            lastError = error.localizedDescription
            diagnostics?.log("mac", "invio fallito: \(error.localizedDescription)")
            return "Non sono riuscito a raggiungere il Mac: \(error.localizedDescription)"
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.poll()
            }
        }
        Task { await poll() }
    }

    func stopPolling() {
        timer?.invalidate(); timer = nil
    }

    func poll() async {
        let open = jobs.filter { !$0.isFinished }
        guard !open.isEmpty else { stopPolling(); return }

        for job in open {
            guard let req = try? request("/task/\(job.id)"),
                  let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String,
                  let i = jobs.firstIndex(where: { $0.id == job.id }) else { continue }

            jobs[i].status = status
            jobs[i].voice = (obj["voice"] as? String) ?? ""
            jobs[i].result = (obj["result"] as? String) ?? ""

            if jobs[i].isFinished {
                diagnostics?.log("mac", "\(job.id) \(status)")
                persist()
                onCompleted?(jobs[i])
            }
        }
        if pendingCount == 0 { stopPolling() }
    }
}
