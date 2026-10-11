// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Pylux app entry + CloudStation-4 access-code gate (code screen, heartbeat, ban/delete kick).

import SwiftUI
import UIKit

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
    static let serverURL = "https://cloudstation-server.onrender.com"
    private static let tokenKey = "cloudstation.token"

    @Published private(set) var isAuthorized: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var muted = false
    @Published var errorMessage: String?

    private var sessionId: Int?
    private var pingTask: Task<Void, Never>?

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

    // MARK: Session reporting (hours played, online status)

    private func startReporting() {
        guard isAuthorized, pingTask == nil else { return }
        pingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.beginSession()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { break }
                await self.ping()
            }
        }
    }

    private func stopReporting() {
        pingTask?.cancel()
        pingTask = nil
        if let sid = sessionId {
            sessionId = nil
            Task { _ = await self.request("/api/session/end", body: ["sessionId": sid]) }
        }
    }

    private func beginSession() async {
        guard let (status, obj) = await request("/api/session/start") else { return }
        if status == 401 || status == 403 {
            revoke(message: (obj["error"] as? String) == "banned" ? "Your access was suspended" : "Access removed")
            return
        }
        if status == 200 { sessionId = obj["sessionId"] as? Int }
    }

    private func ping() async {
        guard let sid = sessionId else {
            await beginSession()
            return
        }
        guard let (status, obj) = await request("/api/session/ping", body: ["sessionId": sid]) else { return }
        if status == 401 || status == 403 {
            revoke(message: (obj["error"] as? String) == "banned" ? "Your access was suspended" : "Access removed")
            return
        }
        if status == 200 { muted = (obj["muted"] as? Bool) ?? false }
    }

    private func validateOnLaunch() async {
        guard let (status, obj) = await request("/api/me", method: "GET") else {
            startReporting() // offline: keep going, the ping loop will enforce later
            return
        }
        if status == 401 || status == 403 {
            revoke(message: (obj["error"] as? String) == "banned" ? "Your access was suspended" : "Access removed")
        } else {
            muted = (obj["muted"] as? Bool) ?? false
            startReporting()
        }
    }

    /// Server said the user is banned/deleted: clear the token, stop everything, show the code screen.
    private func revoke(message: String?) {
        pingTask?.cancel()
        pingTask = nil
        sessionId = nil
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
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
    }
}