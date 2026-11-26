import Combine
import Foundation
import MindDockCore
import SwiftUI

enum DropLaneChoice: String, CaseIterable, Sendable {
    case auto
    case work
    case life

    var label: String {
        switch self {
        case .auto: return "自动分道"
        case .work: return "工作"
        case .life: return "生活"
        }
    }
}

enum QuickBarMode: String, CaseIterable, Sendable {
    case drop
    case recall

    var label: String {
        switch self {
        case .drop: return "闪投"
        case .recall: return "打捞"
        }
    }
}

@MainActor
final class DockViewModel: ObservableObject {
    let engine: DockEngine
    let voiceController: VoiceCaptureController
    let settingsStore: MindDockSettingsStore

    @Published private(set) var snapshot: DockSnapshot
    @Published var statusBanner: String?
    @Published var draftText: String = ""
    @Published var dropLaneChoice: DropLaneChoice = .auto
    @Published private(set) var speechLocale: SpeechLocale

    @Published var quickBarMode: QuickBarMode = .drop
    @Published var recallQuery: String = ""
    @Published private(set) var recallResults: [DockItem] = []
    @Published private(set) var isRecalling: Bool = false

    private var cancellables = Set<AnyCancellable>()
    var onStateChanged: (() -> Void)?

    init(
        engine: DockEngine,
        voiceController: VoiceCaptureController? = nil,
        settingsStore: MindDockSettingsStore = MindDockSettingsStore(),
        initialSettings: MindDockSettings? = nil
    ) throws {
        let resolvedSettings = initialSettings ?? settingsStore.load()
        self.engine = engine
        self.settingsStore = settingsStore
        self.speechLocale = resolvedSettings.speechLocale
        self.voiceController = voiceController ?? VoiceCaptureController(
            intelligenceClient: engine.intelligenceClient,
            hasASRFallbackEndpoint: engine.intelligenceClient.hasAudioTranscriptionEndpoint,
            speechLocale: resolvedSettings.speechLocale
        )
        self.snapshot = try engine.getDock()

        self.voiceController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        engine.onDockChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    var predictedLaneForDraft: Lane {
        switch dropLaneChoice {
        case .work:
            return .work
        case .life:
            return .life
        case .auto:
            let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return snapshot.activeLane
            }
            return DockEngine.inferLaneLocally(for: draftText)
        }
    }

    func refresh() {
        do {
            snapshot = try engine.getDock()
            onStateChanged?()
        } catch {
            statusBanner = "本地存储异常：\(error.localizedDescription)"
        }
    }

