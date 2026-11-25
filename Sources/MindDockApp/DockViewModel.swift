import Foundation
import SwiftUI
import MindDockCore

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

@MainActor
final class DockViewModel: ObservableObject {
    let engine: DockEngine

    @Published private(set) var snapshot: DockSnapshot
    @Published var statusBanner: String?
    @Published var draftText: String = ""
    @Published var dropLaneChoice: DropLaneChoice = .auto

    var onStateChanged: (() -> Void)?

    init(engine: DockEngine) throws {
        self.engine = engine
        self.snapshot = try engine.getDock()
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

    @discardableResult
    func submitDraftDrop() -> Bool {
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
                statusBanner = "Dropped to \(item.lane.rawValue.capitalized) off-stage"
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

    func shift(to lane: Lane) {
        do {
            snapshot = try engine.shift(to: lane)
            statusBanner = "Shifted Dock to \(lane.rawValue.capitalized)"
            onStateChanged?()
        } catch {
            statusBanner = "Shift failed: \(error)"
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
