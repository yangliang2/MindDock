import Foundation
import Speech

public struct LifeDockPushBerth: Codable, Sendable, Equatable {
    public let slotNumber: Int
    public let id: String
    public let raw: String
    public let prep: String?

    public init(slotNumber: Int, id: String, raw: String, prep: String?) {
        self.slotNumber = slotNumber
        self.id = id
        self.raw = raw
        self.prep = prep
    }
}

public struct LifeDockPushPayload: Codable, Sendable, Equatable {
    public let berths: [LifeDockPushBerth]
    public let queuedCount: Int
    public let fingerprint: String

    public init(berths: [LifeDockPushBerth], queuedCount: Int, fingerprint: String) {
        self.berths = berths
        self.queuedCount = queuedCount
        self.fingerprint = fingerprint
    }
}

public enum InboundMessageKind: String, Codable, Sendable, Equatable {
    case text
    case audio
}

public enum InboundSenderRole: String, Codable, Sendable, Equatable {
    case user
    case bot
}

public struct InboundMobileMessage: Codable, Sendable, Equatable {
    public let messageId: String
    public let senderRole: InboundSenderRole
    public let kind: InboundMessageKind
    public let text: String
    public let audioData: Data?
    public let audioFileExtension: String?
    public let createdAtTimestamp: String

    public init(
        messageId: String,
        senderRole: InboundSenderRole,
        kind: InboundMessageKind,
        text: String,
        audioData: Data? = nil,
        audioFileExtension: String? = nil,
        createdAtTimestamp: String
    ) {
        self.messageId = messageId
        self.senderRole = senderRole
        self.kind = kind
        self.text = text
        self.audioData = audioData
        self.audioFileExtension = audioFileExtension
        self.createdAtTimestamp = createdAtTimestamp
    }
}

public struct InboundMessageBatch: Codable, Sendable, Equatable {
    public let messages: [InboundMobileMessage]
    public let nextCursor: String?

