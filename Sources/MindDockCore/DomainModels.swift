import Foundation

public enum Lane: String, Codable, CaseIterable, Sendable, Equatable {
    case work
    case life

    public var opposite: Lane {
        self == .work ? .life : .work
    }
}

public enum ItemStatus: String, Codable, Sendable, Equatable {
    case docked
    case queued
    case deep
}

public enum PrepState: String, Codable, Sendable, Equatable {
    case pending
    case ready
    case skipped
}

public enum SpeechLocale: String, Codable, CaseIterable, Sendable, Equatable {
    case zhCN = "zh-CN"
    case enUS = "en-US"

    public var shortLabel: String {
        switch self {
        case .zhCN: return "中"
        case .enUS: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhCN: return "中文 (zh-CN)"
        case .enUS: return "English (en-US)"
        }
    }

    public var fallbackLocale: SpeechLocale {
        self == .zhCN ? .enUS : .zhCN
    }
}

public struct DockItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let raw: String
    public let lane: Lane
    public let status: ItemStatus
    public let prep: String?
    public let prepState: PrepState
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        raw: String,
        lane: Lane,
        status: ItemStatus,
        prep: String? = nil,
        prepState: PrepState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.raw = raw
        self.lane = lane
        self.status = status
        self.prep = prep
        self.prepState = prepState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DockSnapshot: Sendable, Equatable {
    public let activeLane: Lane
    public let lane: Lane
    public let berths: [DockItem]
    public let queuedCount: Int
    public let offstageCount: Int
    public let deepCount: Int

    public init(
        activeLane: Lane,
        lane: Lane,
        berths: [DockItem],
        queuedCount: Int,
        offstageCount: Int,
        deepCount: Int
    ) {
        self.activeLane = activeLane
        self.lane = lane
        self.berths = berths
        self.queuedCount = queuedCount
        self.offstageCount = offstageCount
        self.deepCount = deepCount
    }
}

public struct ResolveResult: Sendable, Equatable {
    public let sunkItem: DockItem
    public let promotedItem: DockItem?

    public init(sunkItem: DockItem, promotedItem: DockItem?) {
        self.sunkItem = sunkItem
        self.promotedItem = promotedItem
    }
}

public enum ReclassifyTarget: Sendable, Equatable {
    case lane(Lane)
    case flipLane
    case deep
}

public enum DockError: Error, Sendable, Equatable {
    case emptyDrop
    case itemNotFound(String)
    case storageFailure(String)
}
