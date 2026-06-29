import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A cmux terminal screen plus its hash (for safe approval responses).
struct CmuxScreen {
    let text: String
    let hash: String?
    /// Real per-run colors + CJK-aligned grid for the live terminal view.
    /// nil when the bridge can't read a styled screen (falls back to `text`).
    let styled: CmuxStyledScreen?
}

/// One entry in the terminal's color palette (indexed by a run's `styleId`).
struct CmuxStyle {
    let fg: String?
    let bg: String?
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let faint: Bool
    let inverse: Bool
    let strike: Bool
}

/// A styled span of text on one terminal row.
struct CmuxRun {
    let text: String
    let styleId: Int
}

/// A terminal screen carrying cmux's real colors. `palette[styleId]` resolves a
/// run's color/attributes; `lines` are rows of runs, already CJK-aligned.
struct CmuxStyledScreen {
    let cols: Int
    let bg: String
    let fg: String
    let palette: [CmuxStyle]
    let lines: [[CmuxRun]]

    func style(_ id: Int) -> CmuxStyle? {
        (id >= 0 && id < palette.count) ? palette[id] : nil
    }
}

/// One entry in a directory listing.
struct CmuxDirEntry: Identifiable {
    let id = UUID()
    let name: String
    let isDir: Bool
    let path: String
}

/// A filesystem node read from the Mac, scoped to the terminal's working
/// directory — either a text file (with `content`) or a directory (`entries`).
struct CmuxNode {
    enum Kind { case file, directory, image, video }
    let kind: Kind
    let name: String
    let path: String
    let content: String
    let truncated: Bool
    let entries: [CmuxDirEntry]
    /// Decoded image bytes (image nodes only); nil if absent or too large.
    let imageData: Data?
}

/// Result of a scoped node read (success or a human-readable failure reason).
enum CmuxNodeResult {
    case ok(CmuxNode)
    case failed(String)
}

/// Result of uploading an image into a terminal's cwd.
enum CmuxUploadResult {
    case ok(path: String, relPath: String)
    case failed(String)
}

/// Result of a guarded cmux input send.
enum CmuxSendResult {
    case sent
    case screenChanged(text: String, hash: String?)
    case failed(String)
}