    public init(messages: [InboundMobileMessage], nextCursor: String?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public protocol AudioTranscriber: Sendable {
    func transcribe(audioData: Data, fileExtension: String) async throws -> String
}

public protocol MobileBridgeClient: Sendable {
    func pushLifeDock(_ payload: LifeDockPushPayload) async throws
    func pullMessages(sinceCursor: String?) async throws -> InboundMessageBatch
}

public struct MobileSyncReport: Sendable, Equatable {
    public let resolvedItems: [ResolveResult]
    public let droppedItems: [DockItem]
    public let advancedCursor: String?

    public init(
        resolvedItems: [ResolveResult] = [],
        droppedItems: [DockItem] = [],
        advancedCursor: String? = nil
    ) {
        self.resolvedItems = resolvedItems
        self.droppedItems = droppedItems
        self.advancedCursor = advancedCursor
    }
}

public struct ShiftSyncResult: Sendable, Equatable {
    public let snapshot: DockSnapshot
    public let pushedLifeDock: Bool
    public let syncReport: MobileSyncReport?

    public init(snapshot: DockSnapshot, pushedLifeDock: Bool, syncReport: MobileSyncReport? = nil) {
        self.snapshot = snapshot
        self.pushedLifeDock = pushedLifeDock
        self.syncReport = syncReport
    }
}

public struct MobilePushTestResult: Sendable, Equatable {
    public let pushedBerthCount: Int
    public let usedSamplePreview: Bool

    public init(pushedBerthCount: Int, usedSamplePreview: Bool) {
        self.pushedBerthCount = pushedBerthCount
        self.usedSamplePreview = usedSamplePreview
    }
}

public enum MobileBridgeError: Error, LocalizedError, Sendable, Equatable {
    case unconfigured
    case invalidResponse(String)
    case httpStatus(Int, String)
    case remoteError(Int, String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "Mobile bridge is not configured yet. Enter a Feishu App ID + Secret (with Chat ID) or a Webhook URL."
        case .invalidResponse(let detail):
            return "Invalid response from mobile bridge: \(detail)"
        case .httpStatus(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(String(trimmed.prefix(200)))"
        case .remoteError(let code, let msg):
            return "Remote error (\(code)): \(msg)"
        case .transcriptionFailed(let msg):
            return "Audio transcription failed: \(msg)"
        }
    }
}

public struct MobileBridgeConfig: Codable, Sendable, Equatable {
    public var webhookURL: URL?
    public var appId: String?
    public var appSecret: String?
    public var chatId: String?
    public var receiveIdType: String
    public var apiBaseURL: URL
    public var pushPlusToken: String?

    public init(
        webhookURL: URL? = nil,
        appId: String? = nil,
        appSecret: String? = nil,
        chatId: String? = nil,
        receiveIdType: String = "chat_id",
        apiBaseURL: URL = URL(string: "https://open.feishu.cn")!,
        pushPlusToken: String? = nil
    ) {
        self.webhookURL = webhookURL
        self.appId = appId
        self.appSecret = appSecret
        self.chatId = chatId
        self.receiveIdType = receiveIdType
        self.apiBaseURL = apiBaseURL
        self.pushPlusToken = pushPlusToken
    }

    public var hasAppBotCredentials: Bool {
        guard let appId, !appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let appSecret, !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> MobileBridgeConfig? {
        func read(_ envKey: String, _ defaultsKey: String) -> String? {
            if let v = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
            if let v = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
            return nil
        }

        let webhookStr = read("MINDDOCK_FEISHU_WEBHOOK_URL", "minddock.feishu.webhookURL")
        let webhookURL = webhookStr.flatMap(URL.init(string:))
        let appId = read("MINDDOCK_FEISHU_APP_ID", "minddock.feishu.appId")
        let appSecret = read("MINDDOCK_FEISHU_APP_SECRET", "minddock.feishu.appSecret")
        let chatId = read("MINDDOCK_FEISHU_CHAT_ID", "minddock.feishu.chatId")
        let receiveIdType = read("MINDDOCK_FEISHU_RECEIVE_ID_TYPE", "minddock.feishu.receiveIdType") ?? "chat_id"
        let baseStr = read("MINDDOCK_FEISHU_BASE_URL", "minddock.feishu.baseURL") ?? "https://open.feishu.cn"
        let baseURL = URL(string: baseStr) ?? URL(string: "https://open.feishu.cn")!
        let pushPlusToken = read("MINDDOCK_PUSHPLUS_TOKEN", "minddock.pushplus.token")

        let cfg = MobileBridgeConfig(
            webhookURL: webhookURL,
            appId: appId,
            appSecret: appSecret,
            chatId: chatId,
            receiveIdType: receiveIdType,
            apiBaseURL: baseURL,
            pushPlusToken: pushPlusToken
        )
        if cfg.webhookURL == nil && !cfg.hasAppBotCredentials {
            return nil
        }
        return cfg
    }
}

public final class FeishuMobileBridgeClient: MobileBridgeClient, @unchecked Sendable {
    public let config: MobileBridgeConfig
    private let session: URLSession
    private let audioTranscriber: (any AudioTranscriber)?
    private let lock = NSLock()
    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var discoveredChatId: String?

    public init(
        config: MobileBridgeConfig,
        session: URLSession = .shared,
        audioTranscriber: (any AudioTranscriber)? = nil
    ) {
        self.config = config
        self.session = session
        self.audioTranscriber = audioTranscriber
    }

    public func pushLifeDock(_ payload: LifeDockPushPayload) async throws {
        if config.hasAppBotCredentials {
            let token = try await validTenantAccessToken()
            if let receiveId = try await resolveTargetChatId(token: token) {
                try await sendAppBotCard(payload: payload, receiveId: receiveId, token: token)
                return
            }
            if config.webhookURL == nil {
                throw MobileBridgeError.invalidResponse(
                    "Feishu App credentials verified, but no bot chat found yet. Send 'hi' to your MindDock bot in Feishu (or fill in Chat ID)."
                )
            }
        }

        if let webhookURL = config.webhookURL {
            try await sendWebhookPush(payload: payload, webhookURL: webhookURL)
            return
        }

        throw MobileBridgeError.unconfigured
    }

    public func pullMessages(sinceCursor: String?) async throws -> InboundMessageBatch {
        if !config.hasAppBotCredentials {
            return InboundMessageBatch(messages: [], nextCursor: sinceCursor)
        }

        let token = try await validTenantAccessToken()
        guard let chatId = try await resolveTargetChatId(token: token) else {
            return InboundMessageBatch(messages: [], nextCursor: sinceCursor)
        }

        let parsedCursor = Self.parseCursor(sinceCursor)
        var pageToken: String? = nil
        var collectedMessages: [InboundMobileMessage] = []
        var latestCursor = sinceCursor

        repeat {
            var comps = URLComponents(
                url: config.apiBaseURL.appendingPathComponent("/open-apis/im/v1/messages"),
                resolvingAgainstBaseURL: false
            )
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "container_id_type", value: "chat"),
                URLQueryItem(name: "container_id", value: chatId),
                URLQueryItem(name: "sort_type", value: "ByCreateTimeAsc"),
                URLQueryItem(name: "page_size", value: "50")
            ]
            if let cursorMs = parsedCursor?.timestampMs {
                let startSeconds = cursorMs >= 100_000_000_000 ? (cursorMs / 1000) : cursorMs
                queryItems.append(URLQueryItem(name: "start_time", value: String(startSeconds)))
            }
            if let pageToken {
                queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
            }
            comps?.queryItems = queryItems
            guard let url = comps?.url else {
                throw MobileBridgeError.invalidResponse("Unable to construct Feishu message history URL")
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, http) = try await performDataRequest(req)
            try validateHTTPAndFeishuCode(data: data, response: http)

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = root["data"] as? [String: Any] else {
                break
            }

            let rawItems = (dataObj["items"] as? [[String: Any]]) ?? []
            for item in rawItems {
                guard let messageId = item["message_id"] as? String, !messageId.isEmpty else {
                    continue
                }
                let createTimeStr = (item["create_time"] as? String) ?? "0"
                let itemTimeMs = Int64(createTimeStr) ?? 0

                if let cursor = parsedCursor {
                    if itemTimeMs < cursor.timestampMs {
                        continue
                    }
                    if itemTimeMs == cursor.timestampMs && messageId == cursor.messageId {
                        continue
                    }
                }

                let senderObj = item["sender"] as? [String: Any]
                let senderType = (senderObj?["sender_type"] as? String)?.lowercased() ?? "user"
                let senderRole: InboundSenderRole = (senderType == "app" || senderType == "bot") ? .bot : .user
                let msgType = (item["msg_type"] as? String)?.lowercased() ?? "text"
                let bodyObj = item["body"] as? [String: Any]
                let contentRaw = (bodyObj?["content"] as? String) ?? ""

                if senderRole == .bot {
                    collectedMessages.append(
                        InboundMobileMessage(
                            messageId: messageId,
                            senderRole: .bot,
                            kind: .text,
                            text: "",
                            createdAtTimestamp: createTimeStr
                        )
                    )
                    latestCursor = "\(createTimeStr)#\(messageId)"
                    continue
                }

                if msgType == "audio" {
                    let fileKey = Self.extractJSONField("file_key", from: contentRaw)
                    var audioBytes: Data? = nil
                    var transcript = ""
                    if let fileKey, !fileKey.isEmpty {
                        let downloaded = try await downloadMessageResource(
                            messageId: messageId,
                            fileKey: fileKey,
                            type: "audio",
                            token: token
                        )
                        if let transcriber = self.audioTranscriber {
                            transcript = try await transcriber.transcribe(audioData: downloaded, fileExtension: "opus")
                        } else {
                            audioBytes = downloaded
                        }
                    }
                    collectedMessages.append(
                        InboundMobileMessage(
                            messageId: messageId,
                            senderRole: .user,
                            kind: .audio,
                            text: transcript,
                            audioData: audioBytes,
                            audioFileExtension: "opus",
                            createdAtTimestamp: createTimeStr
                        )
                    )
                } else {
                    let parsedText = Self.extractMessageText(msgType: msgType, contentRaw: contentRaw)
                    collectedMessages.append(
                        InboundMobileMessage(
                            messageId: messageId,
                            senderRole: .user,
                            kind: .text,
                            text: parsedText,
                            createdAtTimestamp: createTimeStr
                        )
                    )
                }

                latestCursor = "\(createTimeStr)#\(messageId)"
            }

            let hasMore = (dataObj["has_more"] as? Bool) ?? false
            let nextToken = dataObj["page_token"] as? String
            if hasMore, let nextToken, !nextToken.isEmpty {
                pageToken = nextToken
            } else {
                pageToken = nil
            }
        } while pageToken != nil

        return InboundMessageBatch(messages: collectedMessages, nextCursor: latestCursor)
    }

    // MARK: - Formatting & Outbound Transport

    public static func formatLockScreenTitle(for payload: LifeDockPushPayload) -> String {
        "🌿 MindDock · 生活停靠台 (\(payload.berths.count)/\(DockEngine.maxBerths))"
    }

    public static func formatLockScreenMarkdown(for payload: LifeDockPushPayload) -> String {
        var blocks: [String] = []
        for berth in payload.berths {
            var line = "**\(berth.slotNumber).** \(berth.raw)"
            if let prep = berth.prep?.trimmingCharacters(in: .whitespacesAndNewlines), !prep.isEmpty {
                line += "\n💡 \(prep)"
            }
            blocks.append(line)
        }
        if payload.queuedCount > 0 {
            blocks.append("*(候补队列还有 \(payload.queuedCount) 项，销项后自动递补)*")
        }
        return blocks.joined(separator: "\n\n")
    }

    public static func buildFeishuInteractiveCard(for payload: LifeDockPushPayload) -> [String: Any] {
        let title = formatLockScreenTitle(for: payload)
        let markdown = formatLockScreenMarkdown(for: payload)
        return [
            "config": ["wide_screen_mode": true],
            "header": [
                "template": "turquoise",
                "title": [
                    "tag": "plain_text",
                    "content": title
                ]
            ],
            "elements": [
                [
                    "tag": "markdown",
                    "content": markdown
                ],
                [
                    "tag": "hr"
                ],
                [
                    "tag": "note",
                    "elements": [
                        [
                            "tag": "plain_text",
                            "content": "回复 \"done 1\" / \"完成 1\" / \"1\" 销项并自动递补 · 直接发语音或文字可随时闪投"
                        ]
                    ]
                ]
            ]
        ]
    }

    private func sendWebhookPush(payload: LifeDockPushPayload, webhookURL: URL) async throws {
        let host = (webhookURL.host ?? "").lowercased()
        let title = Self.formatLockScreenTitle(for: payload)
        let markdown = Self.formatLockScreenMarkdown(for: payload)
            + "\n\n---\n回复 `done 1` / `完成 1` 销项"
        let bodyDict: [String: Any]

        if host.contains("ftqq.com") || host.contains("ft07.com") {
            bodyDict = [
                "title": title,
                "desp": markdown
            ]
        } else if host.contains("pushplus.plus") {
            var dict: [String: Any] = [
                "title": title,
                "content": markdown,
                "template": "markdown"
            ]
            if let token = config.pushPlusToken {
                dict["token"] = token
            } else if let comps = URLComponents(url: webhookURL, resolvingAgainstBaseURL: false),
                      let qToken = comps.queryItems?.first(where: { $0.name == "token" })?.value {
                dict["token"] = qToken
            }
            bodyDict = dict
        } else {
            bodyDict = [
                "msg_type": "interactive",
                "card": Self.buildFeishuInteractiveCard(for: payload)
            ]
        }

        var req = URLRequest(url: webhookURL)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, http) = try await performDataRequest(req)
        try validateHTTPAndFeishuCode(data: data, response: http)
    }

