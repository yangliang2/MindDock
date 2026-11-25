import Darwin
import Foundation

public struct MindDockSettings: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var llmBaseURL: String
    public var llmAPIKey: String
    public var llmModel: String
    public var asrEndpointURL: String
    public var asrModel: String

    public var feishuWebhookURL: String
    public var feishuAppId: String
    public var feishuAppSecret: String
    public var feishuChatId: String
    public var feishuReceiveIdType: String
    public var feishuBaseURL: String
    public var pushPlusToken: String

    public init(
        llmBaseURL: String = "https://api.deepseek.com/v1",
        llmAPIKey: String = "",
        llmModel: String = "deepseek-chat",
        asrEndpointURL: String = "",
        asrModel: String = "whisper-1",
        feishuWebhookURL: String = "",
        feishuAppId: String = "",
        feishuAppSecret: String = "",
        feishuChatId: String = "",
        feishuReceiveIdType: String = "chat_id",
        feishuBaseURL: String = "https://open.feishu.cn",
        pushPlusToken: String = ""
    ) {
        self.llmBaseURL = llmBaseURL
        self.llmAPIKey = llmAPIKey
        self.llmModel = llmModel
        self.asrEndpointURL = asrEndpointURL
        self.asrModel = asrModel
        self.feishuWebhookURL = feishuWebhookURL
        self.feishuAppId = feishuAppId
        self.feishuAppSecret = feishuAppSecret
        self.feishuChatId = feishuChatId
        self.feishuReceiveIdType = feishuReceiveIdType
        self.feishuBaseURL = feishuBaseURL
        self.pushPlusToken = pushPlusToken
    }

    public var openAIConfiguration: OpenAICompatibleConfiguration {
        let trimmedBase = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = URL(string: trimmedBase.isEmpty ? "https://api.deepseek.com/v1" : trimmedBase)
            ?? URL(string: "https://api.deepseek.com/v1")!

        let trimmedModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? "deepseek-chat" : trimmedModel

        let trimmedASR = asrEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedASRURL = trimmedASR.isEmpty ? nil : URL(string: trimmedASR)

        let trimmedASRModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedASRModel = trimmedASRModel.isEmpty ? "whisper-1" : trimmedASRModel

        return OpenAICompatibleConfiguration(
            baseURL: resolvedBase,
            apiKey: llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: resolvedModel,
            asrEndpointURL: resolvedASRURL,
            asrModel: resolvedASRModel
        )
    }

    public var mobileBridgeConfig: MobileBridgeConfig? {
        let trimmedWebhook = feishuWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookURL = trimmedWebhook.isEmpty ? nil : URL(string: trimmedWebhook)

        let trimmedAppId = Self.nonEmptyOrNil(feishuAppId)
        let trimmedAppSecret = Self.nonEmptyOrNil(feishuAppSecret)
        let trimmedChatId = Self.nonEmptyOrNil(feishuChatId)
        let trimmedReceiveType = Self.nonEmptyOrNil(feishuReceiveIdType) ?? "chat_id"
        let trimmedFeishuBase = Self.nonEmptyOrNil(feishuBaseURL) ?? "https://open.feishu.cn"
        let resolvedFeishuBase = URL(string: trimmedFeishuBase) ?? URL(string: "https://open.feishu.cn")!
        let trimmedPushPlus = Self.nonEmptyOrNil(pushPlusToken)

        let cfg = MobileBridgeConfig(
            webhookURL: webhookURL,
            appId: trimmedAppId,
            appSecret: trimmedAppSecret,
            chatId: trimmedChatId,
            receiveIdType: trimmedReceiveType,
            apiBaseURL: resolvedFeishuBase,
            pushPlusToken: trimmedPushPlus
        )
        if cfg.webhookURL == nil && !cfg.hasAppBotCredentials {
            return nil
        }
        return cfg
    }

    public var redactedSummary: String {
        let keyStatus = Self.nonEmptyOrNil(llmAPIKey) == nil ? "unconfigured" : "***REDACTED***"
        let secretStatus = Self.nonEmptyOrNil(feishuAppSecret) == nil ? "unconfigured" : "***REDACTED***"
        let webhookStatus: String = {
            guard let raw = Self.nonEmptyOrNil(feishuWebhookURL), let url = URL(string: raw), let host = url.host else {
                return "unconfigured"
            }
            return "https://\(host)/***REDACTED***"
        }()
        let pushPlusStatus = Self.nonEmptyOrNil(pushPlusToken) == nil ? "unconfigured" : "***REDACTED***"
        return "MindDockSettings(llmBaseURL: \(llmBaseURL), llmModel: \(llmModel), llmAPIKey: \(keyStatus), asrEndpointURL: \(asrEndpointURL), feishuAppId: \(feishuAppId), feishuAppSecret: \(secretStatus), feishuChatId: \(feishuChatId), feishuWebhookURL: \(webhookStatus), pushPlusToken: \(pushPlusStatus))"
    }

    public var description: String {
        redactedSummary
    }

    public var debugDescription: String {
        redactedSummary
    }

    fileprivate static func nonEmptyOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum MindDockSettingsError: Error, LocalizedError, Sendable, Equatable {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let msg):
            return msg
        }
    }
}