/// HTTP client for communicating with the Cmux iPhone bridge server.
final class BridgeClient {

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case invalidCode
        case expired
        case rateLimited
        case networkError
        case screenChanged
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidCode:      return "Invalid pairing code."
            case .expired:          return "Pairing code expired."
            case .rateLimited:      return "Too many attempts. Try again later."
            case .networkError:     return "Cannot reach bridge server."
            case .screenChanged:    return "Screen changed before the answer landed."
            case .serverError(let msg): return msg
            }
        }
    }

    // MARK: - Properties

    private(set) var baseURL: URL?
    private(set) var token: String?

    private let session: URLSession

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        // Restore saved token from the Keychain (migrating any legacy plaintext
        // copy out of UserDefaults on first launch).
        self.token = KeychainStore.migrate(fromUserDefaults: "bridge_token", account: "bridge_token")
        if let saved = UserDefaults.standard.string(forKey: "bridge_url") {
            self.baseURL = URL(string: saved)
        }
    }

    // MARK: - Configuration

    func configure(host: String, port: UInt16) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)
        UserDefaults.standard.set(urlString, forKey: "bridge_url")
    }

    /// Switch the active bridge to an already-paired Mac (host/port/token known).
    /// Used by the Macs switcher — no pairing round-trip.
    func applyActive(host: String, port: UInt16, token: String) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)
        self.token = token
        UserDefaults.standard.set(urlString, forKey: "bridge_url")
        KeychainStore.set(token, for: "bridge_token")
    }

    var isPaired: Bool {
        token != nil && baseURL != nil
    }

    func clearCredentials() {
        token = nil
        baseURL = nil
        KeychainStore.delete("bridge_token")
        UserDefaults.standard.removeObject(forKey: "bridge_url")
    }

    // MARK: - Pairing

    /// A stable per-install device id (persisted) + a display name, sent at pair
    /// time so each device gets its own revocable token on the bridge.
    static func deviceIdentity() -> (id: String, name: String) {
        let key = "cmuxiphone_device_id"
        let id: String
        if let existing = UserDefaults.standard.string(forKey: key) {
            id = existing
        } else {
            id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
        }
        #if canImport(UIKit)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "iPhone"
        #endif
        return (id, name)
    }

    /// Pairs with the bridge using a 6-digit code.
    /// On success, stores the session token.
    @discardableResult
    func pair(code: String) async throws -> String {
        guard let baseURL else {
            throw BridgeError.networkError
        }

        let url = baseURL.appendingPathComponent("pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send a stable per-install device id + name so the bridge tracks this
        // device individually (re-pairing replaces it, not duplicates) and
        // `cmux-iphone pair --list` shows a real name.
        let dev = Self.deviceIdentity()
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceId": dev.id, "deviceName": dev.name])

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            let result = try JSONDecoder().decode(PairResponse.self, from: data)
            self.token = result.token
            KeychainStore.set(result.token, for: "bridge_token")
            return result.token

        case 401:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if body?.error.contains("expired") == true {
                throw BridgeError.expired
            }
            throw BridgeError.invalidCode

        case 429:
            throw BridgeError.rateLimited

        default:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw BridgeError.serverError(body?.error ?? "Unknown error (HTTP \(httpResponse.statusCode))")
        }
    }

    // MARK: - Commands

    /// Sends a text command to a session's PTY, or directly to a cmux terminal.
    /// `submit` appends Enter (default). Pass `submit: false` to type without
    /// submitting — e.g. a single digit to pick a row in an interactive picker.
    func sendCommand(text: String, sessionId: String? = nil, terminalId: String? = nil, submit: Bool = true) async throws {
        var body: [String: Any] = ["command": text, "submit": submit]
        if let sid = sessionId { body["sessionId"] = sid }
        if let tid = terminalId { body["terminalId"] = tid }
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Sends a named special key (up/down/left/right/enter/escape/tab/backspace)
    /// to a cmux terminal — used to drive interactive TUI pickers like codex's
    /// `/model` popup from the phone.
    func sendKey(terminalId: String, key: String) async throws {
        try await authenticatedPostRaw(path: "command", body: ["key": key, "terminalId": terminalId])
    }

    /// Fetches the live cmux workspace/terminal tree (raw JSON data).
    func fetchCmuxTree() async throws -> Data {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("cmux/tree")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.networkError
        }
        return data
    }

    /// Reads the plain-text screen of one cmux terminal, plus its hash (used to
    /// guard approval responses against the screen changing mid-flight).
    func fetchCmuxScreen(terminalId: String) async throws -> CmuxScreen {
        guard let baseURL, let token else { throw BridgeError.networkError }
        var comps = URLComponents(url: baseURL.appendingPathComponent("cmux/screen"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "id", value: terminalId)]
        guard let url = comps?.url else { throw BridgeError.networkError }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.networkError
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return CmuxScreen(
            text: (json?["text"] as? String) ?? "",
            hash: json?["hash"] as? String,
            styled: Self.parseStyled(json?["styled"] as? [String: Any])
        )
    }

    /// Parse the optional `styled` payload (palette + rows of runs). Returns nil
    /// if absent or malformed so the caller falls back to plain `text`.
    private static func parseStyled(_ obj: [String: Any]?) -> CmuxStyledScreen? {
        guard let obj else { return nil }
        let paletteRaw = obj["palette"] as? [[String: Any]] ?? []
        let palette: [CmuxStyle] = paletteRaw.map { p in
            CmuxStyle(
                fg: p["fg"] as? String,
                bg: p["bg"] as? String,
                bold: p["bold"] as? Bool ?? false,
                italic: p["italic"] as? Bool ?? false,
                underline: p["underline"] as? Bool ?? false,
                faint: p["faint"] as? Bool ?? false,
                inverse: p["inverse"] as? Bool ?? false,
                strike: p["strike"] as? Bool ?? false
            )
        }
        let linesRaw = obj["lines"] as? [[[String: Any]]] ?? []
        let lines: [[CmuxRun]] = linesRaw.map { row in
            row.compactMap { run in
                guard let t = run["t"] as? String else { return nil }
                return CmuxRun(text: t, styleId: run["s"] as? Int ?? 0)
            }
        }
        guard !lines.isEmpty else { return nil }
        return CmuxStyledScreen(
            cols: obj["cols"] as? Int ?? 0,
            bg: obj["bg"] as? String ?? "#1E1E1E",
            fg: obj["fg"] as? String ?? "#FFFFFF",
            palette: palette,
            lines: lines
        )
    }

    /// Read a file or directory referenced in the terminal, scoped server-side to
    /// the terminal's working directory. Returns a human-readable failure on error.
    func fetchCmuxFile(terminalId: String, path filePath: String) async -> CmuxNodeResult {
        guard let baseURL, let token else { return .failed("브리지에 연결되어 있지 않습니다") }
        var comps = URLComponents(url: baseURL.appendingPathComponent("cmux/file"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "id", value: terminalId),
            URLQueryItem(name: "path", value: filePath),
        ]
        guard let url = comps?.url else { return .failed("경로가 올바르지 않습니다") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await performRequest(request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let http = response as? HTTPURLResponse else { return .failed("응답이 없습니다") }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(Self.fileErrorMessage(json?["error"] as? String, status: http.statusCode))
            }
            let type = json?["type"] as? String
            let entries: [CmuxDirEntry] = (json?["entries"] as? [[String: Any]] ?? []).compactMap { e in
                guard let name = e["name"] as? String, let p = e["path"] as? String else { return nil }
                return CmuxDirEntry(name: name, isDir: e["dir"] as? Bool ?? false, path: p)
            }
            let kind: CmuxNode.Kind
            switch type {
            case "dir": kind = .directory
            case "image": kind = .image
            case "video": kind = .video
            default: kind = .file
            }
            let imageData = (json?["data"] as? String).flatMap { Data(base64Encoded: $0) }
            return .ok(CmuxNode(
                kind: kind,
                name: json?["name"] as? String ?? (filePath as NSString).lastPathComponent,
                path: json?["path"] as? String ?? filePath,
                content: json?["content"] as? String ?? "",
                // image: `tooLarge` reuses the truncated flag for the "too big" notice
                truncated: (json?["truncated"] as? Bool ?? false) || (json?["tooLarge"] as? Bool ?? false),
                entries: entries,
                imageData: imageData
            ))
        } catch {
            return .failed("불러오지 못했습니다")
        }
    }

    /// Start a new agent session (cmux workspace) in `cwd` running `agent`.
    func newCmuxSession(cwd: String?, agent: String, name: String?) async -> Bool {
        guard let baseURL, let token else { return false }
        let url = baseURL.appendingPathComponent("cmux/new-session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["agent": agent]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let name, !name.isEmpty { body["name"] = name }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await performRequest(request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    /// Authenticated URL for streaming a media file (video) — token is in the
    /// query so AVPlayer (which can't set headers) can play it directly.
    func mediaURL(terminalId: String, path filePath: String) -> URL? {
        guard let baseURL, let token else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("cmux/media"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "id", value: terminalId),
            URLQueryItem(name: "path", value: filePath),
            URLQueryItem(name: "token", value: token),
        ]
        return comps?.url
    }

    /// Ask the bridge to stand up a TCP forwarder for a localhost dev-server port
    /// and return the proxy port the phone should connect to (on the bridge host).
    func openProxy(port: Int) async -> Int? {
        guard let baseURL, let token else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("proxy/open"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "port", value: String(port))]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return json?["proxyPort"] as? Int
        } catch {
            return nil
        }
    }

    /// Per-terminal run state ("running"/"idle"), derived server-side from the
    /// live screen. Returns nil on failure.
    func fetchCmuxStatuses() async -> [String: String]? {
        guard let baseURL, let token else { return nil }
        let url = baseURL.appendingPathComponent("cmux/statuses")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return json?["statuses"] as? [String: String]
        } catch {
            return nil
        }
    }

    /// Upload an image (photo/screenshot) into the terminal's cwd. Returns the
    /// saved path so the caller can hand it to the agent.
    func uploadCmuxImage(terminalId: String, data: Data, ext: String) async -> CmuxUploadResult {
        guard let baseURL, let token else { return .failed("브리지에 연결되어 있지 않습니다") }
        var comps = URLComponents(url: baseURL.appendingPathComponent("cmux/upload"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "id", value: terminalId),
            URLQueryItem(name: "ext", value: ext),
        ]
        guard let url = comps?.url else { return .failed("경로가 올바르지 않습니다") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/\(ext)", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (respData, response) = try await performRequest(request)
            let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            guard let http = response as? HTTPURLResponse else { return .failed("응답이 없습니다") }
            if (200..<300).contains(http.statusCode) {
                let path = json?["path"] as? String ?? ""
                let rel = json?["relPath"] as? String ?? path
                return .ok(path: path, relPath: rel)
            }
            switch json?["error"] as? String {
            case "too-large": return .failed("이미지가 너무 큽니다")
            case "terminal-cwd-unavailable": return .failed("터미널 작업 폴더를 확인할 수 없습니다")
            default: return .failed("업로드 실패 (\(http.statusCode))")
            }
        } catch {
            return .failed("업로드하지 못했습니다")
        }
    }

    private static func fileErrorMessage(_ reason: String?, status: Int) -> String {
        switch reason {
        case "denied", "outside-workspace": return "보안상 열 수 없는 경로입니다 (민감 파일)"
        case "binary-file": return "바이너리 파일은 미리볼 수 없습니다"
        case "is-a-directory": return "폴더입니다 (파일이 아님)"
        case "not-a-file", "not-found": return "파일을 찾을 수 없습니다"
        case "terminal-cwd-unavailable": return "터미널 작업 폴더를 확인할 수 없습니다"
        default: return "열 수 없습니다 (\(status))"
        }
    }

    /// Send input to a cmux terminal, guarded by the screen hash the phone last
    /// rendered. The bridge refuses (409) if the screen changed since — so an
    /// approval "yes"/"no" can't land on a different prompt.
    func sendCmuxGuarded(terminalId: String, text: String, expectedScreenHash: String?, submit: Bool = true) async -> CmuxSendResult {
        guard let baseURL, let token else { return .failed("not paired") }
        let url = baseURL.appendingPathComponent("command")
        var body: [String: Any] = ["command": text, "terminalId": terminalId, "submit": submit]
        if let h = expectedScreenHash { body["expectedScreenHash"] = h }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            if (200..<300).contains(http.statusCode) { return .sent }
            if http.statusCode == 409 {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return .screenChanged(text: (json?["currentScreen"] as? String) ?? "",
                                      hash: json?["currentHash"] as? String)
            }
            return .failed("HTTP \(http.statusCode)")
        } catch {
            return .failed("network")
        }
    }

    /// Spawns a new agent session.
    func spawnSession(agent: String, cwd: String? = nil) async throws -> String {
        var body: [String: Any] = ["spawn": agent]
        if let cwd { body["cwd"] = cwd }
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.serverError("Failed to spawn session")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["sessionId"] as? String ?? ""
    }

    /// Attaches the live-terminal pin (terminalId + expectedScreenHash) to an
    /// approval body so the bridge can refuse (409) if the screen changed.
    private func pin(_ body: inout [String: Any], terminalId: String?, expectedScreenHash: String?) {
        if let tid = terminalId { body["terminalId"] = tid }
        if let h = expectedScreenHash { body["expectedScreenHash"] = h }
    }

    /// Responds to an approval request.
    func respondToApproval(requestId: String, allow: Bool, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        var decision: [String: Any] = [
            "behavior": allow ? "allow" : "deny"
        ]
        if !allow {
            decision["message"] = "Denied from Cmux iPhone app"
        }
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Responds to an approval with a selected option (for dynamic options / AskUserQuestion).
    func respondToApprovalWithOption(requestId: String, optionLabel: String, index: Int, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": ["behavior": "allow"],
            "selectedOption": optionLabel,
            "optionIndex": index
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Responds with "allow" + adds a permission rule so it doesn't ask again this session.
    func respondToApprovalAllowAll(requestId: String, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        let decision: [String: Any] = [
            "behavior": "allow"
        ]
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision,
            "allowAll": true
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    // MARK: - Status

    /// Toggle supervise mode (broad PreToolUse approval) on the bridge.
    func setSupervise(on: Bool) async throws {
        try await authenticatedPostRaw(path: "supervise", body: ["on": on])
    }

    /// Fetches the current bridge status. /status now requires auth (it exposes
    /// session cwds), so send the bearer token.
    func fetchStatus() async throws -> BridgeStatus {
        guard let baseURL else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(BridgeStatus.self, from: data)
    }

    // MARK: - SSE URL

    /// Returns the URL for the SSE events endpoint, including auth.
    func eventsURL() -> URL? {
        guard let baseURL, let token else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    // MARK: - Private helpers

    private func authenticatedPost(path: String, body: [String: String]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed")
        }
    }

    private func authenticatedPostRaw(path: String, body: [String: Any]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.networkError
        }
        // 409 = the bridge refused because the terminal screen changed since the
        // user was shown the approval (expectedScreenHash mismatch).
        if httpResponse.statusCode == 409 { throw BridgeError.screenChanged }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed (HTTP \(httpResponse.statusCode))")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // Preserve the real reason in the device log (e.g. ATS -1022) before
            // collapsing to the coarse BridgeError the UI consumes.
            if let u = error as? URLError {
                print("[BridgeClient] request failed: code=\(u.errorCode) \(u.localizedDescription) url=\(request.url?.absoluteString ?? "?")")
            } else {
                print("[BridgeClient] request failed: \(error)")
            }
            throw BridgeError.networkError
        }
    }

    // MARK: - Response types

    private struct PairResponse: Decodable {
        let token: String
        let sessionId: String?
        let bridgeId: String?
        let availableAgents: [String]?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    struct BridgeStatus: Decodable {
        let state: String
        let sessionId: String?
        let bridgeId: String?
        let hasPty: Bool
        let activeAgent: String?
        let availableAgents: [String]?
        let sessions: [BridgeSessionInfo]?
        let sseClients: Int
        let pendingPermissions: Int
        let eventBufferSize: Int
        let supervise: Bool?
    }

    struct BridgeSessionInfo: Decodable {
        let id: String
        let agent: String
        let cwd: String
        let folderName: String
        let state: String
    }
}