    private func sendAppBotCard(payload: LifeDockPushPayload, receiveId: String, token: String) async throws {
        var comps = URLComponents(
            url: config.apiBaseURL.appendingPathComponent("/open-apis/im/v1/messages"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "receive_id_type", value: config.receiveIdType)]
        guard let url = comps?.url else {
            throw MobileBridgeError.invalidResponse("Unable to build Feishu messages URL")
        }

        let card = Self.buildFeishuInteractiveCard(for: payload)
        let cardData = try JSONSerialization.data(withJSONObject: card)
        guard let cardString = String(data: cardData, encoding: .utf8) else {
            throw MobileBridgeError.invalidResponse("Unable to encode Feishu card content string")
        }

        let body: [String: Any] = [
            "receive_id": receiveId,
            "msg_type": "interactive",
            "content": cardString
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await performDataRequest(req)
        try validateHTTPAndFeishuCode(data: data, response: http)
    }

    private func validTenantAccessToken() async throws -> String {
        let now = Date()
        if let existing = lock.withLock({ () -> String? in
            if let token = cachedToken, now < tokenExpiresAt {
                return token
            }
            return nil
        }) {
            return existing
        }

        guard let appId = config.appId, let appSecret = config.appSecret else {
            throw MobileBridgeError.unconfigured
        }

        let authURL = config.apiBaseURL.appendingPathComponent("/open-apis/auth/v3/tenant_access_token/internal")
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_id": appId,
            "app_secret": appSecret
        ])