public final class MindDockSettingsStore: @unchecked Sendable {
    public let configJSONURL: URL
    public let primaryDotEnvURL: URL
    public let additionalDotEnvURLs: [URL]
    private let environment: [String: String]
    private let defaults: UserDefaults?
    private let lock = NSLock()

    public static func defaultConfigDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let customDir = MindDockSettings.nonEmptyOrNil(environment["MINDDOCK_CONFIG_DIR"]) {
            return URL(fileURLWithPath: (customDir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("minddock", isDirectory: true)
    }

    public init(
        configJSONURL: URL? = nil,
        primaryDotEnvURL: URL? = nil,
        additionalDotEnvURLs: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = .standard
    ) {
        let configDir = Self.defaultConfigDirectoryURL(environment: environment)
        self.configJSONURL = configJSONURL ?? configDir.appendingPathComponent("config.json")
        if let primaryDotEnvURL {
            self.primaryDotEnvURL = primaryDotEnvURL
        } else if let envOverride = MindDockSettings.nonEmptyOrNil(environment["MINDDOCK_ENV_FILE"]) {
            self.primaryDotEnvURL = URL(fileURLWithPath: (envOverride as NSString).expandingTildeInPath)
        } else {
            self.primaryDotEnvURL = configDir.appendingPathComponent(".env")
        }

        if let additionalDotEnvURLs {
            self.additionalDotEnvURLs = additionalDotEnvURLs
        } else {
            let repoDotEnv = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env")
            if repoDotEnv.standardizedFileURL != self.primaryDotEnvURL.standardizedFileURL {
                self.additionalDotEnvURLs = [repoDotEnv]
            } else {
                self.additionalDotEnvURLs = []
            }
        }

        self.environment = environment
        self.defaults = defaults
    }

    public func load() -> MindDockSettings {
        lock.withLock {
            var merged = settingsFromDefaults()

            var dotEnvMap: [String: String] = [:]
            for extraURL in additionalDotEnvURLs.reversed() {
                let parsed = Self.parseDotEnvFile(at: extraURL)
                for (k, v) in parsed { dotEnvMap[k] = v }
            }
            let primaryParsed = Self.parseDotEnvFile(at: primaryDotEnvURL)
            for (k, v) in primaryParsed { dotEnvMap[k] = v }

            let jsonSettings = readJSONConfigFile(at: configJSONURL)
            let jsonMTime = Self.modificationDate(of: configJSONURL)
            let dotEnvMTime = Self.latestModificationDate(of: [primaryDotEnvURL] + additionalDotEnvURLs)

            // Apply older file source first, then newer file source so CLI setup-wizard.sh (.env)
            // and in-app Settings UI (config.json + .env) stay seamlessly synchronized.
            if let jsonSettings {
                if let jsonMTime, let dotEnvMTime, dotEnvMTime > jsonMTime {
                    merged = jsonSettings
                    applyEnvDictionary(dotEnvMap, into: &merged)
                } else {
                    applyEnvDictionary(dotEnvMap, into: &merged)
                    merged = jsonSettings
                }
            } else {
                applyEnvDictionary(dotEnvMap, into: &merged)
            }

            // Process environment overrides always win at runtime.
            applyEnvDictionary(environment, into: &merged)
            return merged
        }
    }

    public func save(_ settings: MindDockSettings) throws {
        try lock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(settings)
            try Self.writeSecureFile0600(data: jsonData, to: configJSONURL)

            let dotEnvData = Self.buildMergedDotEnvData(for: settings, existingFileURL: primaryDotEnvURL)
            try Self.writeSecureFile0600(data: dotEnvData, to: primaryDotEnvURL)

            if let defaults {
                defaults.set(settings.llmBaseURL, forKey: "minddock.llm.baseURL")
                defaults.set(settings.llmModel, forKey: "minddock.llm.model")
                defaults.set(settings.asrEndpointURL, forKey: "minddock.asr.endpointURL")
                defaults.set(settings.asrModel, forKey: "minddock.asr.model")
                defaults.set(settings.feishuChatId, forKey: "minddock.feishu.chatId")
                defaults.set(settings.feishuReceiveIdType, forKey: "minddock.feishu.receiveIdType")
                defaults.set(settings.feishuBaseURL, forKey: "minddock.feishu.baseURL")

                // Never leave plaintext secrets in UserDefaults plists.
                defaults.removeObject(forKey: "minddock.llm.apiKey")
                defaults.removeObject(forKey: "minddock.feishu.appId")
                defaults.removeObject(forKey: "minddock.feishu.appSecret")
                defaults.removeObject(forKey: "minddock.feishu.webhookURL")
                defaults.removeObject(forKey: "minddock.pushplus.token")
            }
        }
    }

    // MARK: - Internal Parsing & Secure File Helpers

    private static let managedEnvKeys: [String] = [
        "MINDDOCK_LLM_BASE_URL",
        "MINDDOCK_LLM_API_KEY",
        "MINDDOCK_LLM_MODEL",
        "MINDDOCK_ASR_URL",
        "MINDDOCK_ASR_MODEL",
        "MINDDOCK_FEISHU_WEBHOOK_URL",
        "MINDDOCK_FEISHU_APP_ID",
        "MINDDOCK_FEISHU_APP_SECRET",
        "MINDDOCK_FEISHU_CHAT_ID",
        "MINDDOCK_FEISHU_RECEIVE_ID_TYPE",
        "MINDDOCK_FEISHU_BASE_URL",
        "MINDDOCK_PUSHPLUS_TOKEN"
    ]

    private func settingsFromDefaults() -> MindDockSettings {
        guard let defaults else { return MindDockSettings() }
        var s = MindDockSettings()
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.llm.baseURL")) {
            s.llmBaseURL = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.llm.apiKey")) {
            s.llmAPIKey = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.llm.model")) {
            s.llmModel = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.asr.endpointURL")) {
            s.asrEndpointURL = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.asr.model")) {
            s.asrModel = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.webhookURL")) {
            s.feishuWebhookURL = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.appId")) {
            s.feishuAppId = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.appSecret")) {
            s.feishuAppSecret = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.chatId")) {
            s.feishuChatId = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.receiveIdType")) {
            s.feishuReceiveIdType = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.feishu.baseURL")) {
            s.feishuBaseURL = v
        }
        if let v = MindDockSettings.nonEmptyOrNil(defaults.string(forKey: "minddock.pushplus.token")) {
            s.pushPlusToken = v
        }
        return s
    }

