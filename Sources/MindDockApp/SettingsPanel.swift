import AppKit
import Foundation
import MindDockCore
import SwiftUI

enum SettingsFeedbackKind: Equatable {
    case neutral
    case working
    case success
    case error
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var draft: MindDockSettings
    @Published var revealLLMKey: Bool = false
    @Published var revealFeishuSecret: Bool = false
    @Published var revealWebhookURL: Bool = false

    @Published private(set) var isBusy: Bool = false
    @Published private(set) var feedbackMessage: String = "Credentials are stored locally at 0600 permissions and never logged."
    @Published private(set) var feedbackKind: SettingsFeedbackKind = .neutral

    let store: MindDockSettingsStore
    private weak var dockViewModel: DockViewModel?

    init(store: MindDockSettingsStore, dockViewModel: DockViewModel) {
        self.store = store
        self.dockViewModel = dockViewModel
        self.draft = store.load()
    }

    var configFileDisplayPath: String {
        (store.configJSONURL.path as NSString).abbreviatingWithTildeInPath
    }

    var dotEnvDisplayPath: String {
        (store.primaryDotEnvURL.path as NSString).abbreviatingWithTildeInPath
    }

    func reloadFromDisk() {
        draft = store.load()
        dockViewModel?.applySettings(draft)
        feedbackKind = .success
        feedbackMessage = "Reloaded configuration from \(configFileDisplayPath) & \(dotEnvDisplayPath) and applied live."
    }

    @discardableResult
    func saveAndApply() -> Bool {
        do {
            try store.save(draft)
            dockViewModel?.applySettings(draft)
            feedbackKind = .success
            feedbackMessage = "Saved (0600 permissions) and hot-reloaded into MindDock without restart."
            return true
        } catch {
            feedbackKind = .error
            feedbackMessage = "Failed to save settings: \(error.localizedDescription)"
            return false
        }
    }

    func applyPreset(baseURL: String, model: String) {
        draft.llmBaseURL = baseURL
        draft.llmModel = model
    }

    func testLLMConnection() async {
        guard !isBusy else { return }
        guard saveAndApply() else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "Testing OpenAI-compatible chat completion (\(draft.openAIConfiguration.model))…"
        defer { isBusy = false }

        do {
            let summary = try await dockViewModel.testIntelligenceConnection()
            feedbackKind = .success
            feedbackMessage = "✓ LLM ready — \(summary)"
        } catch {
            feedbackKind = .error
            feedbackMessage = "LLM connection failed: \(error.localizedDescription)"
        }
    }

    func testLockScreenPush() async {
        guard !isBusy else { return }
        guard saveAndApply() else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "Sending lock-screen push to mobile bridge…"
        defer { isBusy = false }

        do {
            let result = try await dockViewModel.triggerTestMobilePush()
            feedbackKind = .success
            if result.usedSamplePreview {
                feedbackMessage = "✓ Sent sample test card to your phone! Check Feishu / webhook notification."
            } else {
                feedbackMessage = "✓ Pushed \(result.pushedBerthCount) active Life Berth(s) to your phone lock screen."
            }
        } catch {
            feedbackKind = .error
            feedbackMessage = "Lock-screen push failed: \(error.localizedDescription)"
        }
    }