        let (data, http) = try await performDataRequest(req)
        try validateHTTPAndFeishuCode(data: data, response: http)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["tenant_access_token"] as? String, !token.isEmpty else {
            throw MobileBridgeError.invalidResponse("Missing tenant_access_token in Feishu response")
        }
        let expireSeconds = (json["expire"] as? Int) ?? 7200
        let expiry = Date().addingTimeInterval(TimeInterval(max(60, expireSeconds - 60)))

        lock.withLock {
            self.cachedToken = token
            self.tokenExpiresAt = expiry
        }
        return token
    }

    private func resolveTargetChatId(token: String) async throws -> String? {
        if let explicit = config.chatId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let cached = lock.withLock({ discoveredChatId }) {
            return cached
        }

        var comps = URLComponents(
            url: config.apiBaseURL.appendingPathComponent("/open-apis/im/v1/chats"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "page_size", value: "20")]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await performDataRequest(req)
        try validateHTTPAndFeishuCode(data: data, response: http)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let items = dataObj["items"] as? [[String: Any]],
           let firstChatId = items.first?["chat_id"] as? String,
           !firstChatId.isEmpty {
            lock.withLock { self.discoveredChatId = firstChatId }
            return firstChatId
        }
        return nil
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileBridgeError.invalidResponse("Non-HTTP response")
        }
        return (data, http)
    }

    private func validateHTTPAndFeishuCode(data: Data, response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw MobileBridgeError.httpStatus(response.statusCode, bodyStr)
        }
        if !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? Int,
           code != 0 {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? "Remote error"
            throw MobileBridgeError.remoteError(code, msg)
        }
    }

    private func downloadMessageResource(
        messageId: String,
        fileKey: String,
        type: String,
        token: String
    ) async throws -> Data {
        var comps = URLComponents(
            url: config.apiBaseURL
                .appendingPathComponent("/open-apis/im/v1/messages")
                .appendingPathComponent(messageId)
                .appendingPathComponent("resources")
                .appendingPathComponent(fileKey),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "type", value: type)]
        guard let url = comps?.url else {
            throw MobileBridgeError.invalidResponse("Unable to build resource download URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await performDataRequest(req)
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw MobileBridgeError.httpStatus(http.statusCode, bodyStr)
        }
        return data
    }

    private static func parseCursor(_ cursor: String?) -> (timestampMs: Int64, messageId: String?)? {
        guard let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !cursor.isEmpty else {
            return nil
        }
        let parts = cursor.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let ts = Int64(parts[0]) else {
            return nil
        }
        let msgId = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (ts, msgId)
    }

    private static func extractJSONField(_ key: String, from rawJSON: String) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj[key] as? String
    }

    private static func extractMessageText(msgType: String, contentRaw: String) -> String {
        if let text = extractJSONField("text", from: contentRaw) {
            return text
        }
        if msgType == "post",
           let data = contentRaw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var fragments: [String] = []
            if let title = obj["title"] as? String, !title.isEmpty {
                fragments.append(title)
            }
            if let rows = obj["content"] as? [[[String: Any]]] {
                for row in rows {
                    let line = row.compactMap { $0["text"] as? String }.joined()
                    if !line.isEmpty { fragments.append(line) }
                }
            }
            if !fragments.isEmpty {
                return fragments.joined(separator: "\n")
            }
        }
        return contentRaw
    }
}