    func setQuickBarMode(_ mode: QuickBarMode) {
        if mode != .drop {
            stopVoiceCapture()
        }
        quickBarMode = mode
        if mode == .recall && recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recallResults = (try? Array(engine.deepItems().prefix(5))) ?? []
        }
    }

    func beginVoiceMicPress() {
        voiceController.beginMicPress(currentDraft: draftText) { [weak self] updatedText in
            self?.draftText = updatedText
        }
    }

    func endVoiceMicPress() {
        voiceController.endMicPress()
    }

    func toggleVoiceCapture() {
        voiceController.toggleCapture(currentDraft: draftText) { [weak self] updatedText in
            self?.draftText = updatedText
        }
    }

    func setSpeechLocale(_ locale: SpeechLocale) {
        guard speechLocale != locale else { return }
        speechLocale = locale
        voiceController.speechLocale = locale
        var currentSettings = settingsStore.load()
        currentSettings.speechLocale = locale
        try? settingsStore.save(currentSettings)
        let adapters = MindDockRuntimeAdapters.make(from: currentSettings)
        engine.applyAdapters(adapters)
        voiceController.updateIntelligenceClient(
            adapters.intelligenceClient,
            hasASRFallbackEndpoint: adapters.intelligenceClient.hasAudioTranscriptionEndpoint,
            speechLocale: locale
        )
        onStateChanged?()
    }

    func stopVoiceCapture() {
        voiceController.stopCapture(finalizeWithASRIfNeeded: false)
    }

    func cancelQuickBarSession() {
        voiceController.cancelCapture()
    }

    @discardableResult
    func submitDraftDrop() -> Bool {
        stopVoiceCapture()

        let raw = draftText
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let explicitLane: Lane?
        switch dropLaneChoice {
        case .auto: explicitLane = nil
        case .work: explicitLane = .work
        case .life: explicitLane = .life
        }

        do {
            let item = try engine.drop(raw, lane: explicitLane)
            draftText = ""
            dropLaneChoice = .auto
            snapshot = try engine.getDock()
            if item.lane != snapshot.activeLane {
                statusBanner = "已闪投至\(item.lane.displayTitle)后台 · AI 正在备料"
            } else if item.status == .queued {
                statusBanner = "3 个泊位已满 · 已排入候补队列（先进先出）"
            } else {
                statusBanner = "已停靠至\(item.lane.dockTitle)"
            }
            onStateChanged?()
            return true
        } catch {
            statusBanner = "闪投失败：\(error.localizedDescription)"
            return false
        }
    }

    func performRecall() async {
        let trimmed = recallQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            recallResults = (try? Array(engine.deepItems().prefix(5))) ?? []
            isRecalling = false
            return
        }

        isRecalling = true
        defer { isRecalling = false }
        do {
            recallResults = try await engine.recall(query: trimmed)
        } catch {
            statusBanner = "打捞失败：\(error.localizedDescription)"
            recallResults = []
        }
    }

    @discardableResult
    func resurfaceFromRecall(id: String) -> DockItem? {
        do {
            let item = try engine.resurface(id: id)
            recallResults.removeAll { $0.id == id }
            snapshot = try engine.getDock()
            if item.status == .docked {
                statusBanner = "已捞回\(item.lane.dockTitle)泊位"
            } else {
                statusBanner = "3 个泊位已满 · 已捞回\(item.lane.displayTitle)候补队列"
            }
            onStateChanged?()
            return item
        } catch {
            statusBanner = "捞回失败：\(error.localizedDescription)"
            return nil
        }
    }

    func shift(to lane: Lane) {
        do {
            snapshot = try engine.shift(to: lane)
            statusBanner = "已换场至\(lane.dockTitle)"
            onStateChanged?()
            let engineRef = self.engine
            Task { [weak self] in
                do {
                    let result = try await engineRef.shiftAndSync(to: lane)
                    await MainActor.run {
                        guard let self else { return }
                        self.snapshot = result.snapshot
                        if result.pushedLifeDock {
                            self.statusBanner = "已换场至生活 · 锁屏卡片已推送到手机飞书"
                        } else if let report = result.syncReport,
                                  (!report.droppedItems.isEmpty || !report.resolvedItems.isEmpty) {
                            self.statusBanner = "已同步手机飞书：新接入 \(report.droppedItems.count) 条闪投，办结 \(report.resolvedItems.count) 项"
                        }
                        self.onStateChanged?()
                    }
                } catch {
                    await MainActor.run {
                        self?.statusBanner = "手机飞书提示：\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            statusBanner = "换场失败：\(error.localizedDescription)"
        }
    }

    func handleSystemDeparture() {
        shift(to: .life)
    }

    func handleSystemArrival() {
        shift(to: .work)
    }

    func applySettings(_ settings: MindDockSettings) {
        speechLocale = settings.speechLocale
        let adapters = MindDockRuntimeAdapters.make(from: settings)
        engine.applyAdapters(adapters)
        voiceController.updateIntelligenceClient(
            adapters.intelligenceClient,
            hasASRFallbackEndpoint: adapters.intelligenceClient.hasAudioTranscriptionEndpoint,
            speechLocale: settings.speechLocale
        )
        statusBanner = "配置已保存并即时生效"
        onStateChanged?()
    }

    func testIntelligenceConnection() async throws -> String {
        try await engine.testIntelligenceConnection()
    }

    func triggerTestMobilePush() async throws -> MobilePushTestResult {
        let result = try await engine.testMobilePush()
        if result.usedSamplePreview {
            statusBanner = "已向手机飞书发送锁屏预览卡片"
        } else {
            statusBanner = "已推送 \(result.pushedBerthCount) 个生活泊位到手机锁屏"
        }
        onStateChanged?()
        return result
    }

    func triggerManualMobileSync() async throws -> MobileSyncReport {
        let report = try await engine.syncMobileBridge()
        if let updated = try? engine.getDock() {
            snapshot = updated
        }
        if !report.droppedItems.isEmpty || !report.resolvedItems.isEmpty {
            statusBanner = "已同步手机飞书：新增 \(report.droppedItems.count) 条闪投，办结 \(report.resolvedItems.count) 项"
        } else {
            statusBanner = "手机飞书已是最新状态"
        }
        onStateChanged?()
        return report
    }

    func syncMobileBridgeInBackground(manual: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if manual {
                    _ = try await self.triggerManualMobileSync()
                } else {
                    let report = try await self.engine.syncMobileBridge()
                    if let updated = try? self.engine.getDock() {
                        self.snapshot = updated
                    }
                    if !report.droppedItems.isEmpty || !report.resolvedItems.isEmpty {
                        self.statusBanner = "已同步手机飞书：新增 \(report.droppedItems.count) 条闪投，办结 \(report.resolvedItems.count) 项"
                    }
                    self.onStateChanged?()
                }
            } catch {
                if manual {
                    self.statusBanner = "手机同步失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func resolve(id: String) {
        do {
            let result = try engine.resolveBerth(id: id)
            snapshot = try engine.getDock()
            if result.promotedItem != nil {
                statusBanner = "✓ 已办结沉入深海 · 候补首项已自动递补"
            } else {
                statusBanner = "✓ 已办结沉入深海 · 泊位已留白"
            }
            onStateChanged?()
        } catch {
            statusBanner = "办结失败：\(error.localizedDescription)"
        }
    }

    func flipLane(id: String) {
        do {
            let updated = try engine.reclassify(id: id, to: .flipLane)
            snapshot = try engine.getDock()
            let placement = updated.status == .docked ? "泊位" : "候补队列"
            statusBanner = "已切到\(updated.lane.displayTitle)\(placement)"
            onStateChanged?()
        } catch {
            statusBanner = "切换分道失败：\(error.localizedDescription)"
        }
    }

    func sinkToDeep(id: String) {
        do {
            _ = try engine.reclassify(id: id, to: .deep)
            snapshot = try engine.getDock()
            statusBanner = "已沉入深海留存"
            onStateChanged?()
        } catch {
            statusBanner = "沉底失败：\(error.localizedDescription)"
        }
    }

    func cycleDropLaneChoice() {
        let all = DropLaneChoice.allCases
        if let idx = all.firstIndex(of: dropLaneChoice) {
            dropLaneChoice = all[(idx + 1) % all.count]
        }
    }
}
