// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Pylux app entry + CloudStation-4 access-code gate (code screen, heartbeat, ban/delete kick).

import Network
import SwiftUI
import UIKit

/// Server address (no trailing slash). Used by the gate and by the relay.
private let csServerBase = "https://cloudstation-server.onrender.com"

@main
struct PyluxApp: App {
    @UIApplicationDelegateAdaptor(PyluxAppDelegate.self) private var appDelegate
    @StateObject private var gate = CloudStationGate.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if gate.isAuthorized {
                    ContentView()
                        .overlay(alignment: .bottomLeading) { RemoteOverlay() }
                } else {
                    CodeGateView()
                }
            }
            .environmentObject(gate)
            .onChange(of: scenePhase) { newPhase in
                gate.scenePhaseChanged(newPhase)
            }
        }
    }
}

// MARK: - Gate

extension Notification.Name {
    /// Posted when the server banned / deleted this user or revoked the code.
    static let cloudStationRevoked = Notification.Name("cloudStationRevoked")
}

@MainActor
final class CloudStationGate: ObservableObject {
    static let shared = CloudStationGate()

    /// Your deployed server (no trailing slash).
    static let serverURL = csServerBase
    private static let tokenKey = "cloudstation.token"

    @Published private(set) var isAuthorized: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var muted = false
    @Published var errorMessage: String?
    @Published private(set) var remoteStatus = ""
    @Published private(set) var remoteActive = false
    /// Console credentials received from the host (used later to add the console to Pylux).
    private(set) var remoteConsole: RemoteConsole?
    private var remoteProxy: RelayClientProxy?

    private var sessionId: Int?
    private var pingTask: Task<Void, Never>?
    private var isStreaming = false

