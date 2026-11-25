import Foundation

public struct DropPrepAnalysis: Sendable, Equatable {
    public let lane: Lane
    public let prep: String?
    public let prepState: PrepState

    public init(lane: Lane, prep: String?, prepState: PrepState) {
        self.lane = lane
        self.prep = prep
        self.prepState = prepState
    }

    public static func clampPrepLines(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(3).joined(separator: "\n")
    }
}

public enum IntelligenceConnectionError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case httpStatus(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API Key is empty. Enter an OpenAI-compatible API Key first."
        case .httpStatus(let status, let detail):
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        case .emptyResponse:
            return "Endpoint returned an empty completion response."
        }
    }
}

public protocol IntelligenceClient: Sendable {
    func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis
    func rankRecall(query: String, candidates: [DockItem]) async -> [DockItem]
    func transcribeAudio(data: Data, filename: String, mimeType: String) async -> String?
}

public extension IntelligenceClient {
    func rankRecall(query: String, candidates: [DockItem]) async -> [DockItem] {
        LocalRecallRanker.rank(query: query, candidates: candidates)
    }

    func transcribeAudio(data: Data, filename: String, mimeType: String) async -> String? {
        nil
    }
}

public struct OpenAICompatibleConfiguration: Sendable, Equatable, Codable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var asrEndpointURL: URL?
    public var asrModel: String
    public var timeoutInterval: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
        apiKey: String = "",
        model: String = "deepseek-chat",
        asrEndpointURL: URL? = nil,
        asrModel: String = "whisper-1",
        timeoutInterval: TimeInterval = 15.0
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.asrEndpointURL = asrEndpointURL
        self.asrModel = asrModel
        self.timeoutInterval = timeoutInterval
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let unconfigured = OpenAICompatibleConfiguration()

    public static func fromEnvironmentOrDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> OpenAICompatibleConfiguration {
        let baseStr = firstNonEmpty(
            environment["MINDDOCK_LLM_BASE_URL"],
            environment["OPENAI_BASE_URL"],
            defaults.string(forKey: "minddock.llm.baseURL")
        ) ?? "https://api.deepseek.com/v1"
        let baseURL = URL(string: baseStr) ?? URL(string: "https://api.deepseek.com/v1")!

        let apiKey = firstNonEmpty(
            environment["MINDDOCK_LLM_API_KEY"],
            environment["DEEPSEEK_API_KEY"],
            environment["OPENAI_API_KEY"],
            defaults.string(forKey: "minddock.llm.apiKey")
        ) ?? ""

        let model = firstNonEmpty(
            environment["MINDDOCK_LLM_MODEL"],
            environment["OPENAI_MODEL"],
            defaults.string(forKey: "minddock.llm.model")
        ) ?? "deepseek-chat"

        let asrURLStr = firstNonEmpty(
            environment["MINDDOCK_ASR_URL"],
            defaults.string(forKey: "minddock.asr.endpointURL")
        )
        let asrURL = asrURLStr.flatMap(URL.init(string:))

        let asrModel = firstNonEmpty(
            environment["MINDDOCK_ASR_MODEL"],
            defaults.string(forKey: "minddock.asr.model")
        ) ?? "whisper-1"

        return OpenAICompatibleConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            asrEndpointURL: asrURL,
            asrModel: asrModel
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

public final class OpenAICompatibleIntelligenceClient: IntelligenceClient, @unchecked Sendable {
    public let configuration: OpenAICompatibleConfiguration
    private let urlSession: URLSession

    public init(
        configuration: OpenAICompatibleConfiguration = .fromEnvironmentOrDefaults(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func testConnection() async throws -> String {
        guard configuration.isConfigured else {
            throw IntelligenceConnectionError.missingAPIKey
        }
        let reply = try await sendChatCompletion(
            system: "Reply briefly with OK.",
            user: "ping"
        )
        let cleaned = reply
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(cleaned.prefix(40))
        return "Connected (\(configuration.model)): \(preview)"
    }

    public func prepareDrop(raw: String, explicitLane: Lane?) async -> DropPrepAnalysis {
        let fallbackLane = explicitLane ?? DockEngine.inferLaneLocally(for: raw)
        guard configuration.isConfigured else {
            return DropPrepAnalysis(lane: fallbackLane, prep: nil, prepState: .skipped)
        }

        let systemPrompt = """
        You are MindDock's background Prep assistant.
        1. Classify the user's raw Drop into "work" (professional engineering, meetings, office tasks) or "life" (personal errands, family, health, bills, home).
        2. Write a concise Prep note (at most 3 short lines) giving concrete next steps, checklist cues, or context so the user can act immediately without starting from scratch. NEVER rewrite or repeat the raw text verbatim as a summary.
        Respond strictly with a JSON object: {"lane": "work" | "life", "prep": "line 1\\nline 2"}
        """
        let userPrompt = "Raw Drop:\n\(raw)"

        guard let content = try? await sendChatCompletion(system: systemPrompt, user: userPrompt),
              let jsonData = Self.extractJSONObjectData(from: content),
              let parsed = try? JSONDecoder().decode(PrepResponseDTO.self, from: jsonData) else {
            return DropPrepAnalysis(lane: fallbackLane, prep: nil, prepState: .skipped)
        }

        let resolvedLane: Lane
        if let explicitLane {
            resolvedLane = explicitLane
        } else if let llmLane = parsed.lane.flatMap({ Lane(rawValue: $0.lowercased()) }) {
            resolvedLane = llmLane
        } else {
            resolvedLane = fallbackLane
        }

        if let clamped = DropPrepAnalysis.clampPrepLines(parsed.prep) {
            return DropPrepAnalysis(lane: resolvedLane, prep: clamped, prepState: .ready)
        } else {
            return DropPrepAnalysis(lane: resolvedLane, prep: nil, prepState: .skipped)
        }
    }

    public func rankRecall(query: String, candidates: [DockItem]) async -> [DockItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !candidates.isEmpty else { return [] }

        guard configuration.isConfigured else {
            return LocalRecallRanker.rank(query: trimmedQuery, candidates: candidates)
        }

        let limitedCandidates = Array(candidates.prefix(80))
        let candidateLines = limitedCandidates.map { item -> String in
            let prepPart = item.prep.map { " | prep: \($0.replacingOccurrences(of: "\n", with: " "))" } ?? ""
            return "- id: \(item.id) | lane: \(item.lane.rawValue) | raw: \(item.raw)\(prepPart)"
        }.joined(separator: "\n")

        let systemPrompt = """
        You are MindDock's Recall assistant over the Deep memory layer.
        Match the user's vague natural-language impression (including synonyms, bilingual concepts, and fuzzy descriptions) against the candidate items.
        Return ONLY genuinely relevant item IDs ordered from best match to weakest match as JSON:
        {"matched_ids": ["id1", "id2"]}
        """
        let userPrompt = """
        Vague Recall query: \(trimmedQuery)

        Deep candidates:
        \(candidateLines)
        """

        guard let content = try? await sendChatCompletion(system: systemPrompt, user: userPrompt),
              let jsonData = Self.extractJSONObjectData(from: content),
              let parsed = try? JSONDecoder().decode(RecallResponseDTO.self, from: jsonData) else {
            return LocalRecallRanker.rank(query: trimmedQuery, candidates: candidates)
        }

        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var seen = Set<String>()
        var ordered: [DockItem] = []
        for id in parsed.matchedIDs {
            if !seen.contains(id), let item = byID[id] {
                seen.insert(id)
                ordered.append(item)
            }
        }
        return ordered
    }

    public func transcribeAudio(data: Data, filename: String, mimeType: String) async -> String? {
        guard let asrURL = configuration.asrEndpointURL, !data.isEmpty else { return nil }

        let boundary = "MindDockBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: asrURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutInterval
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if configuration.isConfigured {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(configuration.asrModel)\r\n".utf8))

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        guard let (responseData, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TranscriptionResponseDTO.self, from: responseData) else {
            return nil
        }

        let trimmed = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Internal HTTP & JSON Helpers

    private struct TranscriptionResponseDTO: Decodable {
        let text: String
    }

    private struct ChatCompletionRequestDTO: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatCompletionResponseDTO: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct PrepResponseDTO: Decodable {
        let lane: String?
        let prep: String?
    }

    private struct RecallResponseDTO: Decodable {
        let matchedIDs: [String]

        enum CodingKeys: String, CodingKey {
            case matchedIDs = "matched_ids"
        }
    }

    private func chatCompletionsURL() -> URL {
        let trimmed = configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed) ?? configuration.baseURL
        }
        return URL(string: "\(trimmed)/chat/completions") ?? configuration.baseURL.appendingPathComponent("chat/completions")
    }

    func sendChatCompletion(system: String, user: String) async throws -> String {
        var request = URLRequest(url: chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ChatCompletionRequestDTO(
            model: configuration.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            temperature: 0.2
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IntelligenceConnectionError.httpStatus(http.statusCode, String(bodyText.prefix(240)))
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponseDTO.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw IntelligenceConnectionError.emptyResponse
        }
        return content
    }

    static func extractJSONObjectData(from text: String) -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if let closingFence = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[..<closingFence.lowerBound])
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            return Data(String(cleaned[start...end]).utf8)
        }
        return Data(cleaned.utf8)
    }
}

public enum LocalRecallRanker {
    private static let synonymClusters: [[String]] = [
        ["login", "auth", "authentication", "signin", "sign-in", "passkey", "webauthn", "password", "passwordless", "oauth", "sso", "security", "credential", "登录", "免密", "鉴权", "认证", "密码", "密钥"],
        ["timeout", "504", "502", "gateway", "latency", "slow", "webhook", "callback", "payment", "billing", "nginx", "upstream", "超时", "延迟", "网关", "回调", "支付", "偶发", "报错", "故障"],
        ["database", "db", "sqlite", "sql", "wal", "query", "lock", "storage", "persistence", "migration", "数据库", "存储", "持久化", "迁移", "锁"],
        ["doctor", "dentist", "tooth", "teeth", "dental", "clinic", "hospital", "medicine", "pharmacy", "fever", "health", "checkup", "医疗", "医院", "牙医", "洗牙", "药店", "买药", "退烧", "退烧贴", "发烧", "体检"],
        ["package", "parcel", "delivery", "courier", "express", "pickup", "locker", "grocery", "groceries", "supermarket", "fresh", "errand", "快递", "取件", "丰巢", "包裹", "驿站", "生鲜", "超市", "买菜"],
        ["car", "auto", "vehicle", "insurance", "policy", "renew", "renewal", "bill", "utility", "车", "老车", "汽车", "车险", "续保", "保险", "水电", "缴费", "账单"],
        ["filter", "purifier", "hepa", "air", "home", "house", "guest", "family", "kid", "child", "滤芯", "净化器", "家里", "客人", "孩子", "娃", "家人"]
    ]

    public static func rank(query: String, candidates: [DockItem]) -> [DockItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty, !candidates.isEmpty else { return [] }

        let directTokens = tokenize(normalizedQuery)
        let expandedTerms = expandSynonyms(query: normalizedQuery, tokens: directTokens)

        var scored: [(item: DockItem, score: Double)] = []
        for item in candidates {
            let corpus = "\(item.raw)\n\(item.prep ?? "")".lowercased()
            let itemTokens = tokenize(corpus)
            var score = 0.0

            if corpus.contains(normalizedQuery) {
                score += 12.0
            }

            for token in directTokens {
                if itemTokens.contains(token) {
                    score += 4.0
                } else if token.count >= 2 && corpus.contains(token) {
                    score += 3.0
                }
            }

            for synonym in expandedTerms {
                if corpus.contains(synonym) || itemTokens.contains(synonym) {
                    score += 1.8
                }
            }

            if score > 0 {
                scored.append((item, score))
            }
        }

        return scored
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.001 {
                    return lhs.score > rhs.score
                }
                return lhs.item.updatedAt > rhs.item.updatedAt
            }
            .map(\.item)
    }

    private static func expandSynonyms(query: String, tokens: Set<String>) -> Set<String> {
        var expanded = Set<String>()
        for cluster in synonymClusters {
            let matched = cluster.contains { term in
                tokens.contains(term) || (term.count >= 2 && query.contains(term))
            }
            if matched {
                expanded.formUnion(cluster)
            }
        }
        return expanded.subtracting(tokens)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        var result = Set<String>()
        var currentASCII = ""
        var cjkChars: [Character] = []

        func flushASCII() {
            guard !currentASCII.isEmpty else { return }
            let word = currentASCII
            currentASCII = ""
            guard word.count >= 2 else { return }
            result.insert(word)
            if word.count > 4, word.hasSuffix("ing") {
                result.insert(String(word.dropLast(3)))
            } else if word.count > 3, word.hasSuffix("ed") {
                result.insert(String(word.dropLast(2)))
            } else if word.count > 3, word.hasSuffix("s") {
                result.insert(String(word.dropLast(1)))
            }
        }

        func flushCJK() {
            guard !cjkChars.isEmpty else { return }
            if cjkChars.count == 1 {
                result.insert(String(cjkChars[0]))
            } else {
                for i in 0..<(cjkChars.count - 1) {
                    result.insert(String([cjkChars[i], cjkChars[i + 1]]))
                }
            }
            cjkChars.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                flushCJK()
                currentASCII.unicodeScalars.append(scalar)
            } else if isCJKScalar(scalar) {
                flushASCII()
                cjkChars.append(Character(scalar))
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return result
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }
}
