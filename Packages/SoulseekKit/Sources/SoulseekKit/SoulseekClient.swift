#if canImport(Network)
import Foundation
import Network

public struct DownloadID: Hashable, Sendable {
    public let username: String
    public let path: String

    public init(username: String, path: String) {
        self.username = username
        self.path = path
    }
}

public enum DownloadState: Equatable, Sendable {
    /// Connecting to the peer to send QueueUpload.
    case requesting
    /// Peer accepted the request; waiting for a free upload slot on their side.
    case queued(place: UInt32?)
    /// Peer sent TransferRequest; waiting for their file connection.
    case starting
    case transferring
    case completed(URL)
    case failed(String)
}

public struct DownloadUpdate: Sendable {
    public let id: DownloadID
    public let state: DownloadState
    public let received: UInt64
    public let size: UInt64
}

public enum ClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case loggedIn
    case failed(String)
}

/// A local file we share. `virtualPath` is what peers see, backslash-separated.
public struct LocalShare: Sendable {
    public let virtualPath: String
    public let url: URL
    public let size: UInt64

    public init(virtualPath: String, url: URL, size: UInt64) {
        self.virtualPath = virtualPath
        self.url = url
        self.size = size
    }
}

public enum UploadState: Equatable, Sendable {
    case queued
    case transferring
    case completed
    case failed
}

/// Progress of a file we're sending to a peer. `id.username` is the downloader.
public struct UploadUpdate: Sendable {
    public let id: DownloadID
    public let state: UploadState
    public let sent: UInt64
    public let size: UInt64
}

/// Whether peers can connect to us.
public enum ListenerStatus: Equatable, Sendable {
    case off
    /// `accepted`: connections peers have opened to us since the app started.
    case listening(port: UInt16, accepted: Int)
    case failed(String)
}

public enum ClientEvent: Sendable {
    case state(ClientState)
    case searchResponse(SearchResponse)
    case download(DownloadUpdate)
    case upload(UploadUpdate)
    case listener(ListenerStatus)
    case log(String)
}

/// Soulseek client built on Network.framework.
///
/// Like Nicotine+, it listens on a port (2234 by default; the app opens it on the router) and
/// reaches peers both ways at once: a direct connection, plus a ConnectToPeer request through the
/// server asking them to connect to us, so whichever side is reachable gets through. When a peer
/// asks the server to reach us, we dial out with PierceFireWall.
///
/// Connections strangers open to us are kept on a short leash: a cap on unidentified connections
/// (overall and per address) that must say who they are within seconds, small frame and unpack
/// limits, a memory budget, and idle connections closed. Someone connecting directly can claim any
/// username, so messages that touch our downloads are only acted on once the server confirms that
/// user is at that address.
///
/// All state lives on a private serial queue. `onEvent` is always called on the main queue;
/// set it before calling `connect`.
public final class SoulseekClient: @unchecked Sendable {
    public var onEvent: ((ClientEvent) -> Void)?

    public var serverHost = "server.slsknet.org"
    public var serverPort: UInt16 = 2242
    /// Reported to the server so peers try us directly first; nothing listens on it.
    public var advertisedPort: UInt32 = 2234

    public let downloadDirectory: URL
    public let incompleteDirectory: URL

    private let queue = DispatchQueue(label: "colon3.soulseek-client")
    private var server: NWConnection?
    private var serverFrames = FrameBuffer()
    private var username = ""
    private var isLoggedIn = false
    private var activeSearches = Set<UInt32>()

    private var peers: [String: PeerLink] = [:]
    private var addressWaiters: [String: [(PeerAddress?) -> Void]] = [:]
    private var fileLinks: [ObjectIdentifier: FileLink] = [:]

    private var downloads: [DownloadID: DownloadRecord] = [:]
    private var downloadsByToken: [String: DownloadID] = [:]

    private var shares: [String: LocalShare] = [:]
    private var uploadQueue: [UploadJob] = []
    private var activeUpload: UploadJob?
    private var completedUploads: UInt32 = 0
    private var folderBrowses: [UInt32: FolderBrowse] = [:]

    // Listening (see the Incoming connections section)
    private var listenPort: UInt16 = 2234
    private var listener: NWListener?
    private var listenerReady = false
    private var listenerRestartScheduled = false
    private var acceptedConnections = 0
    private var lastListenerEmit = Date.distantPast
    private var listenerEmitScheduled = false
    private var pendingLimiter = ConnectionLimiter(maxTotal: Incoming.maxPending, maxPerAddress: Incoming.maxPendingPerAddress)
    private var pendingIncoming: [ObjectIdentifier: PendingConnection] = [:]
    /// P connections peers opened to us (also in `peers` once they're known to be who they say).
    private var incomingLinks: [ObjectIdentifier: PeerLink] = [:]
    private var idleSweepScheduled = false
    /// ConnectToPeer requests we sent, by token, waiting for the peer to connect to us.
    private var indirectRequests: [UInt32: IndirectRequest] = [:]
    /// Our uploads' file connections being set up, by transfer token.
    private var uploadAttempts: [UInt32: UploadAttempt] = [:]
    /// "username|ip" pairs the server confirmed, so direct connections from them are trusted.
    private var verifiedPeers: [String: Date] = [:]
    /// The IP the server last reported for each user.
    private var lastKnownIPs: [String: String] = [:]
    /// The connection the message being handled came in on; replies go back over it.
    private var replyLink: PeerLink?
    /// Off when the app pauses sharing (away from Wi-Fi); queued requests wait.
    private var sharingAllowed = true
    private var lastShareListReply: [String: Date] = [:]

    public init(downloadDirectory: URL, incompleteDirectory: URL) {
        self.downloadDirectory = downloadDirectory
        self.incompleteDirectory = incompleteDirectory
    }

    // MARK: - Public API

    public func connect(username: String, password: String) {
        queue.async { self.openServer(username: username, password: password) }
    }

    public func disconnect() {
        queue.async { self.tearDown(.disconnected) }
    }

    /// Starts a search and returns its token. Results arrive as `.searchResponse` events.
    @discardableResult
    public func search(_ query: String) -> UInt32 {
        let token = UInt32.random(in: 1..<UInt32.max)
        queue.async {
            guard self.isLoggedIn else { return }
            self.activeSearches.insert(token)
            self.sendServer(.fileSearch(token: token, query: query))
        }
        return token
    }

    /// `folderName` overrides the library folder the file lands in (default: the peer's folder
    /// name), e.g. to drop a missing track into an existing album's folder.
    public func download(username: String, file: SharedFile, folderName: String? = nil) {
        queue.async {
            let id = DownloadID(username: username, path: file.path)
            if let existing = self.downloads[id] {
                switch existing.state {
                case .failed: break
                default: return  // Already in progress or done
                }
            }
            self.downloads[id] = DownloadRecord(id: id, state: .requesting, size: file.size, folderName: folderName)
            self.emitDownload(id)
            self.requestQueuePlace(id)
        }
    }

    public func retry(_ id: DownloadID) {
        queue.async {
            guard var record = self.downloads[id] else { return }
            record.state = .requesting
            record.retries = 0
            self.downloads[id] = record
            self.emitDownload(id)
            self.requestQueuePlace(id)
        }
    }

