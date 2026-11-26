import Foundation

public enum FeishuBrandDomain: String, Codable, Sendable, Equatable {
    case feishu
    case lark

    public var accountsBaseURL: URL {
        switch self {
        case .feishu:
            return URL(string: "https://accounts.feishu.cn")!
        case .lark:
            return URL(string: "https://accounts.larksuite.com")!
        }
    }

    public var openAPIBaseURL: URL {
        switch self {
        case .feishu:
            return URL(string: "https://open.feishu.cn")!
        case .lark:
            return URL(string: "https://open.larksuite.com")!
        }
    }
}

public struct FeishuDeviceSession: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let verificationURIComplete: URL
    public let expiresIn: Int
    public let interval: Int
    public let domain: FeishuBrandDomain

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL,
        expiresIn: Int,
        interval: Int,
        domain: FeishuBrandDomain = .feishu
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
        self.domain = domain
    }
}

public struct FeishuProvisionedBot: Sendable, Equatable {
    public let appId: String
    public let appSecret: String
    public let openId: String?
    public let domain: FeishuBrandDomain

    public init(
        appId: String,
        appSecret: String,
        openId: String?,
        domain: FeishuBrandDomain
    ) {
        self.appId = appId
        self.appSecret = appSecret
        self.openId = openId
        self.domain = domain
    }

    public func applyingCredentials(to settings: MindDockSettings) -> MindDockSettings {
        var updated = settings
        updated.feishuAppId = appId
        updated.feishuAppSecret = appSecret
        if let openId, !openId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.feishuOpenId = openId
        }
        updated.feishuBaseURL = domain.openAPIBaseURL.absoluteString
        updated.feishuReceiveIdType = "chat_id"
        updated.onboardingCompleted = true
        return updated
    }
}

public struct FeishuProvisioningCompletion: Sendable, Equatable {
    public let settings: MindDockSettings
    public let bootstrap: FeishuWelcomeBootstrapResult

    public init(settings: MindDockSettings, bootstrap: FeishuWelcomeBootstrapResult) {
        self.settings = settings
        self.bootstrap = bootstrap
    }
}

public enum FeishuPollStep: Sendable, Equatable {
    case pending(domain: FeishuBrandDomain, intervalIncreaseSeconds: Int)
    case provisioned(FeishuProvisionedBot)
}

public enum FeishuQRRegistrationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedAuthMethod([String])
    case accessDenied(String)
    case expiredToken(String)
    case invalidResponse(String)
    case httpStatus(Int, String)
    case remoteError(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAuthMethod(let methods):
            let joined = methods.isEmpty ? "无" : methods.joined(separator: ", ")
            return "当前飞书租户暂不支持一键密钥注册（支持方式：\(joined)），请改用「手动填凭证」模式。"
        case .accessDenied(let detail):
            let suffix = detail.isEmpty ? "" : "（\(detail)）"
            return "手机端取消或拒绝了授权\(suffix)，如企业限制了个人创建机器人，可改用「15秒单人群 Webhook」或「手动填凭证」。"
        case .expiredToken:
            return "二维码已过期，请点击「刷新二维码」重新生成。"
        case .invalidResponse(let detail):
            return "飞书授权响应格式异常：\(detail)"
        case .httpStatus(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "飞书服务返回 HTTP \(code)" : "飞书服务返回 HTTP \(code)：\(String(trimmed.prefix(160)))"
        case .remoteError(let code, let desc):
            return desc.isEmpty ? "飞书授权失败（\(code)）" : "飞书授权失败（\(code)）：\(desc)"
        }
    }
}

