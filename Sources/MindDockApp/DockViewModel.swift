import Combine
import Foundation
import MindDockCore
import SwiftUI

public enum DropLaneChoice: String, CaseIterable, Sendable {
    case auto
    case work
    case life

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .work: return "Work"
        case .life: return "Life"
        }
    }
}

public enum QuickBarMode: String, CaseIterable, Sendable {
    case drop
    case recall

    public var label: String {
        switch self {
        case .drop: return "Drop"
        case .recall: return "Recall"
        }
    }
}

@MainActor
final class DockViewModel: ObservableObject {
    let engine: DockEngine
    let voiceController: VoiceCaptureController

    @Published private(set) var snapshot: DockSnapshot
    @Published var statusBanner: String?
    @Published var draftText: String = ""
    @Published var dropLaneChoice: DropLaneChoice = .auto

    @Published var quickBarMode: QuickBarMode = .drop
    @Published var recallQuery: String = ""
    @Published private(set) var recallResults: [DockItem] = []
    @Published private(set) var isRecalling: Bool = false

    private var cancellables = Set<AnyCancellable>()
    var onStateChanged: (() -> Void)?

    init(
        engine: DockEngine,
        voiceController: VoiceCaptureController? = nil
    ) throws {
        self.engine = engine
        self.voiceController = voiceController ?? VoiceCaptureController(
            intelligenceClient: engine.intelligenceClient,
            hasASRFallbackEndpoint: (engine.intelligenceClient as? OpenAICompatibleIntelligenceClient)?.configuration.asrEndpointURL != nil
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
            statusBanner = "Storage error: \(error)"
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

    func toggleVoiceCapture() {
        voiceController.toggleCapture(currentDraft: draftText) { [weak self] updatedText in
            self?.draftText = updatedText
        }
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
                statusBanner = "Dropped to \(item.lane.rawValue.capitalized) off-stage · Prep running"
            } else if item.status == .queued {
                statusBanner = "3 Berths full — queued off-stage (FIFO)"
            } else {
                statusBanner = "Docked in \(item.lane.rawValue.capitalized) Berth"
            }
            onStateChanged?()
            return true
        } catch {
            statusBanner = "Drop failed: \(error)"
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
            statusBanner = "Recall failed: \(error)"
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
                statusBanner = "Resurfaced to \(item.lane.rawValue.capitalized) Berth"
            } else {
                statusBanner = "3 Berths full — resurfaced into \(item.lane.rawValue.capitalized) queue"
            }
            onStateChanged?()
            return item
        } catch {
            statusBanner = "Resurface failed: \(error)"
            return nil
        }
    }

    func shift(to lane: Lane) {
        do {
            snapshot = try engine.shift(to: lane)
            statusBanner = "Shifted Dock to \(lane.rawValue.capitalized)"
            onStateChanged?()
            let engineRef = self.engine
            Task { [weak self] in
                do {
                    let result = try await engineRef.shiftAndSync(to: lane)
                    await MainActor.run {
                        guard let self else { return }
                        self.snapshot = result.snapshot
                        if result.pushedLifeDock {
                            self.statusBanner = "Shifted to Life · Pushed to mobile lock screen"
                        } else if let report = result.syncReport,
                                  (!report.droppedItems.isEmpty || !report.resolvedItems.isEmpty) {
                            self.statusBanner = "Synced \(report.droppedItems.count) mobile Drop(s), \(report.resolvedItems.count) resolved"
                        }
                        self.onStateChanged?()
                    }
                } catch {
                    await MainActor.run {
                        self?.statusBanner = "Mobile bridge error: \(error)"
                    }
                }
            }
        } catch {
            statusBanner = "Shift failed: \(error)"
        }
    }

    func handleSystemDeparture() {
        shift(to: .life)
    }

    func handleSystemArrival() {
        shift(to: .work)
    }

    func syncMobileBridgeInBackground(manual: Bool = false) {
        let engineRef = self.engine
        Task { [weak self] in
            do {
                let report = try await engineRef.syncMobileBridge()
                await MainActor.run {
                    guard let self else { return }
                    if let updated = try? self.engine.getDock() {
                        self.snapshot = updated
                    }
                    if !report.droppedItems.isEmpty || !report.resolvedItems.isEmpty {
                        self.statusBanner = "Synced \(report.droppedItems.count) mobile Drop(s), \(report.resolvedItems.count) resolved"
                    } else if manual {
                        self.statusBanner = "Mobile bridge up to date"
                    }
                    self.onStateChanged?()
                }
            } catch {
                if manual {
                    await MainActor.run {
                        self?.statusBanner = "Mobile sync failed: \(error)"
                    }
                }
            }
        }
    }

    func resolve(id: String) {
        do {
            let result = try engine.resolveBerth(id: id)
            snapshot = try engine.getDock()
            if result.promotedItem != nil {
                statusBanner = "Sunk to Deep · Promoted oldest queued item"
            } else {
                statusBanner = "Sunk to Deep · Berth freed"
            }
            onStateChanged?()
        } catch {
            statusBanner = "Resolve failed: \(error)"
        }
    }

    func flipLane(id: String) {
        do {
            let updated = try engine.reclassify(id: id, to: .flipLane)
            snapshot = try engine.getDock()
            let placement = updated.status == .docked ? "Berth" : "queue"
            statusBanner = "Moved to \(updated.lane.rawValue.capitalized) \(placement)"
            onStateChanged?()
        } catch {
            statusBanner = "Flip failed: \(error)"
        }
    }

    func sinkToDeep(id: String) {
        do {
            _ = try engine.reclassify(id: id, to: .deep)
            snapshot = try engine.getDock()
            statusBanner = "Sunk straight to Deep"
            onStateChanged?()
        } catch {
            statusBanner = "Sink failed: \(error)"
        }
    }

    func cycleDropLaneChoice() {
        let all = DropLaneChoice.allCases
        if let idx = all.firstIndex(of: dropLaneChoice) {
            dropLaneChoice = all[(idx + 1) % all.count]
        }
    }
}