public final class MacOSAudioTranscriber: AudioTranscriber, Sendable {
    public let localeIdentifier: String

    public init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
    }

    public func transcribe(audioData: Data, fileExtension: String) async throws -> String {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindDockAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sanitizedExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty
            ? "opus"
            : fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let inputURL = workDir.appendingPathComponent("clip.\(sanitizedExt)")
        let wavURL = workDir.appendingPathComponent("clip.wav")
        try audioData.write(to: inputURL, options: .atomic)

        let targetAudioURL = Self.convertToPlayableWAVIfNeeded(inputURL: inputURL, wavURL: wavURL)

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw MobileBridgeError.transcriptionFailed("SFSpeechRecognizer unavailable for locale \(localeIdentifier)")
        }

        let request = SFSpeechURLRecognitionRequest(url: targetAudioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            final class ResumeGate: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }
            let gate = ResumeGate()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let shouldResume = gate.lock.withLock { () -> Bool in
                        guard !gate.resumed else { return false }
                        gate.resumed = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: MobileBridgeError.transcriptionFailed(error.localizedDescription))
                    }
                    return
                }
                if let result, result.isFinal {
                    let shouldResume = gate.lock.withLock { () -> Bool in
                        guard !gate.resumed else { return false }
                        gate.resumed = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }
    }

    private static func convertToPlayableWAVIfNeeded(inputURL: URL, wavURL: URL) -> URL {
        if inputURL.pathExtension.lowercased() == "wav" {
            return inputURL
        }
        let afconvertPath = "/usr/bin/afconvert"
        if FileManager.default.isExecutableFile(atPath: afconvertPath) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: afconvertPath)
            proc.arguments = ["-f", "WAVE", "-d", "LEI16@16000", inputURL.path, wavURL.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: wavURL.path) {
                    return wavURL
                }
            }
        }
        let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = ["-y", "-i", inputURL.path, "-ar", "16000", "-ac", "1", wavURL.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: wavURL.path) {
                    return wavURL
                }
            }
        }
        return inputURL
    }
}
