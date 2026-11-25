import SwiftUI
import AVFoundation

enum CaptureState: String {
    case idle = "待機", armed = "準備中", starting = "開始中", recording = "録画中", finishing = "保存中", saved = "保存済み", partial = "部分失敗"

    var permitsNewTake: Bool { self == .idle || self == .saved || self == .partial }
}

@MainActor
final class CaptureModel: ObservableObject {
    let camera = Camera()
    private let peer = PeerLink()

    @Published var modes: [CameraMode] = []
    @Published var mode: CameraMode?
    @Published var role: DeviceRole = .solo
    @Published var view: Viewpoint = .rear
    @Published var subject = ""
    @Published var throwingHand = "R"
    @Published var throwNumber = 1
    @Published var sessionID = UUID()
    @Published var lockExposure = false
    @Published var lockFocus = false
    @Published var state: CaptureState = .idle
    @Published var connected = false
    @Published var remoteStatus = ""
    @Published var issue: String?
    @Published var saved: [URL] = []
    @Published var remaining = ""
    @Published var activeTake: Take?
    private var waiting: Command?
    private var responseTimeout: Task<Void, Never>?
    private var history = CommandHistory()
    private var activeStart: Command?
    private var events: [CaptureEvent] = []
    private var lastFolder: URL?
    private var pendingFailure: String?
    private var remoteStop: Command?
    private var finalReply: Reply?
    private var lastIssue: String?

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let key = arguments.firstIndex(of: "-FingerBallTestSubject"),
           arguments.indices.contains(key + 1), arguments[key + 1].hasPrefix("TEST_") {
            subject = arguments[key + 1]
        }
        #endif
        camera.onFailure = { [weak self] message in self?.interrupted(message) }
        peer.onConnection = { [weak self] connected in self?.connectionChanged(connected) }
        peer.onPacket = { [weak self] packet, event in self?.receive(packet, event: event) }
        peer.onError = { [weak self] message in self?.issue = message }
        refresh()
    }

    var canConfigure: Bool { state.permitsNewTake && waiting == nil }

    var canStart: Bool {
        canConfigure && mode != nil && role != .recorder && (role == .solo || connected)
            && draft.isValid
    }

    var draft: Take {
        Take(sessionID: sessionID, takeID: UUID(), subjectID: subject, throwNumber: throwNumber, throwingHand: throwingHand)
    }

    func prepare() async {
        do {
            modes = try await camera.prepare()
            if mode == nil { mode = CameraMode.automaticChoice(modes) }
        } catch { issue = error.localizedDescription }
    }

    func changeRole() {
        remoteStatus = ""
        peer.configure(role)
    }

    func refresh() {
        saved = SessionStore.local.takes()
        let capacity = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        remaining = capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "取得不可"
    }

    func start() {
        guard canStart else { return }
        let take = draft
        initialize(take)
        if role == .solo {
            begin(take)
        } else {
            state = .armed
            request(.arm, take: take)
        }
    }

    private func initialize(_ take: Take) {
        activeTake = take
        events = []
        lastFolder = nil
        issue = nil
        pendingFailure = nil
        remoteStatus = ""
        activeStart = nil
        remoteStop = nil
        finalReply = nil
        lastIssue = nil
    }

    private func rotation() -> Int {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return 0 }
        switch scene.interfaceOrientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        default: return 0
        }
    }

    private func begin(_ take: Take) {
        guard let mode else { interrupted("撮影形式を選択してください"); return }
        state = .starting
        let initialEvents = events
        events = []
        let orientation = rotation()
        let iosVersion = UIDevice.current.systemVersion
        Task {
            do {
                try await camera.start(take: take, role: role, view: view, mode: mode,
                                       lockExposure: lockExposure, lockFocus: lockFocus, rotation: orientation,
                                       iosVersion: iosVersion, events: initialEvents)
                events.forEach(camera.log)
                events = []
                state = .recording
                append(CaptureEvent(kind: "recording_started", detail: take.takeID.uuidString))
                if let command = activeStart, role == .recorder { acknowledge(command, status: "recording") }
                if pendingFailure != nil {
                    interrupted(pendingFailure ?? "録画が中断されました")
                } else if remoteStop != nil {
                    finish()
                }
            } catch {
                let message = error.localizedDescription
                if role == .recorder, let command = activeStart {
                    acknowledge(command, status: "failed", error: message)
                }
                fail(message)
                if role == .controller && connected { request(.stop, take: take) }
            }
        }
    }

    func stop() {
        guard state == .recording, let take = activeTake else { return }
        if role == .controller && connected { request(.stop, take: take) }
        finish()
    }

    private func finish() {
        guard state == .recording else { return }
        state = .finishing
        Task {
            let app = UIApplication.shared
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = app.beginBackgroundTask(withName: "Finalize FingerBall take") {
                if backgroundTask != .invalid {
                    app.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
            defer {
                if backgroundTask != .invalid { app.endBackgroundTask(backgroundTask) }
            }
            do {
                let (folder, failure) = try await camera.stop(partialReason: pendingFailure)
                lastFolder = folder
                for event in events { appendToSaved(event, folder: folder) }
                events = []
                lastIssue = pendingFailure ?? failure ?? lastIssue
                if let lastIssue { markSavedPartial(lastIssue) }
                state = lastIssue == nil ? .saved : .partial
                issue = lastIssue
                refresh()
                if role == .recorder, let command = remoteStop ?? activeStart {
                    acknowledge(command, status: state == .saved ? "saved" : "partial", error: lastIssue)
                }
            } catch { fail(error.localizedDescription) }
        }
    }

    private func request(_ action: Action, take: Take) {
        let command = Command(action: action, take: take)
        waiting = command
        do {
            try peer.send(Packet(command: command))
            append(CaptureEvent(kind: "peer_send", detail: "\(action.rawValue) \(command.id)"))
        } catch {
            waiting = nil
            interrupted(error.localizedDescription)
            return
        }
        scheduleTimeout(for: command, seconds: 12)
    }

    private func scheduleTimeout(for command: Command, seconds: Int) {
        responseTimeout?.cancel()
        responseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self, self.waiting?.id == command.id else { return }
            self.waiting = nil
            self.interrupted("子機から \(command.action.rawValue) の応答がありません")
        }
    }

    private func acknowledge(_ command: Command, status: String, error: String? = nil) {
        let reply = Reply(commandID: command.id, takeID: command.take.takeID, status: status, error: error)
        history.save(reply)
        if status == "saved" || status == "partial" { finalReply = reply }
        send(reply)
    }

    private func send(_ reply: Reply) {
        do {
            try peer.send(Packet(reply: reply))
            append(CaptureEvent(kind: "peer_ack_send", detail: "\(reply.status) \(reply.commandID) \(reply.error ?? "")"))
        } catch {
            append(CaptureEvent(kind: "peer_ack_failed", detail: error.localizedDescription))
            if lastFolder != nil { markSavedPartial(error.localizedDescription) }
        }
    }

    private func receive(_ packet: Packet, event: CaptureEvent) {
        if role == .recorder, let command = packet.command {
            if let reply = history.reply(for: command.id) {
                if reply.takeID == activeTake?.takeID { send(reply) }
                return
            }
            guard history.accept(command.id) else { return }
            receive(command, event: event)
        } else if role == .controller, let reply = packet.reply, reply.takeID == activeTake?.takeID {
            append(event)
            remoteStatus = reply.error.map { "\(reply.status) · \($0)" } ?? reply.status
            let expected = waiting?.id == reply.commandID ? waiting : nil
            let action = expected?.action
            if let expected {
                if reply.status == "finishing" {
                    scheduleTimeout(for: expected, seconds: 120)
                } else {
                    waiting = nil
                    responseTimeout?.cancel()
                }
            }
            if let error = reply.error {
                interrupted("子機: \(error)")
            } else if action == .arm && reply.status == "armed", let take = activeTake, state == .armed {
                request(.start, take: take)
                if waiting?.action == .start { begin(take) }
            }
        }
    }

    private func receive(_ command: Command, event: CaptureEvent) {
        switch command.action {
        case .arm:
            guard state.permitsNewTake && mode != nil && command.take.isValid else {
                acknowledge(command, status: "failed", error: "子機の撮影形式または状態を確認してください")
                return
            }
            initialize(command.take)
            append(event)
            state = .armed
            acknowledge(command, status: "armed")
        case .start:
            guard state == .armed && activeTake == command.take else {
                acknowledge(command, status: "failed", error: "子機が対象テイクの準備状態にありません")
                return
            }
            append(event)
            activeStart = command
            begin(command.take)
        case .stop:
            guard activeTake == command.take else {
                acknowledge(command, status: "failed", error: "子機に対象のテイクがありません")
                return
            }
            append(event)
            switch state {
            case .starting, .recording, .finishing:
                remoteStop = command
                acknowledge(command, status: "finishing")
                finish()
            case .armed:
                fail("録画開始前に停止しました")
                acknowledge(command, status: "partial", error: issue)
            case .saved, .partial:
                acknowledge(command, status: finalReply?.status ?? "partial", error: finalReply?.error ?? issue)
            case .idle:
                acknowledge(command, status: "failed", error: "子機に録画がありません")
            }
        }
    }

    private func connectionChanged(_ connected: Bool) {
        let wasConnected = self.connected
        self.connected = connected
        if wasConnected && !connected && (!state.permitsNewTake || waiting != nil) {
            waiting = nil
            responseTimeout?.cancel()
            interrupted("端末間の接続が切れました")
        }
    }

    func interrupted(_ message: String) {
        if case .solo = role, state.permitsNewTake { issue = message; return }
        append(CaptureEvent(kind: "interruption", detail: message))
        switch state {
        case .armed: fail(message)
        case .starting, .finishing: pendingFailure = pendingFailure ?? message
        case .recording:
            pendingFailure = pendingFailure ?? message
            if role == .controller && connected && waiting?.action != .stop, let take = activeTake {
                finish()
                request(.stop, take: take)
            }
            finish()
        case .saved, .partial:
            markSavedPartial(message)
        case .idle: issue = message
        }
    }

    private func append(_ event: CaptureEvent) {
        if state == .recording { camera.log(event) }
        else if let folder = lastFolder { appendToSaved(event, folder: folder) }
        else if activeTake != nil { events.append(event) }
    }

    private func appendToSaved(_ event: CaptureEvent, folder: URL) {
        do { try SessionStore.log(event, to: folder) }
        catch { lastIssue = lastIssue ?? error.localizedDescription }
    }

    private func markSavedPartial(_ message: String) {
        lastIssue = lastIssue ?? message
        issue = lastIssue
        guard let folder = lastFolder else { return }
        state = .partial
        let url = folder.appending(path: "metadata.json")
        do {
            var metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
            metadata.status = "partial"
            metadata.error = lastIssue
            try SessionStore.writeJSON(metadata, to: url)
        } catch { issue = "\(message) · \(error.localizedDescription)" }
    }

    private func fail(_ message: String) {
        state = .partial
        issue = message
    }
}
