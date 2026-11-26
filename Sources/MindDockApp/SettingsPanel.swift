import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MindDockCore
import SwiftUI

enum SettingsFeedbackKind: Equatable {
    case neutral
    case working
    case success
    case error
}

enum FeishuSetupMode: String, CaseIterable, Identifiable {
    case qrScan
    case webhook
    case manualCredentials

    var id: String { rawValue }

    var tabTitle: String {
        switch self {
        case .qrScan:
            return "📱 飞书扫码一键创建"
        case .webhook:
            return "🔗 15秒单人群 Webhook"
        case .manualCredentials:
            return "🔑 手动填凭证"
        }
    }

    var badgeText: String? {
        switch self {
        case .qrScan:
            return "推荐 · 免填密钥"
        case .webhook:
            return "仅下班推锁屏"
        case .manualCredentials:
            return "企业权限受限备用"
        }
    }
}

enum FeishuQRViewState: Equatable {
    case idle
    case loadingQR
    case waitingForScan(qrURL: URL, userCode: String, isLarkDomain: Bool)
    case bindingWelcome
    case boundSuccess(chatId: String)
    case boundNeedsManualHi
    case failed(String)
}

enum QRCodeRenderer {
    private static let ciContext = CIContext(options: nil)

    static func makeQRCodeImage(from content: String, targetSide: CGFloat = 220) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = max(1, floor(targetSide / max(extent.width, extent.height)))
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height)
        )
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var draft: MindDockSettings
    @Published var selectedPreset: LLMProviderPreset
    @Published var showAdvancedLLM: Bool = false
    @Published var showAdvancedManualChatId: Bool = false
    @Published var revealLLMKey: Bool = false
    @Published var revealFeishuSecret: Bool = false
    @Published var revealWebhookURL: Bool = false

    @Published var onboardingStep: Int = 1
    @Published var step1FailedOnce: Bool = false
    @Published var mobileSetupMode: FeishuSetupMode = .qrScan
    @Published private(set) var qrState: FeishuQRViewState = .idle
    @Published private(set) var qrCodeImage: NSImage?

    @Published private(set) var isBusy: Bool = false
    @Published private(set) var feedbackMessage: String = "所有密钥仅保存在本机安全目录，绝不上传第三方服务器。"
    @Published private(set) var feedbackKind: SettingsFeedbackKind = .neutral

    let store: MindDockSettingsStore
    private let qrRegistrar: FeishuQRBotRegistrar
    private weak var dockViewModel: DockViewModel?
    private var qrPollingTask: Task<Void, Never>?

    init(
        store: MindDockSettingsStore,
        dockViewModel: DockViewModel,
        qrRegistrar: FeishuQRBotRegistrar = FeishuQRBotRegistrar()
    ) {
        self.store = store
        self.dockViewModel = dockViewModel
        self.qrRegistrar = qrRegistrar
        let loaded = store.load()
        self.draft = loaded
        self.selectedPreset = LLMProviderPreset.matching(baseURL: loaded.llmBaseURL) ?? .deepseek
        self.mobileSetupMode = Self.initialMobileMode(for: loaded)
    }

    private static func initialMobileMode(for settings: MindDockSettings) -> FeishuSetupMode {
        let hasApp = !settings.feishuAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWebhook = !settings.feishuWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasApp && hasWebhook {
            return .webhook
        }
        return .qrScan
    }

    var configFileDisplayPath: String {
        (store.configJSONURL.path as NSString).abbreviatingWithTildeInPath
    }

    var isFeishuAppBound: Bool {
        draft.mobileBridgeConfig?.hasAppBotCredentials == true
    }

    func prepareForOnboardingOpen() {
        draft = store.load()
        selectedPreset = LLMProviderPreset.matching(baseURL: draft.llmBaseURL) ?? .deepseek
        onboardingStep = 1
        step1FailedOnce = false
        feedbackKind = .neutral
        feedbackMessage = "第 1 步只需粘贴 1 个 API Key；也可以直接点左下角先离线体验。"
    }

    func reloadFromDisk() {
        draft = store.load()
        selectedPreset = LLMProviderPreset.matching(baseURL: draft.llmBaseURL) ?? .deepseek
        dockViewModel?.applySettings(draft)
        feedbackKind = .success
        feedbackMessage = "✓ 已从本地配置文件重新加载并立即生效。"
    }

    @discardableResult
    func saveAndApply(silent: Bool = false) -> Bool {
        do {
            try store.save(draft)
            dockViewModel?.applySettings(draft)
            if !silent {
                feedbackKind = .success
                feedbackMessage = "✓ 配置已安全保存并立即生效（无需重启）。"
            }
            return true
        } catch {
            feedbackKind = .error
            feedbackMessage = "保存配置失败：\(error.localizedDescription)"
            return false
        }
    }

    func selectProvider(_ preset: LLMProviderPreset) {
        selectedPreset = preset
        draft.llmBaseURL = preset.baseURL
        draft.llmModel = preset.defaultModel
        step1FailedOnce = false
    }

    func openSelectedProviderConsole() {
        NSWorkspace.shared.open(selectedPreset.apiKeyConsoleURL)
    }

    func openFeishuDeveloperConsole() {
        let trimmedAppId = draft.feishuAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = trimmedAppId.isEmpty
            ? "https://open.feishu.cn/app"
            : "https://open.feishu.cn/app/\(trimmedAppId)/auth"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyFeishuScopesJSON() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(FeishuQRBotRegistrar.manualPermissionScopesJSON, forType: .string)
        feedbackKind = .success
        feedbackMessage = "✓ 已复制飞书权限 JSON！在飞书后台「权限管理 → 批量导入/导出权限」粘贴即可一键开通。"
    }

    func skipOnboardingForOfflineUse() {
        stopFeishuQRPolling()
        draft.onboardingCompleted = true
        _ = saveAndApply(silent: true)
        dockViewModel?.statusBanner = "已开启本地模式 · 按 ⌥Space 随时闪投想法"
    }

    func completeOnboarding() {
        stopFeishuQRPolling()
        draft.onboardingCompleted = true
        _ = saveAndApply(silent: true)
        dockViewModel?.statusBanner = "🎉 配置已完成 · 按 ⌥Space 随时闪投"
    }

    func advanceToStep2WithoutVerification() {
        _ = saveAndApply(silent: true)
        onboardingStep = 2
        feedbackKind = .neutral
        feedbackMessage = "请选择下方最适合你的手机飞书连接方式（推荐直接扫码）。"
        if mobileSetupMode == .qrScan && !isFeishuAppBound {
            startFeishuQRRegistration()
        }
    }

    func verifyAndContinueToStep2() async {
        guard !isBusy else { return }
        guard saveAndApply(silent: true) else { return }

        let trimmedKey = draft.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            onboardingStep = 2
            feedbackKind = .neutral
            feedbackMessage = "暂未填写 API Key（将使用本地分道规则）。接下来可扫码绑定手机飞书。"
            if mobileSetupMode == .qrScan && !isFeishuAppBound {
                startFeishuQRRegistration()
            }
            return
        }

        guard let dockViewModel else { return }
        isBusy = true
        feedbackKind = .working
        feedbackMessage = "正在验证 \(selectedPreset.title) 接口连通性…"
        defer { isBusy = false }

        do {
            let summary = try await dockViewModel.testIntelligenceConnection()
            step1FailedOnce = false
            feedbackKind = .success
            feedbackMessage = "✓ AI 大脑验证成功（\(summary)）！下面扫码连接手机飞书。"
            onboardingStep = 2
            if mobileSetupMode == .qrScan && !isFeishuAppBound {
                startFeishuQRRegistration()
            }
        } catch {
            step1FailedOnce = true
            feedbackKind = .error
            feedbackMessage = "验证未通过：\(error.localizedDescription)"
        }
    }

    func setMobileSetupMode(_ mode: FeishuSetupMode) {
        guard mobileSetupMode != mode else { return }
        mobileSetupMode = mode
        if mode == .qrScan {
            if case .idle = qrState, !isFeishuAppBound {
                startFeishuQRRegistration()
            }
        } else {
            stopFeishuQRPolling()
        }
    }

    func startFeishuQRRegistration() {
        stopFeishuQRPolling()
        qrCodeImage = nil
        qrState = .loadingQR
        feedbackKind = .working
        feedbackMessage = "正在生成飞书一键创建二维码…"

        let registrar = self.qrRegistrar
        qrPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await registrar.beginRegistration()
                guard !Task.isCancelled else { return }

                self.qrCodeImage = QRCodeRenderer.makeQRCodeImage(
                    from: session.verificationURIComplete.absoluteString,
                    targetSide: 210
                )
                self.qrState = .waitingForScan(
                    qrURL: session.verificationURIComplete,
                    userCode: session.userCode,
                    isLarkDomain: false
                )
                self.feedbackKind = .neutral
                self.feedbackMessage = "请打开手机飞书【扫一扫】扫描上方二维码，点击确认创建…"

                for try await step in registrar.pollStream(for: session) {
                    guard !Task.isCancelled else { return }
                    switch step {
                    case .pending(let domain, _):
                        self.qrState = .waitingForScan(
                            qrURL: session.verificationURIComplete,
                            userCode: session.userCode,
                            isLarkDomain: domain == .lark
                        )
                    case .provisioned(let bot):
                        self.qrState = .bindingWelcome
                        self.feedbackKind = .working
                        self.feedbackMessage = "已扫码授权！正在自动绑定会话并发送欢迎卡片到手机飞书…"

                        self.draft = bot.applyingCredentials(to: self.draft)
                        _ = self.saveAndApply(silent: true)

                        do {
                            let completion = try await registrar.completeProvisioning(bot, baseSettings: self.draft)
                            self.draft = completion.settings
                            _ = self.saveAndApply(silent: true)
                            self.qrState = .boundSuccess(chatId: completion.bootstrap.chatId)
                            self.feedbackKind = .success
                            self.feedbackMessage = "🎉 绑定成功！看看手机飞书，已经收到欢迎卡片了！"
                        } catch {
                            self.qrState = .boundNeedsManualHi
                            self.feedbackKind = .success
                            self.feedbackMessage = "✓ 机器人密钥已自动保存！请在手机飞书打开刚创建的机器人发一句「你好」即可激活双向同步。"
                        }
                        self.qrPollingTask = nil
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.qrState = .failed(error.localizedDescription)
                self.feedbackKind = .error
                self.feedbackMessage = error.localizedDescription
            }
        }
    }

    func stopFeishuQRPolling() {
        qrPollingTask?.cancel()
        qrPollingTask = nil
    }

    func openCurrentQROnboardingInBrowser() {
        if case .waitingForScan(let qrURL, _, _) = qrState {
            NSWorkspace.shared.open(qrURL)
        }
    }

    func testLLMConnection() async {
        guard !isBusy else { return }
        guard saveAndApply(silent: true) else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "正在测试 AI 大脑连通性（\(draft.openAIConfiguration.model)）…"
        defer { isBusy = false }

        do {
            let summary = try await dockViewModel.testIntelligenceConnection()
            feedbackKind = .success
            feedbackMessage = "✓ AI 大脑已就绪 — \(summary)"
        } catch {
            feedbackKind = .error
            feedbackMessage = "AI 连接失败：\(error.localizedDescription)"
        }
    }

    func testLockScreenPush() async {
        guard !isBusy else { return }
        guard saveAndApply(silent: true) else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "正在向手机飞书发送测试卡片…"
        defer { isBusy = false }

        do {
            let result = try await dockViewModel.triggerTestMobilePush()
            feedbackKind = .success
            if result.usedSamplePreview {
                feedbackMessage = "🎉 已发送测试卡片到你的手机飞书！快打开手机看看通知吧。"
            } else {
                feedbackMessage = "✓ 已将当前 \(result.pushedBerthCount) 个「生活泊位」推送到你的手机锁屏。"
            }
        } catch {
            feedbackKind = .error
            feedbackMessage = "发送测试卡片失败：\(error.localizedDescription)"
        }
    }

    func syncMobileDropsNow() async {
        guard !isBusy else { return }
        guard saveAndApply(silent: true) else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "正在从手机飞书拉取最新闪投与办结回复…"
        defer { isBusy = false }

        if draft.mobileBridgeConfig == nil {
            feedbackKind = .error
            feedbackMessage = MobileBridgeError.unconfigured.localizedDescription
            return
        }

        if !(draft.mobileBridgeConfig?.hasAppBotCredentials ?? false) {
            feedbackKind = .neutral
            feedbackMessage = "当前为「单人群 Webhook」模式，支持离开电脑推锁屏；如需手机端发语音/文字双向同步，请切换到「飞书扫码一键创建」。"
            return
        }

        do {
            let report = try await dockViewModel.triggerManualMobileSync()
            feedbackKind = .success
            feedbackMessage = "✓ 同步完成：新接入 \(report.droppedItems.count) 条手机闪投，自动办结 \(report.resolvedItems.count) 个泊位。"
        } catch {
            feedbackKind = .error
            feedbackMessage = "手机同步失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Shared Clean Chinese Sections (Used by both Onboarding Wizard & Settings)

struct LLMSetupSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let showStandaloneTestButton: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("选择你常用的 AI 服务商")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    viewModel.openSelectedProviderConsole()
                } label: {
                    HStack(spacing: 3) {
                        Text("去官网获取 API Key ↗")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(.link)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(LLMProviderPreset.allCases, id: \.self) { preset in
                    let isSelected = viewModel.selectedPreset == preset
                    Button {
                        viewModel.selectProvider(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(preset.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10),
                                            lineWidth: isSelected ? 1.5 : 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("API Key（只需填这 1 个框）")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    if viewModel.revealLLMKey {
                        TextField("粘贴 sk-... 密钥（留空也可先离线使用）", text: $viewModel.draft.llmAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("粘贴 sk-... 密钥（留空也可先离线使用）", text: $viewModel.draft.llmAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealLLMKey.toggle()
                    } label: {
                        Image(systemName: viewModel.revealLLMKey ? "eye.slash" : "eye")
                            .frame(width: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(viewModel.revealLLMKey ? "隐藏密钥" : "显示密钥")

                    if showStandaloneTestButton {
                        Button {
                            Task { await viewModel.testLLMConnection() }
                        } label: {
                            Label("测试连通性", systemImage: "checkmark.seal")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .disabled(viewModel.isBusy)
                    }
                }
            }

            DisclosureGroup(
                "高级参数（已按所选服务商自动填好，一般无需改动）",
                isExpanded: $viewModel.showAdvancedLLM
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    settingsField("接口地址") {
                        TextField("https://api.deepseek.com/v1", text: $viewModel.draft.llmBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    settingsField("模型名称") {
                        TextField("deepseek-chat", text: $viewModel.draft.llmModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    settingsField("语音转写地址") {
                        TextField("可选云端 Whisper URL（默认使用 macOS 本地按需语音识别，无需填写）", text: $viewModel.draft.asrEndpointURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    settingsField("默认语音语言") {
                        Picker("", selection: $viewModel.draft.speechLocale) {
                            ForEach(SpeechLocale.allCases, id: \.self) { locale in
                                Text(locale.displayName).tag(locale)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func settingsField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            content()
        }
    }
}

struct MobileSetupSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(FeishuSetupMode.allCases) { mode in
                    let isSelected = viewModel.mobileSetupMode == mode
                    Button {
                        viewModel.setMobileSetupMode(mode)
                    } label: {
                        VStack(spacing: 2) {
                            Text(mode.tabTitle)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            if let badge = mode.badgeText {
                                Text(badge)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10),
                                            lineWidth: isSelected ? 1.5 : 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            switch viewModel.mobileSetupMode {
            case .qrScan:
                FeishuQRSetupPanelView(viewModel: viewModel)
            case .webhook:
                FeishuWebhookSetupPanelView(viewModel: viewModel)
            case .manualCredentials:
                FeishuManualSetupPanelView(viewModel: viewModel)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

private struct FeishuQRSetupPanelView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            qrVisualBox

            VStack(alignment: .leading, spacing: 9) {
                Text("手机飞书扫一扫，自动创建专属机器人")
                    .font(.system(size: 13.5, weight: .semibold))

                VStack(alignment: .leading, spacing: 4) {
                    Text("① 打开手机【飞书】右上角「扫一扫」，扫描左侧二维码")
                    Text("② 在手机上点击【确认创建】，无需手工复制任何密钥")
                    Text("③ 绑定瞬间手机会直接收到欢迎卡片，双向接力即刻就绪")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                qrLiveStatusBanner

                HStack(spacing: 10) {
                    Button {
                        viewModel.startFeishuQRRegistration()
                    } label: {
                        Label(
                            viewModel.qrCodeImage == nil && !viewModel.isFeishuAppBound ? "生成二维码" : "刷新二维码",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }

                    if case .waitingForScan = viewModel.qrState {
                        Button("在浏览器打开授权页 ↗") {
                            viewModel.openCurrentQROnboardingInBrowser()
                        }
                        .font(.system(size: 11.5))
                        .buttonStyle(.link)
                    }

                    if viewModel.isFeishuAppBound {
                        Button {
                            Task { await viewModel.testLockScreenPush() }
                        } label: {
                            Label("发条测试卡片", systemImage: "paperplane.fill")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .disabled(viewModel.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .onAppear {
            if case .idle = viewModel.qrState, !viewModel.isFeishuAppBound {
                viewModel.startFeishuQRRegistration()
            }
        }
    }

    @ViewBuilder
    private var qrVisualBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .frame(width: 176, height: 176)
                .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)

            switch viewModel.qrState {
            case .boundSuccess:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("已自动绑定")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                }
            case .loadingQR, .bindingWelcome:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.qrState == .bindingWelcome ? "正在绑定…" : "生成二维码…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.gray)
                }
            default:
                if let qrImage = viewModel.qrCodeImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 154, height: 154)
                } else if viewModel.isFeishuAppBound {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 34))
                            .foregroundStyle(.green)
                        Text("已连接飞书机器人")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                        Text(viewModel.draft.feishuAppId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    .padding(8)
                } else {
                    Button("点击生成二维码") {
                        viewModel.startFeishuQRRegistration()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var qrLiveStatusBanner: some View {
        switch viewModel.qrState {
        case .idle:
            if viewModel.isFeishuAppBound {
                Text("✓ 当前已绑定飞书应用（\(viewModel.draft.feishuAppId)），可随时重新扫码更换。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Text("点击「生成二维码」开始手机飞书扫码绑定。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        case .loadingQR:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在向飞书申请一键接入二维码…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        case .waitingForScan(_, _, let isLark):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(isLark
                     ? "已识别 Lark 国际版账号，请在手机上点击确认创建…"
                     : "请打开手机飞书【扫一扫】扫描上方二维码，点击确认创建…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.cyan)
            }
        case .bindingWelcome:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("授权成功！正在向手机飞书发送欢迎卡片并自动绑定会话…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.cyan)
            }
        case .boundSuccess:
            Text("🎉 绑定成功！看看手机飞书，已经收到欢迎卡片了！")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        case .boundNeedsManualHi:
            Text("✓ 机器人已自动创建并保存密钥！打开手机飞书给机器人发一句「你好」即可完成激活。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeishuWebhookSetupPanelView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("只需 3 步，下班锁屏自动把「生活泊位」推到手机通知栏：")
                    .font(.system(size: 12, weight: .semibold))
                Text("① 在飞书新建一个只有你自己的「1 人小群」")
                Text("② 点击群右上角「⋯ 设置」→「群机器人」→「添加机器人」→ 选择「自定义机器人」")
                Text("③ 复制生成的 Webhook 链接粘贴到下方输入框")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                if viewModel.revealWebhookURL {
                    TextField("https://open.feishu.cn/open-apis/bot/v2/hook/...", text: $viewModel.draft.feishuWebhookURL)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("粘贴飞书群机器人 Webhook 地址（https://open.feishu.cn/open-apis/bot/v2/hook/...）", text: $viewModel.draft.feishuWebhookURL)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    viewModel.revealWebhookURL.toggle()
                } label: {
                    Image(systemName: viewModel.revealWebhookURL ? "eye.slash" : "eye")
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .help(viewModel.revealWebhookURL ? "隐藏链接" : "显示链接")
            }

            HStack {
                Button {
                    Task { await viewModel.testLockScreenPush() }
                } label: {
                    Label("发条测试卡片到手机", systemImage: "paperplane.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FeishuManualSetupPanelView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("若所在企业禁用了个人扫码创建，可在飞书后台自建应用并一键粘贴权限 JSON：")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    viewModel.copyFeishuScopesJSON()
                } label: {
                    Text("📋 一键复制飞书权限 JSON")
                        .font(.system(size: 11.5, weight: .medium))
                }

                Button("打开飞书开发者后台 ↗") {
                    viewModel.openFeishuDeveloperConsole()
                }
                .font(.system(size: 11.5))
                .buttonStyle(.link)

                Spacer()
            }

            manualField("App ID") {
                TextField("cli_...", text: $viewModel.draft.feishuAppId)
                    .textFieldStyle(.roundedBorder)
            }

            manualField("App Secret") {
                HStack(spacing: 6) {
                    if viewModel.revealFeishuSecret {
                        TextField("飞书应用 App Secret", text: $viewModel.draft.feishuAppSecret)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("飞书应用 App Secret", text: $viewModel.draft.feishuAppSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealFeishuSecret.toggle()
                    } label: {
                        Image(systemName: viewModel.revealFeishuSecret ? "eye.slash" : "eye")
                            .frame(width: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(viewModel.revealFeishuSecret ? "隐藏密钥" : "显示密钥")
                }
            }

            DisclosureGroup(
                "高级项：指定会话 Chat ID（给机器人发一句消息即可自动发现，一般无需填写）",
                isExpanded: $viewModel.showAdvancedManualChatId
            ) {
                manualField("Chat ID") {
                    TextField("可选 oc_...", text: $viewModel.draft.feishuChatId)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.testLockScreenPush() }
                } label: {
                    Label("发条测试卡片到手机", systemImage: "paperplane.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)

                Button {
                    Task { await viewModel.syncMobileDropsNow() }
                } label: {
                    Label("立即同步手机消息", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func manualField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            content()
        }
    }
}

struct StatusFeedbackBannerView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var feedbackColor: Color {
        switch viewModel.feedbackKind {
        case .neutral: return .secondary
        case .working: return .cyan
        case .success: return .green
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(feedbackColor)
                    .frame(width: 8, height: 8)
            }

            Text(viewModel.feedbackMessage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(feedbackColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(feedbackColor.opacity(0.09))
        )
    }
}

// MARK: - 2-Step First-Run Onboarding Wizard View & Window

struct OnboardingWizardView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wizardHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.onboardingStep == 1 {
                        step1Description
                        LLMSetupSectionView(viewModel: viewModel, showStandaloneTestButton: false)
                    } else {
                        step2Description
                        MobileSetupSectionView(viewModel: viewModel)
                    }
                }
                .padding(.trailing, 2)
            }

            StatusFeedbackBannerView(viewModel: viewModel)
            wizardFooter
        }
        .padding(20)
        .frame(width: 620, height: 550)
        .onDisappear {
            viewModel.stopFeishuQRPolling()
        }
    }

    private var wizardHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.onboardingStep == 1
                     ? "欢迎使用 MindDock · 第 1 步：配置 AI 大脑"
                     : "欢迎使用 MindDock · 第 2 步：连接手机飞书")
                    .font(.system(size: 17, weight: .semibold))
                Text("工作与生活自动换场 · 台面永远只留 3 个泊位，其余交给后台备料与深海打捞")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                stepBadge(number: 1, title: "AI 大脑", active: viewModel.onboardingStep == 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                stepBadge(number: 2, title: "手机飞书", active: viewModel.onboardingStep == 2)
            }
        }
    }

    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 17, height: 17)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.22), in: Circle())
                .foregroundStyle(active ? Color.white : Color.secondary)
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(active ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private var step1Description: some View {
        Text("配置 AI 后，随手闪投的一句话会自动区分「工作 / 生活」并在后台备好下一步行动提示；语音闪投默认使用 macOS 本地按需识别（平时零麦克风占用）。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var step2Description: some View {
        Text("无需公网服务器：Mac 锁屏或合盖自动把「生活泊位」推到手机锁屏；在外对飞书机器人发语音或文字，回工位自动上台。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var wizardFooter: some View {
        HStack(spacing: 10) {
            if viewModel.onboardingStep == 1 {
                Button("跳过，先离线使用") {
                    viewModel.skipOnboardingForOfflineUse()
                    onFinish()
                }
                .disabled(viewModel.isBusy)

                Spacer()

                if viewModel.step1FailedOnce {
                    Button("暂跳过验证，去下一步 →") {
                        viewModel.advanceToStep2WithoutVerification()
                    }
                    .disabled(viewModel.isBusy)
                }

                Button {
                    Task { await viewModel.verifyAndContinueToStep2() }
                } label: {
                    Text("验证并继续 →")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            } else {
                Button("← 上一步") {
                    viewModel.stopFeishuQRPolling()
                    viewModel.onboardingStep = 1
                }
                .disabled(viewModel.isBusy)

                Button("稍后再连，先开始使用") {
                    viewModel.completeOnboarding()
                    onFinish()
                }
                .disabled(viewModel.isBusy)

                Spacer()

                Button {
                    viewModel.completeOnboarding()
                    onFinish()
                } label: {
                    Text("完成配置，开始使用")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }
        }
    }
}

// MARK: - Full Settings View & Windows

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onOpenOnboarding: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI 备料与打捞大脑", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                        LLMSetupSectionView(viewModel: viewModel, showStandaloneTestButton: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("手机飞书锁屏推送与双向同步", systemImage: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if viewModel.isFeishuAppBound {
                                Button {
                                    Task { await viewModel.syncMobileDropsNow() }
                                } label: {
                                    Label("立即同步手机闪投", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .controlSize(.small)
                                .disabled(viewModel.isBusy)
                            }
                        }
                        MobileSetupSectionView(viewModel: viewModel)
                    }
                }
                .padding(.trailing, 4)
            }

            StatusFeedbackBannerView(viewModel: viewModel)
            bottomActionBar
        }
        .padding(18)
        .frame(width: 620, height: 640)
        .onDisappear {
            viewModel.stopFeishuQRPolling()
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MindDock 设置与手机连接")
                    .font(.system(size: 16, weight: .semibold))
                Text("配置文件保存在 \(viewModel.configFileDisplayPath)（本机私密存储）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onOpenOnboarding()
            } label: {
                Label("新手配置向导…", systemImage: "wand.and.stars")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .disabled(viewModel.isBusy)

            Button {
                viewModel.reloadFromDisk()
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .disabled(viewModel.isBusy)
            .help("重新读取 ~/.config/minddock/ 下的配置文件")
        }
    }

    private var bottomActionBar: some View {
        HStack {
            Button("关闭") {
                viewModel.stopFeishuQRPolling()
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                _ = viewModel.saveAndApply()
            } label: {
                Text("保存并立即生效")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(viewModel.isBusy)
        }
    }
}

@MainActor
final class OnboardingWizardWindow: NSWindow {
    var onWindowWillClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        let rect = NSRect(x: 0, y: 0, width: 620, height: 550)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "MindDock · 新手配置向导"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = rect
        contentView = hosting
        center()
    }

    override func close() {
        onWindowWillClose?()
        super.close()
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    var onWindowWillClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        let rect = NSRect(x: 0, y: 0, width: 620, height: 640)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "MindDock · 设置与手机连接"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = rect
        contentView = hosting
        center()
    }

    override func close() {
        onWindowWillClose?()
        super.close()
    }
}