    private var token: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: Self.tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            }
        }
    }

    private var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown"
    }

    private init() {
        isAuthorized = UserDefaults.standard.string(forKey: Self.tokenKey) != nil
        if isAuthorized {
            Task { await self.validateOnLaunch() }
        }
    }

    // MARK: Public

    func redeem(code: String) async {
        errorMessage = nil
        isChecking = true
        defer { isChecking = false }
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (status, obj) = await request(
            "/api/redeem",
            body: ["code": clean, "deviceId": deviceId],
            auth: false
        ) else {
            errorMessage = "No connection"
            return
        }
        if status == 200, let t = obj["token"] as? String {
            token = t
            muted = (obj["muted"] as? Bool) ?? false
            isAuthorized = true
            startReporting()
        } else {
            errorMessage = (obj["error"] as? String) ?? "Error"
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isAuthorized else { return }
        switch phase {
        case .active:
            startReporting()
        case .background:
            stopReporting()
        default:
            break
        }
    }

    // MARK: Remote session (stream through the CloudStation relay)

    func startRemote() async {
        guard isAuthorized, !remoteActive else { return }
        remoteStatus = "Looking for a free host…"
        guard let (st, obj) = await request("/api/connect") else {
            remoteStatus = "No connection"
            return
        }
        if st == 503 { remoteStatus = "No host available right now"; return }
        guard st == 200, let ticket = obj["ticket"] as? String else {
            remoteStatus = (obj["error"] as? String) ?? "Error"
            return
        }
        guard let (cst, cobj) = await request("/api/console/\(ticket)", method: "GET"), cst == 200 else {
            remoteStatus = "The host has no console registered yet"
            return
        }
        guard let tok = token else { return }
        let proxy = RelayClientProxy()
        proxy.onClosed = { [weak self] reason in
            Task { @MainActor in self?.remoteClosed(reason) }
        }
        do {
            try proxy.start(token: tok, ticket: ticket)
        } catch {
            remoteStatus = "Could not open the local ports"
            return
        }
        remoteProxy = proxy
        remoteConsole = RemoteConsole(json: cobj)
        remoteActive = true
        remoteStatus = "Connecting to host…"
    }

    func stopRemote() {
        remoteProxy?.stop()
        remoteProxy = nil
        remoteActive = false
        remoteStatus = ""
    }

    private func remoteClosed(_ reason: String) {
        remoteProxy?.stop()
        remoteProxy = nil
        remoteActive = false
        if reason == "access revoked" {
            revoke(message: "Your access was suspended")
        } else {
            remoteStatus = "Remote session ended (\(reason))"
        }
    }

    // MARK: Reporting
    // While idle the app only checks every 20s that the user is still allowed (ban / delete).
    // While a stream is running it also keeps a session open on the server (hours played).

    /// Called by StreamSession when a stream starts.
    func streamStarted() {
        guard isAuthorized else { return }
        isStreaming = true
        if sessionId == nil {
            Task { await self.beginSession() }
        }
    }

    /// Called by StreamSession when a stream stops (safe to call more than once).
    func streamStopped() {
        isStreaming = false
        endSession()
    }

    private func startReporting() {
        guard isAuthorized, pingTask == nil else { return }
        pingTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func stopReporting() {
        pingTask?.cancel()
        pingTask = nil
        endSession()
    }

    private func tick() async {
        if isStreaming {
            await ping()
        } else {
            await checkMe()
        }
    }

    private func endSession() {
        guard let sid = sessionId else { return }
        sessionId = nil
        Task { _ = await self.request("/api/session/end", body: ["sessionId": sid]) }
    }

    private func revokeMessage(_ obj: [String: Any]) -> String {
        (obj["error"] as? String) == "banned" ? "Your access was suspended" : "Access removed"
    }

    private func beginSession() async {
        guard sessionId == nil else { return }
        guard let (status, obj) = await request("/api/session/start") else { return }
        if status == 401 || status == 403 {
            revoke(message: revokeMessage(obj))
            return
        }
        if status == 200, isStreaming { sessionId = obj["sessionId"] as? Int }
    }

    private func ping() async {
        guard let sid = sessionId else {
            await beginSession()
            return
        }
        guard let (status, obj) = await request("/api/session/ping", body: ["sessionId": sid]) else { return }
        if status == 401 || status == 403 {
            revoke(message: revokeMessage(obj))
            return
        }
        if status == 200 { muted = (obj["muted"] as? Bool) ?? false }
    }

    private func checkMe() async {
        guard let (status, obj) = await request("/api/me", method: "GET") else { return }
        if status == 401 || status == 403 {
            revoke(message: revokeMessage(obj))
        } else if status == 200 {
            muted = (obj["muted"] as? Bool) ?? false
        }
    }

    private func validateOnLaunch() async {
        await checkMe()
        if isAuthorized { startReporting() }
    }

    /// Server said the user is banned/deleted: clear the token, stop everything, show the code screen.
    private func revoke(message: String?) {
        pingTask?.cancel()
        pingTask = nil
        sessionId = nil
        isStreaming = false
        token = nil
        errorMessage = message
        isAuthorized = false
        NotificationCenter.default.post(name: .cloudStationRevoked, object: nil)
    }

    // MARK: HTTP

    private func request(
        _ path: String,
        method: String = "POST",
        body: [String: Any] = [:],
        auth: Bool = true
    ) async -> (Int, [String: Any])? {
        guard let url = URL(string: Self.serverURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60 // free Render instances can take ~50s to wake up
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let t = token {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, obj)
        } catch {
            return nil
        }
    }
}

// MARK: - Code entry screen

struct CodeGateView: View {
    @EnvironmentObject private var gate: CloudStationGate
    @State private var code = ""
    @State private var showHostMode = false

    private let bg = Color(red: 0.06, green: 0.06, blue: 0.09)
    private let blue = Color(red: 0.0, green: 0.62, blue: 0.89)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("PyluxLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                Text("CloudStation-4")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                TextField("Access Code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)

                if let e = gate.errorMessage {
                    Text(e)
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Button {
                    Task { await gate.redeem(code: code) }
                } label: {
                    Group {
                        if gate.isChecking {
                            ProgressView()
                        } else {
                            Text("Enter").font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundColor(.white)
                    .background(blue)
                    .cornerRadius(24)
                }
                .disabled(gate.isChecking || code.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Host mode") { showHostMode = true }
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .padding(.top, 12)
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHostMode) { HostModeView() }
    }
}


// MARK: - Relay protocol
// Binary frame: [type:1][id:2 big-endian][payload]. The server forwards frames untouched.
// The host (iPhone next to the PS4) talks to the PS4 (TCP 9295 + UDP 9296); the client proxy listens on
// 127.0.0.1 (same ports) so Pylux can connect to "127.0.0.1" as if it were the console.

private enum RelayFrameType: UInt8 {
    case tcpOpen = 1, tcpData = 2, tcpClose = 3, udpData = 4
}

private func relayFrame(_ type: RelayFrameType, id: UInt16, payload: Data = Data()) -> Data {
    var d = Data()
    d.append(type.rawValue)
    d.append(UInt8(id >> 8))
    d.append(UInt8(id & 0xFF))
    d.append(payload)
    return d
}

private func parseRelayFrame(_ d: Data) -> (RelayFrameType, UInt16, Data)? {
    guard d.count >= 3, let t = RelayFrameType(rawValue: d[d.startIndex]) else { return nil }
    let id = (UInt16(d[d.startIndex + 1]) << 8) | UInt16(d[d.startIndex + 2])
    return (t, id, d.subdata(in: (d.startIndex + 3)..<d.endIndex))
}

private func relayWsURL(_ path: String) -> URL? {
    URL(string: csServerBase.replacingOccurrences(of: "https://", with: "wss://") + path)
}

/// Thin wrapper around URLSessionWebSocketTask.
private final class RelaySocket: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false
    var onBinary: ((Data) -> Void)?
    var onText: (([String: Any]) -> Void)?
    var onClose: ((String) -> Void)?

    func connect(url: URL, headers: [String: String]) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.maximumMessageSize = 1 << 20
        t.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                let reasonData = self.task?.closeReason
                let reason = reasonData.flatMap { String(data: $0, encoding: .utf8) } ?? error.localizedDescription
                self.finish(reason)
            case .success(let msg):
                switch msg {
                case .data(let d):
                    self.onBinary?(d)
                case .string(let str):
                    if let data = str.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onText?(obj)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        onClose?(reason)
    }
}

// MARK: Host side (runs on the iPhone next to the PS4)

final class RelayHost: @unchecked Sendable {
    private let q = DispatchQueue(label: "cs.relay.host")
    private var socket: RelaySocket?
    private let ps4Host: String
    private let hostKey: String
    private var tcp: [UInt16: NWConnection] = [:]
    private var udp: [UInt16: NWConnection] = [:]
    private var stopped = true
    var onStatus: ((String) -> Void)?

    init(ps4Host: String, hostKey: String) {
        self.ps4Host = ps4Host
        self.hostKey = hostKey
    }

    func start() {
        q.async {
            self.stopped = false
            self.connect()
        }
    }

    func stop() {
        q.async {
            self.stopped = true
            self.socket?.close()
            self.socket = nil
            self.closeAll()
            self.onStatus?("Stopped")
        }
    }

    private func connect() {
        guard !stopped, let url = relayWsURL("/ws/host") else { return }
        let s = RelaySocket()
        socket = s
        s.onBinary = { [weak self] d in self?.q.async { self?.handleFrame(d) } }
        s.onText = { [weak self] obj in self?.q.async { self?.handleControl(obj) } }
        s.onClose = { [weak self] reason in self?.q.async { self?.closedByServer(reason) } }
        onStatus?("Connecting to server…")
        s.connect(url: url, headers: ["x-host-key": hostKey])
    }

    private func closedByServer(_ reason: String) {
        socket = nil
        closeAll()
        guard !stopped else { return }
        onStatus?("Disconnected (\(reason)). Retrying…")
        q.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }

    private func handleControl(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "hello":
            onStatus?("Online, waiting for a player")
        case "client_connected":
            closeAll()
            onStatus?("Player connected: \(obj["name"] as? String ?? "")")
        case "client_left":
            closeAll()
            onStatus?("Online, waiting for a player")
        default:
            break
        }
    }

    private func handleFrame(_ data: Data) {
        guard let (type, id, payload) = parseRelayFrame(data) else { return }
        switch type {
        case .tcpOpen:
            openTCP(id)
        case .tcpData:
            tcp[id]?.send(content: payload, completion: .contentProcessed { _ in })
        case .tcpClose:
            tcp[id]?.cancel()
            tcp[id] = nil
        case .udpData:
            sendUDP(id, payload)
        }
    }

    private func openTCP(_ id: UInt16) {
        let c = NWConnection(host: NWEndpoint.Host(ps4Host), port: 9295, using: .tcp)
        tcp[id] = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .failed, .cancelled:
                self.q.async {
                    if self.tcp[id] === c {
                        self.tcp[id] = nil
                        self.socket?.send(relayFrame(.tcpClose, id: id))
                    }
                }
            default:
                break
            }
        }
        c.start(queue: q)
        receiveTCP(c, id)
    }

    private func receiveTCP(_ c: NWConnection, _ id: UInt16) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.socket?.send(relayFrame(.tcpData, id: id, payload: d))
            }
            if isComplete || error != nil {
                c.cancel()
                return
            }
            self.receiveTCP(c, id)
        }
    }

    private func sendUDP(_ id: UInt16, _ payload: Data) {
        let c: NWConnection
        if let existing = udp[id] {
            c = existing
        } else {
            c = NWConnection(host: NWEndpoint.Host(ps4Host), port: 9296, using: .udp)
            udp[id] = c
            c.start(queue: q)
            receiveUDP(c, id)
        }
        c.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func receiveUDP(_ c: NWConnection, _ id: UInt16) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.socket?.send(relayFrame(.udpData, id: id, payload: d))
            }
            if error != nil { return }
            self.receiveUDP(c, id)
        }
    }

    private func closeAll() {
        for (_, c) in tcp { c.cancel() }
        for (_, c) in udp { c.cancel() }
        tcp.removeAll()
        udp.removeAll()
    }
}