    func syncMobileDropsNow() async {
        guard !isBusy else { return }
        guard saveAndApply() else { return }
        guard let dockViewModel else { return }

        isBusy = true
        feedbackKind = .working
        feedbackMessage = "Pulling unread messages & completion replies from Feishu…"
        defer { isBusy = false }

        if draft.mobileBridgeConfig == nil {
            feedbackKind = .error
            feedbackMessage = MobileBridgeError.unconfigured.localizedDescription
            return
        }

        if !(draft.mobileBridgeConfig?.hasAppBotCredentials ?? false) {
            feedbackKind = .neutral
            feedbackMessage = "Webhook-only mode supports outbound lock-screen push. Add Feishu App ID + Secret for two-way mobile Drops."
            return
        }

        do {
            let report = try await dockViewModel.triggerManualMobileSync()
            feedbackKind = .success
            feedbackMessage = "✓ Sync complete: \(report.droppedItems.count) mobile Drop(s) docked, \(report.resolvedItems.count) Berth(s) resolved."
        } catch {
            feedbackKind = .error
            feedbackMessage = "Mobile sync failed: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onClose: () -> Void

    private var feedbackColor: Color {
        switch viewModel.feedbackKind {
        case .neutral: return .secondary
        case .working: return .cyan
        case .success: return .green
        case .error: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    llmSection
                    mobileBridgeSection
                }
                .padding(.trailing, 4)
            }

            statusFeedbackBox
            bottomActionRow
        }
        .padding(18)
        .frame(width: 580, height: 610)
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MindDock Settings & Mobile Setup")
                    .font(.system(size: 16, weight: .semibold))
                Text("Synced with \(viewModel.configFileDisplayPath) & ./scripts/setup-wizard.sh (0600 mode)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.reloadFromDisk()
            } label: {
                Label("Reload Disk", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .disabled(viewModel.isBusy)
            .help("Reload ~/.config/minddock/.env & config.json after running scripts/setup-wizard.sh")
        }
    }

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Intelligence (Prep & Recall — OpenAI-Compatible)", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                HStack(spacing: 5) {
                    Text("Presets:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    presetButton("DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
                    presetButton("OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
                    presetButton("SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3")
                }
            }

            labeledField("Base URL") {
                TextField("https://api.deepseek.com/v1", text: $viewModel.draft.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("API Key") {
                HStack(spacing: 6) {
                    if viewModel.revealLLMKey {
                        TextField("sk-...", text: $viewModel.draft.llmAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-... (leave blank for local offline rules)", text: $viewModel.draft.llmAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealLLMKey.toggle()
                    } label: {
                        Image(systemName: viewModel.revealLLMKey ? "eye.slash" : "eye")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(viewModel.revealLLMKey ? "Hide API Key" : "Reveal API Key")
                }
            }

            labeledField("Model") {
                TextField("deepseek-chat", text: $viewModel.draft.llmModel)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("ASR URL") {
                TextField("Optional cloud Whisper URL (macOS Speech works locally by default)", text: $viewModel.draft.asrEndpointURL)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("Speech") {
                Picker("", selection: $viewModel.draft.speechLocale) {
                    ForEach(SpeechLocale.allCases, id: \.self) { locale in
                        Text(locale.displayName).tag(locale)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack {
                Text("Voice Drops use on-demand macOS Speech Recognition by default (0% idle CPU, no permanent mic dot).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.testLLMConnection() }
                } label: {
                    Label("Test LLM", systemImage: "checkmark.seal")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private var mobileBridgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mobile Lock-Screen & Mailbox Bridge (Zero-Server Feishu / Webhook)", systemImage: "iphone.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))

            Text("Option A (Recommended — Two-Way 24h Sync): Feishu Self-Built App Bot pushes Life Berths on lock/sleep AND pulls off-desk voice/text Drops & 'done 1' replies on wake.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledField("App ID") {
                TextField("cli_...", text: $viewModel.draft.feishuAppId)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("App Secret") {
                HStack(spacing: 6) {
                    if viewModel.revealFeishuSecret {
                        TextField("Feishu App Secret", text: $viewModel.draft.feishuAppSecret)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Feishu App Secret", text: $viewModel.draft.feishuAppSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealFeishuSecret.toggle()
                    } label: {
                        Image(systemName: viewModel.revealFeishuSecret ? "eye.slash" : "eye")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(viewModel.revealFeishuSecret ? "Hide App Secret" : "Reveal App Secret")
                }
            }

            labeledField("Chat ID") {
                TextField("Optional oc_... (auto-discovered once you message your bot)", text: $viewModel.draft.feishuChatId)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            Text("Option B (1-Line Outbound Only): Feishu Group Bot Webhook, ServerChan, or generic JSON webhook URL for lock-screen notifications.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            labeledField("Webhook") {
                HStack(spacing: 6) {
                    if viewModel.revealWebhookURL {
                        TextField("https://open.feishu.cn/open-apis/bot/v2/hook/...", text: $viewModel.draft.feishuWebhookURL)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("https://open.feishu.cn/open-apis/bot/v2/hook/... (optional)", text: $viewModel.draft.feishuWebhookURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealWebhookURL.toggle()
                    } label: {
                        Image(systemName: viewModel.revealWebhookURL ? "eye.slash" : "eye")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.testLockScreenPush() }
                } label: {
                    Label("Test Lock-Screen Push", systemImage: "paperplane.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)

                Button {
                    Task { await viewModel.syncMobileDropsNow() }
                } label: {
                    Label("Sync Mobile Drops Now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .disabled(viewModel.isBusy)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private var statusFeedbackBox: some View {
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
                .fill(feedbackColor.opacity(0.08))
        )
    }

    private var bottomActionRow: some View {
        HStack {
            Button("Close") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                _ = viewModel.saveAndApply()
            } label: {
                Text("Save & Apply Live")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(viewModel.isBusy)
        }
    }

    private func presetButton(_ title: String, baseURL: String, model: String) -> some View {
        Button(title) {
            viewModel.applyPreset(baseURL: baseURL, model: model)
        }
        .controlSize(.mini)
        .buttonStyle(.bordered)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            content()
        }
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        let rect = NSRect(x: 0, y: 0, width: 580, height: 610)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "MindDock Settings & Mobile Setup"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = rect
        contentView = hosting
        center()
    }
}