public final class FeishuQRBotRegistrar: Sendable {
    public static let manualPermissionScopesJSON: String = """
    {
      "scopes": {
        "tenant": [
          "im:message",
          "im:message:send_as_bot",
          "im:message.group_msg",
          "im:message.p2p_msg:readonly",
          "im:chat:readonly",
          "im:resource"
        ],
        "user": []
      }
    }
    """

    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.session = session
        self.sleep = sleep
    }

    public func beginRegistration(initialDomain: FeishuBrandDomain = .feishu) async throws -> FeishuDeviceSession {
        let endpoint = initialDomain.accountsBaseURL.appendingPathComponent("/oauth/v1/app/registration")

        let (initData, initHTTP) = try await postForm(url: endpoint, pairs: [("action", "init")])
        guard (200..<300).contains(initHTTP.statusCode) else {
            throw FeishuQRRegistrationError.httpStatus(initHTTP.statusCode, String(decoding: initData, as: UTF8.self))
        }
        guard let initJSON = try? JSONSerialization.jsonObject(with: initData) as? [String: Any] else {
            throw FeishuQRRegistrationError.invalidResponse("init 响应不是有效 JSON")
        }
        if let errCode = Self.nonEmptyString(initJSON["error"]) {
            let errDesc = Self.nonEmptyString(initJSON["error_description"]) ?? ""
            throw FeishuQRRegistrationError.remoteError(errCode, errDesc)
        }
        let supportedMethods = (initJSON["supported_auth_methods"] as? [String]) ?? []
        if !supportedMethods.contains("client_secret") {
            throw FeishuQRRegistrationError.unsupportedAuthMethod(supportedMethods)
        }

        let (beginData, beginHTTP) = try await postForm(
            url: endpoint,
            pairs: [
                ("action", "begin"),
                ("archetype", "PersonalAgent"),
                ("auth_method", "client_secret"),
                ("request_user_info", "open_id")
            ]
        )
        guard (200..<300).contains(beginHTTP.statusCode) else {
            throw FeishuQRRegistrationError.httpStatus(beginHTTP.statusCode, String(decoding: beginData, as: UTF8.self))
        }
        guard let beginJSON = try? JSONSerialization.jsonObject(with: beginData) as? [String: Any] else {
            throw FeishuQRRegistrationError.invalidResponse("begin 响应不是有效 JSON")
        }
        if let errCode = Self.nonEmptyString(beginJSON["error"]) {
            let errDesc = Self.nonEmptyString(beginJSON["error_description"]) ?? ""
            throw FeishuQRRegistrationError.remoteError(errCode, errDesc)
        }

        guard let deviceCode = Self.nonEmptyString(beginJSON["device_code"]),
              let rawCompleteURI = Self.nonEmptyString(beginJSON["verification_uri_complete"])
                ?? Self.nonEmptyString(beginJSON["verification_uri"]),
              let baseCompleteURL = URL(string: rawCompleteURI) else {
            throw FeishuQRRegistrationError.invalidResponse("缺少 device_code 或 verification_uri_complete")
        }

        let userCode = Self.nonEmptyString(beginJSON["user_code"]) ?? ""
        let rawVerificationURI = Self.nonEmptyString(beginJSON["verification_uri"]) ?? rawCompleteURI
        let verificationURI = URL(string: rawVerificationURI) ?? baseCompleteURL
        let expiresIn = Self.intValue(beginJSON["expires_in"]) ?? 3600
        let interval = max(1, Self.intValue(beginJSON["interval"]) ?? 5)
        let onboardingURL = Self.appendOnboardingQueryItems(to: baseCompleteURL)

        return FeishuDeviceSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: onboardingURL,
            expiresIn: expiresIn,
            interval: interval,
            domain: initialDomain
        )
    }

    public func pollOnce(deviceCode: String, domain: FeishuBrandDomain) async throws -> FeishuPollStep {
        let endpoint = domain.accountsBaseURL.appendingPathComponent("/oauth/v1/app/registration")
        let (data, http) = try await postForm(
            url: endpoint,
            pairs: [
                ("action", "poll"),
                ("device_code", deviceCode),
                ("tp", "ob_cli_app")
            ]
        )

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let userInfo = json?["user_info"] as? [String: Any]
        let tenantBrand = Self.nonEmptyString(userInfo?["tenant_brand"])?.lowercased()
        let resolvedDomain: FeishuBrandDomain = (tenantBrand == "lark") ? .lark : domain

        if let json,
           let clientId = Self.nonEmptyString(json["client_id"]),
           let clientSecret = Self.nonEmptyString(json["client_secret"]) {
            let openId = Self.nonEmptyString(userInfo?["open_id"])
            return .provisioned(
                FeishuProvisionedBot(
                    appId: clientId,
                    appSecret: clientSecret,
                    openId: openId,
                    domain: resolvedDomain
                )
            )
        }

        if let json, let errCode = Self.nonEmptyString(json["error"]) {
            let errDesc = Self.nonEmptyString(json["error_description"]) ?? ""
            switch errCode {
            case "authorization_pending":
                return .pending(domain: resolvedDomain, intervalIncreaseSeconds: 0)
            case "slow_down":
                return .pending(domain: resolvedDomain, intervalIncreaseSeconds: 5)
            case "access_denied":
                throw FeishuQRRegistrationError.accessDenied(errDesc)
            case "expired_token":
                throw FeishuQRRegistrationError.expiredToken(errDesc)
            default:
                throw FeishuQRRegistrationError.remoteError(errCode, errDesc)
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw FeishuQRRegistrationError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        throw FeishuQRRegistrationError.invalidResponse("轮询未返回凭证或等待状态")
    }

    public func pollStream(for deviceSession: FeishuDeviceSession) -> AsyncThrowingStream<FeishuPollStep, Error> {
        let registrar = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var currentDomain = deviceSession.domain
                var hasSwitchedToLark = (deviceSession.domain == .lark)
                var currentInterval = max(1, deviceSession.interval)
                let deadline = Date().addingTimeInterval(TimeInterval(max(10, deviceSession.expiresIn)))

                do {
                    while !Task.isCancelled {
                        if Date() >= deadline {
                            throw FeishuQRRegistrationError.expiredToken("timeout")
                        }
                        try await registrar.sleep(TimeInterval(currentInterval))
                        try Task.checkCancellation()

                        let step = try await registrar.pollOnce(
                            deviceCode: deviceSession.deviceCode,
                            domain: currentDomain
                        )
                        continuation.yield(step)

                        switch step {
                        case .provisioned:
                            continuation.finish()
                            return
                        case .pending(let suggestedDomain, let delta):
                            if suggestedDomain == .lark && !hasSwitchedToLark {
                                currentDomain = .lark
                                hasSwitchedToLark = true
                            }
                            if delta > 0 {
                                currentInterval += delta
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func awaitProvisioning(for deviceSession: FeishuDeviceSession) async throws -> FeishuProvisionedBot {
        for try await step in pollStream(for: deviceSession) {
            if case .provisioned(let bot) = step {
                return bot
            }
        }
        throw CancellationError()
    }

    public func completeProvisioning(
        _ bot: FeishuProvisionedBot,
        baseSettings: MindDockSettings
    ) async throws -> FeishuProvisioningCompletion {
        var updated = bot.applyingCredentials(to: baseSettings)
        let bridgeClient = FeishuMobileBridgeClient(
            config: MobileBridgeConfig(
                appId: bot.appId,
                appSecret: bot.appSecret,
                openId: bot.openId,
                receiveIdType: "chat_id",
                apiBaseURL: bot.domain.openAPIBaseURL
            ),
            session: session
        )
        let bootstrap = try await bridgeClient.bootstrapBotWelcomeAndDiscoverChatId(openId: bot.openId)
        updated.feishuOpenId = bootstrap.openId
        updated.feishuChatId = bootstrap.chatId
        updated.onboardingCompleted = true
        return FeishuProvisioningCompletion(settings: updated, bootstrap: bootstrap)
    }

    // MARK: - Helpers

    private func postForm(url: URL, pairs: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let encodedBody = pairs
            .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
        req.httpBody = Data(encodedBody.utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FeishuQRRegistrationError.invalidResponse("非 HTTP 响应")
        }
        return (data, http)
    }

    private static func appendOnboardingQueryItems(to url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "from" }) {
            items.append(URLQueryItem(name: "from", value: "oc_onboard"))
        }
        if !items.contains(where: { $0.name == "tp" }) {
            items.append(URLQueryItem(name: "tp", value: "ob_cli_app"))
        }
        comps.queryItems = items
        return comps.url ?? url
    }

    private static var formAllowedCharacters: CharacterSet {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? value
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }
}