// MARK: Client side (runs on the remote player's phone)

final class RelayClientProxy: @unchecked Sendable {
    private let q = DispatchQueue(label: "cs.relay.client")
    private let socket = RelaySocket()
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var tcp: [UInt16: NWConnection] = [:]
    private var udp: [UInt16: NWConnection] = [:]
    private var nextId: UInt16 = 1
    private var stopped = false
    var onClosed: ((String) -> Void)?

    func start(token: String, ticket: String) throws {
        let loopback = NWEndpoint.Host.ipv4(IPv4Address.loopback)

        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        tcpParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: loopback, port: NWEndpoint.Port(rawValue: 9295)!)
        let tl = try NWListener(using: tcpParams)
        tl.newConnectionHandler = { [weak self] conn in self?.q.async { self?.acceptTCP(conn) } }
        tl.start(queue: q)
        tcpListener = tl

        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true
        udpParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: loopback, port: NWEndpoint.Port(rawValue: 9296)!)
        let ul = try NWListener(using: udpParams)
        ul.newConnectionHandler = { [weak self] conn in self?.q.async { self?.acceptUDP(conn) } }
        ul.start(queue: q)
        udpListener = ul

        guard let url = relayWsURL("/ws/client?ticket=\(ticket)") else { return }
        socket.onBinary = { [weak self] d in self?.q.async { self?.handleFrame(d) } }
        socket.onClose = { [weak self] reason in self?.q.async { self?.finish(reason) } }
        socket.connect(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    func stop() {
        q.async {
            self.stopped = true
            self.socket.close()
            self.shutdownLocal()
        }
    }

    private func finish(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        shutdownLocal()
        onClosed?(reason)
    }

    private func shutdownLocal() {
        tcpListener?.cancel()
        udpListener?.cancel()
        tcpListener = nil
        udpListener = nil
        for (_, c) in tcp { c.cancel() }
        for (_, c) in udp { c.cancel() }
        tcp.removeAll()
        udp.removeAll()
    }

    private func allocId() -> UInt16 {
        nextId = nextId == UInt16.max ? 1 : nextId + 1
        return nextId
    }

    // Frames coming from the host (PS4 -> player)
    private func handleFrame(_ data: Data) {
        guard let (type, id, payload) = parseRelayFrame(data) else { return }
        switch type {
        case .tcpData:
            tcp[id]?.send(content: payload, completion: .contentProcessed { _ in })
        case .tcpClose:
            closeTCP(id, notify: false)
        case .udpData:
            udp[id]?.send(content: payload, completion: .contentProcessed { _ in })
        case .tcpOpen:
            break
        }
    }

    // Local TCP connections from Pylux (player -> PS4)
    private func acceptTCP(_ conn: NWConnection) {
        let id = allocId()
        tcp[id] = conn
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.q.async { self?.closeTCP(id, notify: true) } }
        }
        conn.start(queue: q)
        socket.send(relayFrame(.tcpOpen, id: id))
        receiveTCP(conn, id)
    }

    private func receiveTCP(_ conn: NWConnection, _ id: UInt16) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.socket.send(relayFrame(.tcpData, id: id, payload: d))
            }
            if isComplete || error != nil {
                self.closeTCP(id, notify: true)
                return
            }
            self.receiveTCP(conn, id)
        }
    }

    private func closeTCP(_ id: UInt16, notify: Bool) {
        guard let c = tcp[id] else { return }
        tcp[id] = nil
        c.cancel()
        if notify { socket.send(relayFrame(.tcpClose, id: id)) }
    }

    // Local UDP datagrams from Pylux (one flow per source port)
    private func acceptUDP(_ conn: NWConnection) {
        let id = allocId()
        udp[id] = conn
        conn.start(queue: q)
        receiveUDP(conn, id)
    }

    private func receiveUDP(_ conn: NWConnection, _ id: UInt16) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.socket.send(relayFrame(.udpData, id: id, payload: d))
            }
            if error != nil { return }
            self.receiveUDP(conn, id)
        }
    }
}