    public func cancel(_ id: DownloadID) {
        queue.async {
            if let token = self.downloads[id]?.token {
                self.downloadsByToken[self.tokenKey(id.username, token)] = nil
            }
            self.downloads[id] = nil
            for link in self.fileLinks.values {
                if case let .downloading(linkID) = link.role, linkID == id { self.closeFile(link, reason: nil) }
            }
        }
    }

    /// Lists a peer's folder (and its subfolders). `completion` runs on the main queue with full
    /// virtual paths, or nil if the peer can't be reached or doesn't answer within 30 seconds.
    public func browseFolder(username: String, folder: String, completion: @escaping ([SharedFile]?) -> Void) {
        queue.async {
            guard self.isLoggedIn else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let token = UInt32.random(in: 1..<UInt32.max)
            self.folderBrowses[token] = FolderBrowse(username: username, folder: folder, completion: completion)
            self.sendToPeer(username, [.folderContentsRequest(token: token, folder: folder)],
                            onFailure: { [weak self] in self?.finishBrowse(token: token, files: nil) })
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.finishBrowse(token: token, files: nil)
            }
        }
    }

    private func finishBrowse(token: UInt32, files: [SharedFile]?) {
        guard let browse = folderBrowses.removeValue(forKey: token) else { return }
        DispatchQueue.main.async { browse.completion(files) }
    }

    public func updateShares(_ list: [LocalShare]) {
        queue.async {
            var map: [String: LocalShare] = [:]
            for share in list { map[share.virtualPath] = share }
            self.shares = map
            if self.isLoggedIn { self.sendShareCounts() }
        }
    }

    /// Listens on `port` for peers (0: don't listen). Applies right away when logged in, otherwise
    /// at the next login, and becomes the advertised port until `setAdvertisedPort` says otherwise.
    public func setListenPort(_ port: UInt16) {
        queue.async {
            guard port != self.listenPort || (self.isLoggedIn && self.listener == nil) else { return }
            self.listenPort = port
            if port != 0 { self.advertisedPort = UInt32(port) }
            guard self.isLoggedIn else { return }
            self.stopListener()
            self.startListener()
            self.sendServer(.setWaitPort(self.advertisedPort))
        }
    }

    /// The port peers should connect to, when the router maps ours to a different outside port.
    public func setAdvertisedPort(_ port: UInt16) {
        queue.async {
            let value = UInt32(port == 0 ? self.listenPort : port)
            guard value != 0, value != self.advertisedPort else { return }
            self.advertisedPort = value
            if self.isLoggedIn { self.sendServer(.setWaitPort(value)) }
        }
    }

    /// Whether uploads may run (the app turns this off away from Wi-Fi when asked to). An upload
    /// in progress stops and the downloader retries later; queued requests wait.
    public func setSharingAllowed(_ allowed: Bool) {
        queue.async {
            guard allowed != self.sharingAllowed else { return }
            self.sharingAllowed = allowed
            if allowed {
                self.startNextUpload()
            } else if let job = self.activeUpload {
                let link = self.fileLinks.values.first { link in
                    if case let .uploading(token) = link.role { return token == job.token }
                    return false
                }
                if let link {
                    self.closeFile(link, reason: nil)
                } else {
                    self.finishUpload(token: job.token, succeeded: false)
                }
            }
        }
    }

    // MARK: - Server connection

    private func openServer(username: String, password: String) {
        tearDown(.connecting)
        self.username = username
        guard let port = NWEndpoint.Port(rawValue: serverPort) else { return }

        let connection = NWConnection(host: NWEndpoint.Host(serverHost), port: port, using: Self.tcpParameters(timeout: 15))
        server = connection
        serverFrames = FrameBuffer()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.server === connection else { return }
            switch state {
            case .ready:
                self.log("Connected to \(self.serverHost), logging in as \(username)")
                self.sendServer(.login(username: username, password: password,
                                       majorVersion: ServerRequest.majorVersion,
                                       minorVersion: ServerRequest.minorVersion))
                self.receive(on: connection, onData: { [weak self] data in
                    guard let self, self.server === connection else { return }
                    self.handleServerData(data)
                }, onClose: { [weak self] _ in
                    guard let self, self.server === connection else { return }
                    self.tearDown(.failed("Disconnected from server"))
                })
            case let .waiting(error), let .failed(error):
                self.tearDown(.failed("Can't reach server: \(error.localizedDescription)"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func tearDown(_ newState: ClientState) {
        isLoggedIn = false
        activeSearches.removeAll()
        if let server {
            server.stateUpdateHandler = nil
            server.cancel()
        }
        server = nil

        stopListener()
        emit(.listener(.off))
        for attempt in uploadAttempts.values {
            attempt.direct?.stateUpdateHandler = nil
            attempt.direct?.cancel()
        }
        uploadAttempts.removeAll()
        for link in Array(peers.values) { closePeer(link, failed: true) }
        indirectRequests.removeAll()
        for link in Array(fileLinks.values) { closeFile(link, reason: "Disconnected") }
        for waiters in addressWaiters.values { waiters.forEach { $0(nil) } }
        addressWaiters.removeAll()

        for (id, record) in downloads {
            switch record.state {
            case .requesting, .starting, .transferring:
                downloads[id]?.state = .failed("Disconnected")
                emitDownload(id)
            default:
                break
            }
        }
        for job in uploadQueue + [activeUpload].compactMap({ $0 }) {
            emitUpload(username: job.username, path: job.path, state: .failed, sent: 0, size: job.share.size)
        }
        uploadQueue.removeAll()
        for token in Array(folderBrowses.keys) { finishBrowse(token: token, files: nil) }
        activeUpload = nil
        emit(.state(newState))
    }

    private func handleServerData(_ data: Data) {
        serverFrames.append(data)
        while server != nil {
            let body: Data
            do {
                guard let next = try serverFrames.nextFrame() else { return }
                body = next
            } catch {
                tearDown(.failed("Server sent an invalid frame"))
                return
            }
            do {
                let event = try ServerEvent.decode(body)
                handleServerEvent(event)
            } catch {
                log("Couldn't decode server message: \(error)")
            }
        }
    }

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case let .loginSucceeded(greeting, ownIP):
            isLoggedIn = true
            log("Logged in (public IP \(ownIP)). \(greeting)")
            startListener()
            sendServer(.setWaitPort(advertisedPort))
            sendServer(.setStatus(2))
            // We don't take part in the distributed search tree.
            sendServer(.haveNoParent(true))
            sendServer(.branchRoot(username))
            sendServer(.branchLevel(0))
            sendServer(.acceptChildren(false))
            sendShareCounts()
            emit(.state(.loggedIn))

        case let .loginFailed(reason, detail):
            tearDown(.failed(Self.describeLoginFailure(reason, detail)))

        case let .peerAddress(username, ip, port):
            if lastKnownIPs.count > 2000 { lastKnownIPs.removeAll() }
            lastKnownIPs[username] = ip
            let waiters = addressWaiters.removeValue(forKey: username) ?? []
            let address: PeerAddress? = (ip == "0.0.0.0" || port == 0) ? nil : PeerAddress(ip: ip, port: port)
            waiters.forEach { $0(address) }

        case let .connectToPeer(username, type, ip, port, token):
            switch type {
            case ConnectionType.peer.rawValue:
                openPiercedPeer(username: username, ip: ip, port: port, token: token)
            case ConnectionType.file.rawValue:
                openPiercedFile(username: username, ip: ip, port: port, token: token)
            default:
                sendServer(.cantConnectToPeer(token: token, username: username))
            }

        case .relogged:
            tearDown(.failed("Logged in from somewhere else"))

        case let .cantConnectToPeer(token):
            // A peer we asked to connect to us couldn't.
            indirectFailed(token: token)

        case .other:
            break
        }
    }

    private static func describeLoginFailure(_ reason: String, _ detail: String?) -> String {
        switch reason {
        case "INVALIDPASS": return "Wrong password for this username"
        case "INVALIDUSERNAME": return "Invalid username" + (detail.map { ": \($0)" } ?? "")
        case "EMPTYPASSWORD": return "Password can't be empty"
        case "INVALIDVERSION": return "Server rejected this client version"
        case "SVRFULL": return "Server is full, try again later"
        case "SVRPRIVATE": return "Server isn't accepting new accounts"
        default: return "Login failed: \(reason)"
        }
    }

    private func sendServer(_ request: ServerRequest) {
        server?.send(content: request.frame, completion: .contentProcessed { _ in })
    }

    private func sendShareCounts() {
        let folders = Set(shares.keys.map { Self.splitVirtualPath($0).folder })
        sendServer(.sharedFoldersFiles(folders: UInt32(folders.count), files: UInt32(shares.count)))
    }

    private func resolveAddress(_ username: String, completion: @escaping (PeerAddress?) -> Void) {
        let isFirst = addressWaiters[username] == nil
        addressWaiters[username, default: []].append(completion)
        guard isFirst else { return }
        sendServer(.getPeerAddress(username: username))
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let waiters = self.addressWaiters.removeValue(forKey: username) else { return }
            waiters.forEach { $0(nil) }
        }
    }

    // MARK: - Peer (P) connections

    /// Sends messages to a peer, opening a direct connection if there isn't one yet.
    private func sendToPeer(_ username: String, _ messages: [PeerMessage],
                            onSent: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        var frames: [Data] = []
        do {
            for message in messages { frames.append(try message.frame()) }
        } catch {
            log("Couldn't encode message for \(username): \(error)")
            return
        }

        // Answers to a request go back over the connection it came in on.
        if let reply = replyLink, reply.username == username, reply.isReady, !reply.isClosed, let connection = reply.connection {
            frames.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
            reply.lastActivity = Date()
            onSent?()
            return
        }

        if let link = peers[username] {
            if link.isReady, let connection = link.connection {
                frames.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
                link.lastActivity = Date()
                onSent?()
            } else {
                link.outbox += frames
                if let onSent { link.sentHandlers.append(onSent) }
                if let onFailure { link.failureHandlers.append(onFailure) }
            }
            return
        }

        let link = PeerLink(username: username)
        link.outbox = frames
        if let onSent { link.sentHandlers.append(onSent) }
        if let onFailure { link.failureHandlers.append(onFailure) }
        peers[username] = link

        resolveAddress(username) { [weak self] address in
            guard let self, !link.isClosed else { return }
            guard let address else {
                self.log("\(username) is offline or unknown")
                self.closePeer(link, failed: true)
                return
            }
            self.startPeerConnection(link, address: address, firstFrame: PeerInitMessage.peerInit(username: self.username, type: "P").frame)
            // At the same time, ask the server to have them connect to us, in case they can't be
            // reached directly. Whichever connection comes up first is used.
            if self.listenerReady, !link.isReady, !link.isClosed {
                link.indirectToken = self.requestIndirect(.peer(link), username: username, type: .peer)
            }
        }
    }

    private func openPiercedPeer(username: String, ip: String, port: UInt32, token: UInt32) {
        let link = PeerLink(username: username)
        if let existing = peers[username], !existing.isReady {
            // Hand queued messages over to the connection that is actually coming up.
            link.outbox = existing.outbox
            link.sentHandlers = existing.sentHandlers
            link.failureHandlers = existing.failureHandlers
            existing.outbox.removeAll()
            existing.sentHandlers.removeAll()
            existing.failureHandlers.removeAll()
            closePeer(existing, failed: false)
        }
        peers[username] = link
        startPeerConnection(link, address: PeerAddress(ip: ip, port: port),
                            firstFrame: PeerInitMessage.pierceFirewall(token: token).frame,
                            pierceToken: token)
    }

    private func startPeerConnection(_ link: PeerLink, address: PeerAddress, firstFrame: Data, pierceToken: UInt32? = nil) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: address.port)) else {
            closePeer(link, failed: true)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 8))
        link.connection = connection

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .ready:
                guard !link.isReady, link.connection === connection else {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    return
                }
                self.activatePeerLink(link, connection: connection, firstFrame: firstFrame)
            case .waiting, .failed:
                if let pierceToken {
                    self.sendServer(.cantConnectToPeer(token: pierceToken, username: link.username))
                    self.closePeer(link, failed: true)
                } else if !link.isReady, link.indirectToken != nil {
                    // The peer may still connect to us through the server; wait for that.
                    link.directFailed = true
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    if link.connection === connection { link.connection = nil }
                } else {
                    self.closePeer(link, failed: true)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// A peer connection came up (ours, or theirs answering our request): send what's waiting
    /// and start reading. `leftover` is data that arrived along with their first message.
    private func activatePeerLink(_ link: PeerLink, connection: NWConnection, firstFrame: Data?, leftover: Data = Data()) {
        if let token = link.indirectToken {
            indirectRequests[token] = nil
            link.indirectToken = nil
        }
        if let firstFrame { connection.send(content: firstFrame, completion: .contentProcessed { _ in }) }
        link.isReady = true
        link.lastActivity = Date()
        link.outbox.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
        link.outbox.removeAll()
        link.failureHandlers.removeAll()
        let sent = link.sentHandlers
        link.sentHandlers.removeAll()
        sent.forEach { $0() }
        if !leftover.isEmpty { handlePeerData(link, leftover) }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handlePeerData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closePeer(link, failed: false)
        })
    }

    private func closePeer(_ link: PeerLink, failed: Bool) {
        guard !link.isClosed else { return }
        link.isClosed = true
        link.connection?.stateUpdateHandler = nil
        link.connection?.cancel()
        if peers[link.username] === link { peers[link.username] = nil }
        incomingLinks[ObjectIdentifier(link)] = nil
        if let token = link.indirectToken {
            indirectRequests[token] = nil
            link.indirectToken = nil
        }
        link.held.removeAll()
        if failed {
            let handlers = link.failureHandlers
            link.failureHandlers.removeAll()
            handlers.forEach { $0() }
        }
    }

    private func handlePeerData(_ link: PeerLink, _ data: Data) {
        guard !link.isClosed else { return }
        link.frames.append(data)
        link.lastActivity = Date()
        if link.incoming, incomingBufferedBytes() > Incoming.bufferedBudget {
            log("Closed the connection from \(link.username): too much data at once")
            closePeer(link, failed: false)
            return
        }
        while !link.isClosed {
            let body: Data
            do {
                guard let next = try link.frames.nextFrame() else { return }
                body = next
            } catch {
                log("Bad frame from \(link.username): \(error)")
                closePeer(link, failed: false)
                return
            }
            do {
                let message = try PeerMessage.decode(body, inflateLimit: link.incoming ? Incoming.inflateLimit : Zlib.defaultLimit)
                routePeerMessage(link, message)
            } catch {
                log("Couldn't decode message from \(link.username): \(error)")
            }
        }
    }

    /// Hands a message to `handlePeerMessage`, unless it touches our downloads and came over a
    /// connection from someone the server hasn't vouched for yet; those wait for the check.
    private func routePeerMessage(_ link: PeerLink, _ message: PeerMessage) {
        if !link.trusted, Self.needsVerifiedSender(message) {
            guard link.held.count < Incoming.maxHeldMessages else { return }
            link.held.append(message)
            verify(link)
            return
        }
        let previous = replyLink
        replyLink = link
        handlePeerMessage(from: link.username, message)
        replyLink = previous
    }

    private static func needsVerifiedSender(_ message: PeerMessage) -> Bool {
        switch message {
        case let .transferRequest(direction, _, _, _): return direction == .upload
        case .uploadDenied, .uploadFailed, .placeInQueueResponse: return true
        default: return false
        }
    }

    private func handlePeerMessage(from username: String, _ message: PeerMessage) {
        switch message {
        case let .fileSearchResponse(response):
            guard activeSearches.contains(response.token) else { return }
            emit(.searchResponse(response))

        case let .transferRequest(direction, token, filename, size):
            if direction == .upload {
                acceptIncomingTransfer(from: username, token: token, filename: filename, size: size)
            } else {
                // Legacy download request (slskd, Seeker). Nicotine+ answers "Queued" and queues it.
                sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Queued", size: nil)])
                enqueueUpload(for: username, path: filename)
            }

        case let .transferResponse(token, allowed, reason, _):
            handleUploadResponse(from: username, token: token, allowed: allowed, reason: reason)

        case let .queueUpload(filename):
            enqueueUpload(for: username, path: filename)

        case let .placeInQueueResponse(filename, place):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            switch record.state {
            case .requesting, .queued:
                downloads[id]?.state = .queued(place: place)
                emitDownload(id)
            default:
                break
            }

        case let .uploadDenied(filename, reason):
            let id = DownloadID(username: username, path: filename)
            guard downloads[id] != nil else { return }
            downloads[id]?.state = .failed(reason.isEmpty ? "Denied by peer" : reason)
            emitDownload(id)

        case let .uploadFailed(filename):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            if case .completed = record.state { return }
            if record.retries < 2 {
                downloads[id]?.retries += 1
                downloads[id]?.state = .requesting
                emitDownload(id)
                requestQueuePlace(id)
            } else {
                downloads[id]?.state = .failed("Upload failed on \(username)'s side")
                emitDownload(id)
            }

        case .sharedFileListRequest:
            // Packing the whole list is the most work a peer can ask of us: once per 20 s each.
            let now = Date()
            if let last = lastShareListReply[username], now.timeIntervalSince(last) < 20 { return }
            if lastShareListReply.count > 500 {
                lastShareListReply = lastShareListReply.filter { now.timeIntervalSince($0.value) < 20 }
            }
            lastShareListReply[username] = now
            sendToPeer(username, [.sharedFileListResponse(folders: sharedFolders())])

        case .userInfoRequest:
            sendToPeer(username, [.userInfoResponse(description: "colon3 (iOS)",
                                                    totalUploads: completedUploads,
                                                    queueSize: UInt32(uploadQueue.count),
                                                    slotsFree: activeUpload == nil && sharingAllowed)])

        case let .placeInQueueRequest(filename):
            if let index = uploadQueue.firstIndex(where: { $0.username == username && $0.path == filename }) {
                sendToPeer(username, [.placeInQueueResponse(filename: filename, place: UInt32(index + 1))])
            }

        case let .folderContentsRequest(token, folder):
            let folders = sharedFolders().filter { $0.name == folder || $0.name.hasPrefix(folder + "\\") }
            sendToPeer(username, [.folderContentsResponse(token: token, folder: folder, folders: folders)])

        case let .folderContentsResponse(token, _, folders):
            guard let browse = folderBrowses[token], browse.username == username else { return }
            let files = folders.flatMap { entry in
                entry.files.map { file in
                    var full = file
                    full.path = entry.name.isEmpty ? file.path : entry.name + "\\" + file.path
                    return full
                }
            }
            finishBrowse(token: token, files: files)

        case .sharedFileListResponse, .userInfoResponse, .unknown:
            break
        }
    }

    // MARK: - Downloads

    private func requestQueuePlace(_ id: DownloadID) {
        sendToPeer(id.username, [.queueUpload(filename: id.path), .placeInQueueRequest(filename: id.path)],
                   onSent: { [weak self] in
                       guard let self, self.downloads[id]?.state == .requesting else { return }
                       self.downloads[id]?.state = .queued(place: nil)
                       self.emitDownload(id)
                   },
                   onFailure: { [weak self] in
                       guard let self, self.downloads[id]?.state == .requesting else { return }
                       self.downloads[id]?.state = .failed("Couldn't connect to \(id.username)")
                       self.emitDownload(id)
                   })
    }

    private func acceptIncomingTransfer(from username: String, token: UInt32, filename: String, size: UInt64?) {
        let id = DownloadID(username: username, path: filename)
        guard var record = downloads[id] else {
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        }
        switch record.state {
        case .completed, .transferring:
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        default:
            break
        }

        if let size { record.size = size }
        if let oldToken = record.token { downloadsByToken[tokenKey(username, oldToken)] = nil }
        record.token = token
        record.state = .starting
        downloads[id] = record
        downloadsByToken[tokenKey(username, token)] = id
        sendToPeer(username, [.transferResponse(token: token, allowed: true, reason: nil, size: nil)])
        emitDownload(id)

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let current = self.downloads[id], current.token == token, current.state == .starting else { return }
            self.downloads[id]?.state = .failed("\(username) never opened the file connection")
            self.emitDownload(id)
        }
    }

    private func openPiercedFile(username: String, ip: String, port: UInt32, token: UInt32) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: Self.tcpParameters(timeout: 8))
        let link = FileLink(username: username, connection: connection, role: .awaitingToken)
        fileLinks[ObjectIdentifier(link)] = link

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .ready:
                connection.send(content: PeerInitMessage.pierceFirewall(token: token).frame,
                                completion: .contentProcessed { _ in })
                self.receive(on: connection, onData: { [weak self, weak link] data in
                    guard let self, let link else { return }
                    self.handleFileData(link, data)
                }, onClose: { [weak self, weak link] _ in
                    guard let self, let link else { return }
                    self.closeFile(link, reason: "Connection closed early")
                })
            case .waiting, .failed:
                self.sendServer(.cantConnectToPeer(token: token, username: username))
                self.closeFile(link, reason: "Couldn't open file connection")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleFileData(_ link: FileLink, _ data: Data) {
        switch link.role {
        case .awaitingToken:
            link.pending.append(data)
            guard link.pending.count >= 4 else { return }
            var reader = ByteReader(link.pending)
            guard let token = try? reader.u32() else { return }
            let leftover = reader.rest()
            link.pending = Data()
            beginReceivingFile(link, token: token, leftover: leftover)

        case let .downloading(id):
            writeChunk(data, link: link, id: id)

        case .uploading:
            handleUploadOffset(link, data)
        }
    }

    private func beginReceivingFile(_ link: FileLink, token: UInt32, leftover: Data) {
        guard let id = downloadsByToken[tokenKey(link.username, token)], var record = downloads[id] else {
            log("Unexpected file connection from \(link.username)")
            closeFile(link, reason: nil)
            return
        }

        let partial = partialURL(for: id)
        var offset: UInt64 = 0
        do {
            try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            offset = try handle.seekToEnd()
            if offset > record.size {
                try handle.truncate(atOffset: 0)
                offset = 0
            }
            link.handle = handle
        } catch {
            record.state = .failed("Can't write file: \(error.localizedDescription)")
            downloads[id] = record
            emitDownload(id)
            closeFile(link, reason: nil)
            return
        }

        record.received = offset
        record.state = .transferring
        downloads[id] = record
        link.role = .downloading(id)

        var writer = ByteWriter()
        writer.u64(offset)
        link.connection.send(content: writer.data, completion: .contentProcessed { _ in })
        emitDownload(id)

        if record.received >= record.size {
            finishDownload(link, id: id)
        } else if !leftover.isEmpty {
            writeChunk(leftover, link: link, id: id)
        }
    }

    private func writeChunk(_ data: Data, link: FileLink, id: DownloadID) {
        guard let handle = link.handle, downloads[id] != nil else {
            closeFile(link, reason: nil)
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            downloads[id]?.state = .failed("Write failed: \(error.localizedDescription)")
            emitDownload(id)
            closeFile(link, reason: nil)
            return
        }
        downloads[id]?.received += UInt64(data.count)
        guard let record = downloads[id] else { return }

        if record.received >= record.size {
            finishDownload(link, id: id)
        } else if Date().timeIntervalSince(link.lastProgress) > 0.3 {
            link.lastProgress = Date()
            emitDownload(id)
        }
    }

    private func finishDownload(_ link: FileLink, id: DownloadID) {
        try? link.handle?.close()
        link.handle = nil
        // The downloader closes the connection to signal completion.
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        fileLinks[ObjectIdentifier(link)] = nil

        if let token = downloads[id]?.token { downloadsByToken[tokenKey(id.username, token)] = nil }
        do {
            let destination = try moveToLibrary(partialURL(for: id), id: id)
            downloads[id]?.state = .completed(destination)
            log("Finished \(destination.lastPathComponent)")
        } catch {
            downloads[id]?.state = .failed("Couldn't save file: \(error.localizedDescription)")
        }
        emitDownload(id)
    }

    private func closeFile(_ link: FileLink, reason: String?) {
        guard !link.isClosed else { return }
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        try? link.handle?.close()
        link.handle = nil
        fileLinks[ObjectIdentifier(link)] = nil

        switch link.role {
        case let .downloading(id):
            guard let record = downloads[id], record.state == .transferring else { return }
            let percent = record.size > 0 ? Int(Double(record.received) / Double(record.size) * 100) : 0
            downloads[id]?.state = .failed("\(reason ?? "Interrupted") at \(percent)%")
            emitDownload(id)
        case let .uploading(token):
            finishUpload(token: token, succeeded: link.uploadDone)
        case .awaitingToken:
            break
        }
    }

    private func partialURL(for id: DownloadID) -> URL {
        incompleteDirectory.appendingPathComponent(MD5.hex(id.username + "\n" + id.path) + ".part")
    }

    private func moveToLibrary(_ source: URL, id: DownloadID) throws -> URL {
        let file = SharedFile(path: id.path, size: 0)
        let folder = downloads[id]?.folderName.map(Self.sanitize)
            ?? Self.libraryFolderName(forRemoteFolder: file.folderName.isEmpty ? id.username : file.folderName)
        let directory = downloadDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = Self.sanitize(file.filename)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            destination = directory.appendingPathComponent(candidate)
            counter += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// The library folder a download from this remote folder lands in.
    public static func libraryFolderName(forRemoteFolder name: String) -> String {
        sanitize(name)
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\0".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "_" + result : result
    }

    // MARK: - Uploads (so we're not a pure leecher)

    private func enqueueUpload(for username: String, path: String) {
        guard let share = shares[path] else {
            sendToPeer(username, [.uploadDenied(filename: path, reason: "File not shared.")])
            return
        }
        if activeUpload?.username == username && activeUpload?.path == path { return }
        if uploadQueue.contains(where: { $0.username == username && $0.path == path }) { return }
        let fromUser = uploadQueue.lazy.filter { $0.username == username }.count
        guard fromUser < Incoming.maxQueuedPerUser, uploadQueue.count < Incoming.maxQueuedTotal else {
            sendToPeer(username, [.uploadDenied(filename: path, reason: "Too many files")])
            return
        }
        uploadQueue.append(UploadJob(username: username, path: path, share: share))
        emitUpload(username: username, path: path, state: .queued, sent: 0, size: share.size)
        startNextUpload()
    }

    private func startNextUpload() {
        guard activeUpload == nil, isLoggedIn, sharingAllowed, !uploadQueue.isEmpty else { return }
        var job = uploadQueue.removeFirst()
        job.token = UInt32.random(in: 1..<UInt32.max)
        activeUpload = job
        let token = job.token

        sendToPeer(job.username, [.transferRequest(direction: .upload, token: token, filename: job.path, size: job.share.size)],
                   onFailure: { [weak self] in self?.finishUpload(token: token, succeeded: false) })

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let active = self.activeUpload, active.token == token, !active.started else { return }
            self.finishUpload(token: token, succeeded: false)
        }
    }

    private func handleUploadResponse(from username: String, token: UInt32, allowed: Bool, reason: String?) {
        guard let job = activeUpload, job.token == token, job.username == username, !job.started else { return }
        guard allowed else {
            log("\(username) declined upload: \(reason ?? "no reason")")
            finishUpload(token: token, succeeded: false)
            return
        }
        activeUpload?.started = true

        resolveAddress(username) { [weak self] address in
            guard let self, self.activeUpload?.token == token, self.uploadAttempts[token] == nil else { return }
            guard let address else {
                self.finishUpload(token: token, succeeded: false)
                return
            }
            // Connect to them directly and, at the same time, ask them through the server to
            // connect to us; the first file connection that comes up is used.
            let attempt = UploadAttempt(token: token, username: username)
            self.uploadAttempts[token] = attempt
            if address.port > 0, address.port <= 65535, let port = NWEndpoint.Port(rawValue: UInt16(address.port)) {
                let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 8))
                attempt.direct = connection
                connection.stateUpdateHandler = { [weak self, weak attempt] state in
                    guard let self, let attempt, attempt.direct === connection, !attempt.claimed else { return }
                    switch state {
                    case .ready:
                        self.claimUpload(attempt, connection: connection, sendPeerInit: true)
                    case .waiting, .failed:
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        attempt.direct = nil
                        attempt.directFailed = true
                        self.uploadAttemptMaybeFailed(attempt)
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            } else {
                attempt.directFailed = true
            }
            if self.listenerReady {
                attempt.indirectToken = self.requestIndirect(.upload(token), username: username, type: .file)
            }
            self.uploadAttemptMaybeFailed(attempt)
        }
    }

    /// The file connection for an upload is up (ours, or theirs answering our request).
    private func claimUpload(_ attempt: UploadAttempt, connection: NWConnection, sendPeerInit: Bool, leftover: Data = Data()) {
        attempt.claimed = true
        if let direct = attempt.direct, direct !== connection {
            direct.stateUpdateHandler = nil
            direct.cancel()
        }
        attempt.direct = nil
        if let indirect = attempt.indirectToken {
            indirectRequests[indirect] = nil
            attempt.indirectToken = nil
        }

        let link = FileLink(username: attempt.username, connection: connection, role: .uploading(attempt.token))
        fileLinks[ObjectIdentifier(link)] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .waiting, .failed: self.closeFile(link, reason: nil)
            default: break
            }
        }
        var writer = ByteWriter()
        if sendPeerInit { writer.raw(PeerInitMessage.peerInit(username: username, type: "F").frame) }
        writer.u32(attempt.token)  // FileTransferInit
        connection.send(content: writer.data, completion: .contentProcessed { _ in })
        if !leftover.isEmpty { handleFileData(link, leftover) }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handleFileData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closeFile(link, reason: nil)
        })
    }

    /// Gives up on an upload once neither connection can come up.
    private func uploadAttemptMaybeFailed(_ attempt: UploadAttempt) {
        guard !attempt.claimed, attempt.directFailed, attempt.indirectToken == nil,
              uploadAttempts[attempt.token] === attempt else { return }
        uploadAttempts[attempt.token] = nil
        finishUpload(token: attempt.token, succeeded: false)
    }

    private func handleUploadOffset(_ link: FileLink, _ data: Data) {
        guard link.handle == nil, !link.uploadDone else { return }
        link.pending.append(data)
        guard link.pending.count >= 8 else { return }
        var reader = ByteReader(link.pending)
        guard let offset = try? reader.u64(), let job = activeUpload else { return }
        link.pending = Data()

        do {
            let handle = try FileHandle(forReadingFrom: job.share.url)
            let start = min(offset, job.share.size)
            try handle.seek(toOffset: start)
            link.handle = handle
            link.sentBytes = start
        } catch {
            closeFile(link, reason: nil)
            return
        }
        emitUpload(username: job.username, path: job.path, state: .transferring, sent: link.sentBytes, size: job.share.size)
        sendNextUploadChunk(link)
    }

    private func sendNextUploadChunk(_ link: FileLink) {
        guard !link.isClosed, let handle = link.handle else { return }
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        } catch {
            closeFile(link, reason: nil)
            return
        }
        if chunk.isEmpty {
            // Everything sent. The downloader closes the connection when it has it all.
            link.uploadDone = true
            try? handle.close()
            link.handle = nil
            return
        }
        link.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            if error != nil {
                self.closeFile(link, reason: nil)
            } else {
                link.sentBytes += UInt64(chunk.count)
                if Date().timeIntervalSince(link.lastProgress) > 0.5, let job = self.activeUpload {
                    link.lastProgress = Date()
                    self.emitUpload(username: job.username, path: job.path, state: .transferring,
                                    sent: link.sentBytes, size: job.share.size)
                }
                self.sendNextUploadChunk(link)
            }
        })
    }

    private func finishUpload(token: UInt32, succeeded: Bool) {
        guard let job = activeUpload, job.token == token else { return }
        if let attempt = uploadAttempts.removeValue(forKey: token) {
            attempt.direct?.stateUpdateHandler = nil
            attempt.direct?.cancel()
            attempt.direct = nil
            if let indirect = attempt.indirectToken { indirectRequests[indirect] = nil }
            attempt.indirectToken = nil
        }
        emitUpload(username: job.username, path: job.path, state: succeeded ? .completed : .failed,
                   sent: succeeded ? job.share.size : 0, size: job.share.size)
        if succeeded {
            completedUploads += 1
            log("Uploaded \(job.path) to \(job.username)")
        } else if job.started && isLoggedIn {
            sendToPeer(job.username, [.uploadFailed(filename: job.path)])
        }
        activeUpload = nil
        startNextUpload()
    }

    private func sharedFolders() -> [SharedFolder] {
        var grouped: [String: [SharedFile]] = [:]
        for share in shares.values {
            let parts = Self.splitVirtualPath(share.virtualPath)
            grouped[parts.folder, default: []].append(SharedFile(path: parts.name, size: share.size))
        }
        return grouped.keys.sorted().map { SharedFolder(name: $0, files: grouped[$0] ?? []) }
    }

    private static func splitVirtualPath(_ path: String) -> (folder: String, name: String) {
        guard let separator = path.lastIndex(of: "\\") else { return ("", path) }
        return (String(path[..<separator]), String(path[path.index(after: separator)...]))
    }

    // MARK: - Incoming connections

    private func startListener() {
        guard listener == nil else { return }
        guard listenPort != 0, let port = NWEndpoint.Port(rawValue: listenPort) else {
            emit(.listener(.off))
            return
        }
        let parameters = Self.tcpParameters(timeout: 8)
        parameters.allowLocalEndpointReuse = true
        // Soulseek peers use IPv4, and the router only forwards IPv4: don't accept IPv6.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: port)
        } catch {
            emit(.listener(.failed("Can't listen on port \(listenPort): \(error.localizedDescription)")))
            scheduleListenerRestart()
            return
        }
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self, self.listener === newListener else {
                connection.cancel()
                return
            }
            self.acceptIncoming(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listener === newListener else { return }
            switch state {
            case .ready:
                self.listenerReady = true
                self.log("Listening for peers on port \(self.listenPort)")
                self.lastListenerEmit = .distantPast
                self.emitListenerStatus()
            case let .waiting(error):
                self.listenerReady = false
                self.emit(.listener(.failed("Waiting for the network (\(error.localizedDescription))")))
            case let .failed(error):
                // Also happens after iOS suspended the app for a while; start again shortly.
                self.listenerReady = false
                self.emit(.listener(.failed(self.describeListenerError(error))))
                newListener.stateUpdateHandler = nil
                newListener.newConnectionHandler = nil
                newListener.cancel()
                self.listener = nil
                self.scheduleListenerRestart()
            default:
                break
            }
        }
        newListener.start(queue: queue)
    }

    private func stopListener() {
        listenerReady = false
        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        for pending in Array(pendingIncoming.values) { dropPending(pending) }
        pendingLimiter.reset()
        for link in Array(incomingLinks.values) { closePeer(link, failed: false) }
    }

    private func scheduleListenerRestart() {
        guard !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            if self.isLoggedIn, self.listener == nil { self.startListener() }
        }
    }

    private func describeListenerError(_ error: NWError) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "Port \(listenPort) is in use by another app"
        }
        return "Can't listen on port \(listenPort): \(error.localizedDescription)"
    }

    /// At most once a second, so a burst of connections doesn't flood the app with updates.
    private func emitListenerStatus() {
        guard listenerReady else { return }
        let wait = 1 - Date().timeIntervalSince(lastListenerEmit)
        if wait <= 0 {
            lastListenerEmit = Date()
            emit(.listener(.listening(port: listenPort, accepted: acceptedConnections)))
        } else if !listenerEmitScheduled {
            listenerEmitScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.listenerEmitScheduled = false
                self.emitListenerStatus()
            }
        }
    }

    /// A new connection to our port. It gets a few seconds to say who it is (PeerInit or
    /// PierceFireWall) and only a small first message; too many at once are turned away.
    private func acceptIncoming(_ connection: NWConnection) {
        let address = Self.remoteAddress(of: connection)
        guard pendingLimiter.admit(address) else {
            connection.cancel()
            return
        }
        let pending = PendingConnection(connection: connection, address: address)
        pendingIncoming[ObjectIdentifier(pending)] = pending
        connection.stateUpdateHandler = { [weak self, weak pending] state in
            guard let self, let pending else { return }
            switch state {
            case .failed, .cancelled: self.dropPending(pending)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveInit(pending)
        queue.asyncAfter(deadline: .now() + Incoming.initTimeout) { [weak self, weak pending] in
            guard let self, let pending else { return }
            self.dropPending(pending)
        }
    }

    private func receiveInit(_ pending: PendingConnection) {
        pending.connection.receive(minimumIncompleteLength: 1, maximumLength: Incoming.initFrameLimit + 4) {
            [weak self, weak pending] data, _, isComplete, error in
            guard let self, let pending, self.pendingIncoming[ObjectIdentifier(pending)] != nil else { return }
            if let data, !data.isEmpty { pending.frames.append(data) }
            let body: Data?
            do {
                body = try pending.frames.nextFrame()
            } catch {
                self.dropPending(pending)
                return
            }
            if let body {
                self.handleInit(pending, body: body)
            } else if isComplete || error != nil {
                self.dropPending(pending)
            } else {
                self.receiveInit(pending)
            }
        }
    }

    /// Closes a connection that never said who it is.
    private func dropPending(_ pending: PendingConnection) {
        guard pendingIncoming.removeValue(forKey: ObjectIdentifier(pending)) != nil else { return }
        pendingLimiter.release(pending.address)
        pending.connection.stateUpdateHandler = nil
        pending.connection.cancel()
    }

    /// Takes a connection off the unidentified list so it can be handed to its new role.
    private func promotePending(_ pending: PendingConnection) -> Bool {
        guard pendingIncoming.removeValue(forKey: ObjectIdentifier(pending)) != nil else { return false }
        pendingLimiter.release(pending.address)
        pending.connection.stateUpdateHandler = nil
        return true
    }

    private func handleInit(_ pending: PendingConnection, body: Data) {
        guard let message = try? PeerInitMessage.decode(body) else {
            dropPending(pending)
            return
        }
        let leftover = pending.frames.drain()
        switch message {
        case let .pierceFirewall(token):
            // A peer answering one of our ConnectToPeer requests; the token says which.
            guard let request = indirectRequests.removeValue(forKey: token), promotePending(pending) else {
                dropPending(pending)
                return
            }
            countAccepted()
            switch request.target {
            case let .peer(link):
                adoptPiercedPeer(link, token: token, connection: pending.connection, leftover: leftover)
            case let .upload(transferToken):
                adoptPiercedUpload(transferToken, indirectToken: token, username: request.username,
                                   connection: pending.connection, leftover: leftover)
            }

        case let .peerInit(username, type):
            guard Self.isPlausibleUsername(username) else {
                dropPending(pending)
                return
            }
            switch type {
            case ConnectionType.peer.rawValue:
                guard incomingLinks.count < Incoming.maxPeerLinks, promotePending(pending) else {
                    dropPending(pending)
                    return
                }
                countAccepted()
                acceptIncomingPeer(username: username, connection: pending.connection, address: pending.address, leftover: leftover)
            case ConnectionType.file.rawValue:
                guard fileLinks.count < Incoming.maxFileLinks, promotePending(pending) else {
                    dropPending(pending)
                    return
                }
                countAccepted()
                acceptIncomingFile(username: username, connection: pending.connection, leftover: leftover)
            default:
                // Distributed search connections: we don't take part in that network.
                dropPending(pending)
            }
        }
    }

    private func countAccepted() {
        acceptedConnections += 1
        emitListenerStatus()
    }

    /// A peer opened a P connection to us directly. They can claim any username, so it starts out
    /// untrusted (see `routePeerMessage`) unless we've already confirmed them at this address.
    private func acceptIncomingPeer(username: String, connection: NWConnection, address: String, leftover: Data) {
        let link = PeerLink(username: username)
        link.connection = connection
        link.incoming = true
        link.address = address
        link.frames = FrameBuffer(limit: Incoming.peerFrameLimit)
        if let confirmed = verifiedPeers[username + "|" + address], Date().timeIntervalSince(confirmed) < Incoming.verifiedFor {
            link.trusted = true
        } else {
            link.trusted = false
        }
        link.isReady = true
        link.lastActivity = Date()
        incomingLinks[ObjectIdentifier(link)] = link
        if link.trusted, peers[username] == nil { peers[username] = link }
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            if case .failed = state { self.closePeer(link, failed: false) }
        }
        scheduleIdleSweep()
        if !leftover.isEmpty { handlePeerData(link, leftover) }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handlePeerData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closePeer(link, failed: false)
        })
    }

    /// The peer connected to us for a P connection we asked for. Our own attempt (if still
    /// trying) is dropped, and queued messages go out over this one.
    private func adoptPiercedPeer(_ link: PeerLink, token: UInt32, connection: NWConnection, leftover: Data) {
        guard !link.isClosed, !link.isReady, link.indirectToken == token else {
            connection.cancel()
            return
        }
        link.indirectToken = nil
        if let direct = link.connection, direct !== connection {
            direct.stateUpdateHandler = nil
            direct.cancel()
        }
        link.connection = connection
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            if case .failed = state { self.closePeer(link, failed: false) }
        }
        activatePeerLink(link, connection: connection, firstFrame: nil, leftover: leftover)
    }

    /// The downloader connected to us for the file connection of our upload.
    private func adoptPiercedUpload(_ transferToken: UInt32, indirectToken: UInt32, username: String,
                                    connection: NWConnection, leftover: Data) {
        guard let attempt = uploadAttempts[transferToken], !attempt.claimed, attempt.indirectToken == indirectToken,
              attempt.username == username, activeUpload?.token == transferToken else {
            connection.cancel()
            return
        }
        attempt.indirectToken = nil
        claimUpload(attempt, connection: connection, sendPeerInit: false, leftover: leftover)
    }

    /// A peer opened a file connection to us to send a file we're downloading. The transfer token
    /// they send next must match one we agreed to with that user, or it's closed.
    private func acceptIncomingFile(username: String, connection: NWConnection, leftover: Data) {
        let link = FileLink(username: username, connection: connection, role: .awaitingToken)
        fileLinks[ObjectIdentifier(link)] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            if case .failed = state { self.closeFile(link, reason: "Connection lost") }
        }
        queue.asyncAfter(deadline: .now() + Incoming.initTimeout) { [weak self, weak link] in
            guard let self, let link, !link.isClosed, case .awaitingToken = link.role else { return }
            self.closeFile(link, reason: nil)
        }
        if !leftover.isEmpty { handleFileData(link, leftover) }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handleFileData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closeFile(link, reason: "Connection closed early")
        })
    }

    /// Asks the server to have `username` connect to us. Gives up after a while, or as soon as the
    /// server says they couldn't.
    private func requestIndirect(_ target: IndirectTarget, username: String, type: ConnectionType) -> UInt32 {
        var token = UInt32.random(in: 1..<UInt32.max)
        while indirectRequests[token] != nil { token = UInt32.random(in: 1..<UInt32.max) }
        indirectRequests[token] = IndirectRequest(target: target, username: username)
        sendServer(.connectToPeer(token: token, username: username, type: type))
        queue.asyncAfter(deadline: .now() + Incoming.indirectTimeout) { [weak self] in
            self?.indirectFailed(token: token)
        }
        return token
    }

    private func indirectFailed(token: UInt32) {
        guard let request = indirectRequests.removeValue(forKey: token) else { return }
        switch request.target {
        case let .peer(link):
            guard link.indirectToken == token else { return }
            link.indirectToken = nil
            if link.directFailed, !link.isReady { closePeer(link, failed: true) }
        case let .upload(transferToken):
            guard let attempt = uploadAttempts[transferToken], attempt.indirectToken == token else { return }
            attempt.indirectToken = nil
            uploadAttemptMaybeFailed(attempt)
        }
    }

    /// Asks the server where this user is; if it's the address the connection came from, the
    /// held messages are handled and the connection is trusted from then on.
    private func verify(_ link: PeerLink) {
        guard !link.verifying, let address = link.address else { return }
        link.verifying = true
        resolveAddress(link.username) { [weak self, weak link] _ in
            guard let self, let link, !link.isClosed else { return }
            link.verifying = false
            let held = link.held
            link.held.removeAll()
            // Compare the IP alone: the server reports port 0 for some reachable peers.
            guard self.lastKnownIPs[link.username] == address else {
                self.log("Ignored transfer messages from someone claiming to be \(link.username) (\(address))")
                return
            }
            link.trusted = true
            if self.verifiedPeers.count > 500 {
                let now = Date()
                self.verifiedPeers = self.verifiedPeers.filter { now.timeIntervalSince($0.value) < Incoming.verifiedFor }
            }
            self.verifiedPeers[link.username + "|" + address] = Date()
            if self.peers[link.username] == nil { self.peers[link.username] = link }
            for message in held where !link.isClosed { self.routePeerMessage(link, message) }
        }
    }

    /// Closes connections peers opened to us that have gone quiet.
    private func scheduleIdleSweep() {
        guard !idleSweepScheduled else { return }
        idleSweepScheduled = true
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            self.idleSweepScheduled = false
            let now = Date()
            for link in Array(self.incomingLinks.values)
            where now.timeIntervalSince(link.lastActivity) > Incoming.idleTimeout && !link.verifying {
                self.closePeer(link, failed: false)
            }
            if !self.incomingLinks.isEmpty { self.scheduleIdleSweep() }
        }
    }

    private func incomingBufferedBytes() -> Int {
        incomingLinks.values.reduce(0) { $0 + $1.frames.bufferedCount }
    }

    private static func isPlausibleUsername(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func remoteAddress(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "unknown" }
        var text: String
        switch host {
        case let .ipv4(address): text = "\(address)"
        case let .ipv6(address): text = "\(address)"
        case let .name(name, _): text = name
        @unknown default: text = "unknown"
        }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        return text
    }

    // MARK: - Helpers

    private func receive(on connection: NWConnection, onData: @escaping (Data) -> Void, onClose: @escaping (NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { onData(data) }
            if isComplete || error != nil {
                onClose(error)
                return
            }
            self?.receive(on: connection, onData: onData, onClose: onClose)
        }
    }

    private static func tcpParameters(timeout: Int) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = timeout
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func tokenKey(_ username: String, _ token: UInt32) -> String { "\(username)|\(token)" }

    private func emitUpload(username: String, path: String, state: UploadState, sent: UInt64, size: UInt64) {
        emit(.upload(UploadUpdate(id: DownloadID(username: username, path: path), state: state, sent: sent, size: size)))
    }

    private func emitDownload(_ id: DownloadID) {
        guard let record = downloads[id] else { return }
        emit(.download(DownloadUpdate(id: id, state: record.state, received: record.received, size: record.size)))
    }

    private func log(_ message: String) { emit(.log(message)) }

    private func emit(_ event: ClientEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

// MARK: - Internal state

private struct PeerAddress {
    let ip: String
    let port: UInt32
}

private final class PeerLink {
    let username: String
    var connection: NWConnection?
    var frames = FrameBuffer()
    var isReady = false
    var isClosed = false
    var outbox: [Data] = []
    var sentHandlers: [() -> Void] = []
    var failureHandlers: [() -> Void] = []
    /// Opened by the peer rather than by us.
    var incoming = false
    /// False for a direct connection from someone the server hasn't confirmed yet.
    var trusted = true
    /// The remote IP, for connections peers opened to us.
    var address: String?
    var directFailed = false
    /// Our pending ConnectToPeer request for this connection.
    var indirectToken: UInt32?
    var lastActivity = Date()
    var verifying = false
    /// Messages waiting for `verify`.
    var held: [PeerMessage] = []

    init(username: String) {
        self.username = username
    }
}

private final class FileLink {
    enum Role {
        case awaitingToken
        case downloading(DownloadID)
        case uploading(UInt32)
    }

    let username: String
    let connection: NWConnection
    var role: Role
    var pending = Data()
    var handle: FileHandle?
    var isClosed = false
    var uploadDone = false
    var sentBytes: UInt64 = 0
    var lastProgress = Date.distantPast

    init(username: String, connection: NWConnection, role: Role) {
        self.username = username
        self.connection = connection
        self.role = role
    }
}

private struct DownloadRecord {
    let id: DownloadID
    var state: DownloadState
    var size: UInt64
    var received: UInt64 = 0
    var token: UInt32?
    var retries = 0
    var folderName: String?
}

private struct FolderBrowse {
    let username: String
    let folder: String
    let completion: ([SharedFile]?) -> Void
}

/// Limits for connections peers open to us.
private enum Incoming {
    static let maxPending = 24
    static let maxPendingPerAddress = 4
    static let initTimeout: TimeInterval = 10
    static let initFrameLimit = 4096
    static let maxPeerLinks = 64
    static let maxFileLinks = 24
    static let peerFrameLimit = 16 * 1024 * 1024
    static let inflateLimit = 32 * 1024 * 1024
    static let bufferedBudget = 48 * 1024 * 1024
    static let idleTimeout: TimeInterval = 300
    static let indirectTimeout: TimeInterval = 20
    static let maxQueuedPerUser = 200
    static let maxQueuedTotal = 2000
    static let verifiedFor: TimeInterval = 600
    static let maxHeldMessages = 32
}

private final class PendingConnection {
    let connection: NWConnection
    let address: String
    var frames = FrameBuffer(limit: Incoming.initFrameLimit)

    init(connection: NWConnection, address: String) {
        self.connection = connection
        self.address = address
    }
}

private enum IndirectTarget {
    case peer(PeerLink)
    /// Our upload's file connection, by transfer token.
    case upload(UInt32)
}

private struct IndirectRequest {
    let target: IndirectTarget
    let username: String
}

private final class UploadAttempt {
    let token: UInt32
    let username: String
    var direct: NWConnection?
    var directFailed = false
    var indirectToken: UInt32?
    var claimed = false

    init(token: UInt32, username: String) {
        self.token = token
        self.username = username
    }
}

private struct UploadJob {
    let username: String
    let path: String
    let share: LocalShare
    var token: UInt32 = 0
    var started = false
}
#endif
