import Foundation
import MultipeerConnectivity

enum Action: String, Codable {
    case arm, start, stop
}

struct Command: Codable, Equatable {
    var id = UUID()
    var action: Action
    var take: Take
}

struct Reply: Codable {
    var commandID: UUID
    var takeID: UUID
    var status: String
    var error: String?
}

struct Packet: Codable {
    var command: Command?
    var reply: Reply?
}

struct CommandHistory {
    private var replies: [UUID: Reply] = [:]
    private var pending: Set<UUID> = []

    mutating func accept(_ id: UUID) -> Bool {
        guard replies[id] == nil else { return false }
        return pending.insert(id).inserted
    }

    mutating func save(_ reply: Reply) {
        pending.remove(reply.commandID)
        replies[reply.commandID] = reply
    }

    func reply(for id: UUID) -> Reply? { replies[id] }
}

final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    private static let service = "fingerball-v1"
    private let peer = MCPeerID(displayName: "FingerBall-" + SessionStore.deviceID.uuidString.prefix(8))
    private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var invited: MCPeerID?
    private(set) var remote: MCPeerID?
    var onConnection: ((Bool) -> Void)?
    var onPacket: ((Packet, CaptureEvent) -> Void)?
    var onError: ((String) -> Void)?

    func configure(_ role: DeviceRole) {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        remote = nil
        invited = nil
        session.disconnect()
        onConnection?(false)
        switch role {
        case .solo: break
        case .recorder:
            let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.service)
            advertiser.delegate = self
            self.advertiser = advertiser
            advertiser.startAdvertisingPeer()
        case .controller:
            let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
            browser.delegate = self
            self.browser = browser
            browser.startBrowsingForPeers()
        }
    }

    func send(_ packet: Packet) throws {
        guard let remote else { throw CaptureError.message("相手の端末が接続されていません") }
        try session.send(JSONEncoder().encode(packet), toPeers: [remote], with: .reliable)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            let accept = self.advertiser === advertiser && self.remote == nil && self.invited == nil
            if accept { self.invited = peerID }
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard self.browser === browser, self.remote == nil, self.invited == nil else { return }
            self.invited = peerID
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 12)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { report(error) }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { report(error) }

    private func report(_ error: Error) {
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected where self.invited == peerID:
                self.remote = peerID
                self.onConnection?(true)
            case .notConnected where self.remote == peerID || self.invited == peerID:
                self.remote = nil
                self.invited = nil
                self.onConnection?(false)
                self.browser?.stopBrowsingForPeers()
                self.browser?.startBrowsingForPeers()
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        let id = packet.command?.id ?? packet.reply?.commandID
        let operation = packet.command?.action.rawValue ?? packet.reply?.status ?? "unknown"
        let event = CaptureEvent(kind: "peer_receive", detail: "\(operation) \(id?.uuidString ?? "")")
        DispatchQueue.main.async {
            guard self.remote == peerID else { return }
            self.onPacket?(packet, event)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}