    private func applyEnvDictionary(_ env: [String: String], into settings: inout MindDockSettings) {
        if let v = Self.firstNonEmpty(env["MINDDOCK_LLM_BASE_URL"], env["OPENAI_BASE_URL"]) {
            settings.llmBaseURL = v
        }
        if let v = Self.firstNonEmpty(env["MINDDOCK_LLM_API_KEY"], env["DEEPSEEK_API_KEY"], env["OPENAI_API_KEY"]) {
            settings.llmAPIKey = v
        }
        if let v = Self.firstNonEmpty(env["MINDDOCK_LLM_MODEL"], env["OPENAI_MODEL"]) {
            settings.llmModel = v
        }
        if env["MINDDOCK_ASR_URL"] != nil {
            settings.asrEndpointURL = env["MINDDOCK_ASR_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let v = Self.firstNonEmpty(env["MINDDOCK_ASR_MODEL"]) {
            settings.asrModel = v
        }
        if env["MINDDOCK_FEISHU_WEBHOOK_URL"] != nil {
            settings.feishuWebhookURL = env["MINDDOCK_FEISHU_WEBHOOK_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if env["MINDDOCK_FEISHU_APP_ID"] != nil {
            settings.feishuAppId = env["MINDDOCK_FEISHU_APP_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if env["MINDDOCK_FEISHU_APP_SECRET"] != nil {
            settings.feishuAppSecret = env["MINDDOCK_FEISHU_APP_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if env["MINDDOCK_FEISHU_CHAT_ID"] != nil {
            settings.feishuChatId = env["MINDDOCK_FEISHU_CHAT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let v = Self.firstNonEmpty(env["MINDDOCK_FEISHU_RECEIVE_ID_TYPE"]) {
            settings.feishuReceiveIdType = v
        }
        if let v = Self.firstNonEmpty(env["MINDDOCK_FEISHU_BASE_URL"]) {
            settings.feishuBaseURL = v
        }
        if env["MINDDOCK_PUSHPLUS_TOKEN"] != nil {
            settings.pushPlusToken = env["MINDDOCK_PUSHPLUS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func readJSONConfigFile(at url: URL) -> MindDockSettings? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(MindDockSettings.self, from: data)
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private static func latestModificationDate(of urls: [URL]) -> Date? {
        urls.compactMap(modificationDate(of:)).max()
    }

    static func parseDotEnvFile(at url: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eqIndex)...])
            if value.count >= 2 && value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "'\\''", with: "'")
            } else if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                value = value
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else {
                if let commentIdx = value.range(of: " #")?.lowerBound {
                    value = String(value[..<commentIdx])
                }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    private static func buildMergedDotEnvData(for settings: MindDockSettings, existingFileURL: URL) -> Data {
        let managedSet = Set(managedEnvKeys)
        var preservedLines: [String] = []
        if let existing = try? String(contentsOf: existingFileURL, encoding: .utf8) {
            for rawLine in existing.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    var candidateKey = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    if candidateKey.hasPrefix("export ") {
                        candidateKey = String(candidateKey.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                    }
                    if managedSet.contains(candidateKey) {
                        continue
                    }
                }
                preservedLines.append(rawLine)
            }
        }

        let pairs: [(String, String)] = [
            ("MINDDOCK_LLM_BASE_URL", settings.llmBaseURL),
            ("MINDDOCK_LLM_API_KEY", settings.llmAPIKey),
            ("MINDDOCK_LLM_MODEL", settings.llmModel),
            ("MINDDOCK_ASR_URL", settings.asrEndpointURL),
            ("MINDDOCK_ASR_MODEL", settings.asrModel),
            ("MINDDOCK_FEISHU_WEBHOOK_URL", settings.feishuWebhookURL),
            ("MINDDOCK_FEISHU_APP_ID", settings.feishuAppId),
            ("MINDDOCK_FEISHU_APP_SECRET", settings.feishuAppSecret),
            ("MINDDOCK_FEISHU_CHAT_ID", settings.feishuChatId),
            ("MINDDOCK_FEISHU_RECEIVE_ID_TYPE", settings.feishuReceiveIdType),
            ("MINDDOCK_FEISHU_BASE_URL", settings.feishuBaseURL),
            ("MINDDOCK_PUSHPLUS_TOKEN", settings.pushPlusToken)
        ]

        var outLines = preservedLines
        for (key, value) in pairs {
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            outLines.append("\(key)='\(escaped)'")
        }
        return Data((outLines.joined(separator: "\n") + "\n").utf8)
    }

    private static func writeSecureFile0600(data: Data, to targetURL: URL) throws {
        let dirURL = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = Darwin.chmod(dirURL.path, mode_t(0o700))

        let tempURL = dirURL.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            throw MindDockSettingsError.writeFailed("Unable to create secure config file at \(targetURL.path): \(err)")
        }

        do {
            _ = Darwin.fchmod(fd, mode_t(0o600))
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var writtenTotal = 0
                while writtenTotal < rawBuffer.count {
                    let count = Darwin.write(fd, base.advanced(by: writtenTotal), rawBuffer.count - writtenTotal)
                    if count < 0 {
                        if errno == EINTR { continue }
                        let err = String(cString: strerror(errno))
                        throw MindDockSettingsError.writeFailed("Write failed for \(targetURL.path): \(err)")
                    }
                    writtenTotal += count
                }
            }
            _ = Darwin.fsync(fd)
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        if Darwin.rename(tempURL.path, targetURL.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempURL)
            throw MindDockSettingsError.writeFailed("Atomic rename failed for \(targetURL.path): \(err)")
        }
        _ = Darwin.chmod(targetURL.path, mode_t(0o600))
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