// MARK: - Console credentials delivered by the host

struct RemoteConsole {
    var nickname: String
    var macHex: String
    var target: Int
    var registKeyHex: String
    var rpKeyHex: String
    var rpKeyType: Int

    init(json: [String: Any]) {
        nickname = (json["nickname"] as? String) ?? "PS4"
        macHex = (json["mac"] as? String) ?? ""
        target = (json["target"] as? Int) ?? 0
        registKeyHex = (json["registKey"] as? String) ?? ""
        rpKeyHex = (json["rpKey"] as? String) ?? ""
        rpKeyType = (json["rpKeyType"] as? Int) ?? 0
    }
}

// MARK: - Remote button (shown on the main screen)

struct RemoteOverlay: View {
    @EnvironmentObject private var gate: CloudStationGate
    @State private var showHost = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !gate.remoteStatus.isEmpty {
                Text(gate.remoteStatus)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        if gate.remoteActive {
                            gate.stopRemote()
                        } else {
                            await gate.startRemote()
                        }
                    }
                } label: {
                    Label(gate.remoteActive ? "Stop remote" : "Remote", systemImage: "cloud.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.0, green: 0.62, blue: 0.89))
                        .cornerRadius(20)
                }
                Button {
                    showHost = true
                } label: {
                    Text("Host")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.18))
                        .cornerRadius(20)
                }
            }
        }
        .padding(16)
        .sheet(isPresented: $showHost) { HostModeView() }
    }
}

// MARK: - Host mode screen (for the owner's iPhone next to the PS4)

final class HostModeModel: ObservableObject {
    @Published var status = "Stopped"
    @Published var running = false
    private var host: RelayHost?

    func start(hostKey: String, ps4Host: String) {
        stop()
        let h = RelayHost(ps4Host: ps4Host, hostKey: hostKey)
        h.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.status = s }
        }
        host = h
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        h.start()
    }

    func stop() {
        host?.stop()
        host = nil
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

struct HostModeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = HostModeModel()
    @State private var hostKey = UserDefaults.standard.string(forKey: "cs.hostKey") ?? ""
    @State private var ps4Ip = UserDefaults.standard.string(forKey: "cs.ps4Ip") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Host settings")) {
                    SecureField("Host key", text: $hostKey)
                        .textInputAutocapitalization(.never)
                    TextField("PS4 IP address", text: $ps4Ip)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                }
                Section(header: Text("Status")) {
                    Text(model.status)
                }
                Section(footer: Text("Keep this screen open and the phone plugged in while hosting.")) {
                    Button(model.running ? "Stop hosting" : "Start hosting") {
                        if model.running {
                            model.stop()
                        } else {
                            UserDefaults.standard.set(hostKey, forKey: "cs.hostKey")
                            UserDefaults.standard.set(ps4Ip, forKey: "cs.ps4Ip")
                            model.start(hostKey: hostKey, ps4Host: ps4Ip)
                        }
                    }
                    .disabled(!model.running && (hostKey.isEmpty || ps4Ip.isEmpty))
                }
            }
            .navigationTitle("Host mode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
