import AVFoundation
import Combine
import Foundation
import Speech

public protocol VoiceCaptureSessionDriver: Sendable {
    var isHardwareActive: Bool { get }
    func start(
        locale: SpeechLocale,
        recordFallbackFile: Bool,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws
    func stop() -> URL?
}

public enum VoiceCaptureError: Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case hardwareUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg), .hardwareUnavailable(let msg):
            return msg
        }
    }
}

public final class NativeSpeechCaptureDriver: VoiceCaptureSessionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var recordedFileURL: URL?
    private var hasInstalledTap = false

    public init() {}

    public var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasInstalledTap || (audioEngine?.isRunning ?? false) || audioEngine != nil
    }

    public func start(
        locale: SpeechLocale,
        recordFallbackFile: Bool,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = stop()

        let micGranted = await Self.requestMicrophonePermission()
        guard micGranted else {
            throw VoiceCaptureError.permissionDenied("未获得麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 MindDock")
        }

        let speechAuthorized = await Self.requestSpeechAuthorization()
        guard speechAuthorized || recordFallbackFile else {
            throw VoiceCaptureError.permissionDenied("未获得语音识别权限，请在「系统设置 → 隐私与安全性 → 语音识别」中允许 MindDock")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw VoiceCaptureError.hardwareUnavailable("未检测到可用的麦克风输入设备")
        }

        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?

        if speechAuthorized,
           let recognizer = Self.makePreferredRecognizer(for: locale),
           recognizer.isAvailable {
            let speechReq = SFSpeechAudioBufferRecognitionRequest()
            speechReq.shouldReportPartialResults = true
            request = speechReq
            task = recognizer.recognitionTask(with: speechReq) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    onTranscript(text, isFinal)
                } else if let error {
                    onError(error.localizedDescription)
                }
            }
        }

        var fallbackFile: AVAudioFile?
        var tempURL: URL?
        if recordFallbackFile {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("minddock-voice-\(UUID().uuidString).caf")
            if let file = try? AVAudioFile(forWriting: url, settings: recordingFormat.settings) {
                fallbackFile = file
                tempURL = url
            }
        }

        let capturedRequest = request
        let capturedFile = fallbackFile
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            capturedRequest?.append(buffer)
            try? capturedFile?.write(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            request?.endAudio()
            task?.cancel()
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            throw VoiceCaptureError.hardwareUnavailable(error.localizedDescription)
        }

        lock.withLock {
            self.audioEngine = engine
            self.recognitionRequest = request
            self.recognitionTask = task
            self.audioFile = fallbackFile
            self.recordedFileURL = tempURL
            self.hasInstalledTap = true
        }
    }

    @discardableResult
    public func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if hasInstalledTap, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
            audioEngine = nil
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        audioFile = nil
        let url = recordedFileURL
        recordedFileURL = nil
        return url
    }

    private static func makePreferredRecognizer(for locale: SpeechLocale) -> SFSpeechRecognizer? {
        if let primary = SFSpeechRecognizer(locale: Locale(identifier: locale.rawValue)), primary.isAvailable {
            return primary
        }
        if let secondary = SFSpeechRecognizer(locale: Locale(identifier: locale.fallbackLocale.rawValue)), secondary.isAvailable {
            return secondary
        }
        return SFSpeechRecognizer(locale: Locale(identifier: locale.rawValue))
            ?? SFSpeechRecognizer(locale: Locale(identifier: locale.fallbackLocale.rawValue))
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                return false
            }
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                return false
            }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

@MainActor
public final class VoiceCaptureController: ObservableObject {
    public static let defaultHoldToSpeakThreshold: TimeInterval = 0.35

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var voiceStatusMessage: String?
    @Published public var speechLocale: SpeechLocale

    private let driver: any VoiceCaptureSessionDriver
    private var intelligenceClient: (any IntelligenceClient)?
    private var hasASRFallbackEndpoint: Bool
    private var basePrefix: String = ""
    private var latestSessionTranscript: String = ""
    private var onTextUpdated: ((String) -> Void)?
    private var activePressStartedAt: Date?
    private var currentPressStartedRecording: Bool = false
    private var captureGeneration: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var pendingASRTask: Task<Void, Never>?

    public init(
        driver: any VoiceCaptureSessionDriver = NativeSpeechCaptureDriver(),
        intelligenceClient: (any IntelligenceClient)? = nil,
        hasASRFallbackEndpoint: Bool = false,
        speechLocale: SpeechLocale = .zhCN
    ) {
        self.driver = driver
        self.intelligenceClient = intelligenceClient
        self.hasASRFallbackEndpoint = hasASRFallbackEndpoint
        self.speechLocale = speechLocale
    }

    public func updateIntelligenceClient(
        _ client: (any IntelligenceClient)?,
        hasASRFallbackEndpoint: Bool,
        speechLocale: SpeechLocale? = nil
    ) {
        self.intelligenceClient = client
        self.hasASRFallbackEndpoint = hasASRFallbackEndpoint
        if let speechLocale {
            self.speechLocale = speechLocale
        }
    }

    public func cycleSpeechLocale() -> SpeechLocale {
        speechLocale = speechLocale.fallbackLocale
        return speechLocale
    }

    public var isHardwareReleased: Bool {
        !isRecording && !driver.isHardwareActive
    }

    public func beginMicPress(
        at now: Date = Date(),
        currentDraft: String,
        onTextUpdated: @escaping @MainActor (String) -> Void
    ) {
        guard activePressStartedAt == nil else { return }
        if isRecording {
            currentPressStartedRecording = false
            activePressStartedAt = now
        } else {
            currentPressStartedRecording = true
            startCapture(currentDraft: currentDraft, onTextUpdated: onTextUpdated)
            activePressStartedAt = now
        }
    }

    public func endMicPress(
        at now: Date = Date(),
        holdThreshold: TimeInterval = VoiceCaptureController.defaultHoldToSpeakThreshold
    ) {
        guard let startedAt = activePressStartedAt else { return }
        activePressStartedAt = nil
        let heldDuration = now.timeIntervalSince(startedAt)
        if !currentPressStartedRecording || heldDuration >= holdThreshold {
            stopCapture(finalizeWithASRIfNeeded: true)
        }
    }

    public func toggleCapture(currentDraft: String, onTextUpdated: @escaping @MainActor (String) -> Void) {
        activePressStartedAt = nil
        if isRecording {
            stopCapture(finalizeWithASRIfNeeded: true)
        } else {
            startCapture(currentDraft: currentDraft, onTextUpdated: onTextUpdated)
        }
    }

    public func startCapture(currentDraft: String, onTextUpdated: @escaping @MainActor (String) -> Void) {
        stopCapture(finalizeWithASRIfNeeded: false)

        let trimmedPrefix = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.basePrefix = trimmedPrefix.isEmpty ? "" : "\(trimmedPrefix) "
        self.latestSessionTranscript = ""
        self.onTextUpdated = onTextUpdated
        self.isRecording = true
        self.voiceStatusMessage = "正在倾听（\(speechLocale.shortLabel)）…"

        captureGeneration &+= 1
        let generation = captureGeneration
        let recordFallback = hasASRFallbackEndpoint
        let selectedLocale = speechLocale
        let driver = self.driver

        startTask = Task { @MainActor [weak self] in
            guard let self, self.isRecording, self.captureGeneration == generation else {
                if let orphan = driver.stop() {
                    try? FileManager.default.removeItem(at: orphan)
                }
                return
            }
            do {
                try await driver.start(
                    locale: selectedLocale,
                    recordFallbackFile: recordFallback,
                    onTranscript: { [weak self] text, isFinal in
                        Task { @MainActor [weak self] in
                            guard let self, self.captureGeneration == generation else { return }
                            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty else { return }
                            self.latestSessionTranscript = cleaned
                            self.onTextUpdated?(self.basePrefix + cleaned)
                            if isFinal && self.isRecording {
                                self.stopCapture(finalizeWithASRIfNeeded: false)
                            }
                        }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRecording, self.captureGeneration == generation else { return }
                            if self.latestSessionTranscript.isEmpty {
                                self.voiceStatusMessage = "语音已结束：\(message)"
                            }
                            self.stopCapture(finalizeWithASRIfNeeded: true)
                        }
                    }
                )
                guard self.isRecording, self.captureGeneration == generation else {
                    if let orphan = driver.stop() {
                        try? FileManager.default.removeItem(at: orphan)
                    }
                    return
                }
            } catch {
                if let orphan = driver.stop() {
                    try? FileManager.default.removeItem(at: orphan)
                }
                if self.captureGeneration == generation {
                    self.isRecording = false
                    self.voiceStatusMessage = error.localizedDescription
                }
            }
        }
    }

    public func stopCapture(finalizeWithASRIfNeeded: Bool = false) {
        captureGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        let recordedURL = driver.stop()
        let wasRecording = isRecording
        isRecording = false
        activePressStartedAt = nil

        let needsASRFallback = finalizeWithASRIfNeeded
            && wasRecording
            && latestSessionTranscript.isEmpty
            && hasASRFallbackEndpoint

        if needsASRFallback, let recordedURL, let client = intelligenceClient {
            voiceStatusMessage = "正在转写语音…"
            let prefix = basePrefix
            let callback = onTextUpdated
            pendingASRTask = Task { @MainActor [weak self] in
                let wavURL = recordedURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("minddock-drop-\(UUID().uuidString).wav")
                defer {
                    try? FileManager.default.removeItem(at: recordedURL)
                    try? FileManager.default.removeItem(at: wavURL)
                }

                let uploadURL: URL?
                if AudioFormatConverter.convertToPCM16kMonoWAV(inputURL: recordedURL, outputURL: wavURL) {
                    uploadURL = wavURL
                } else if AudioFormatConverter.isValidWAVFile(at: recordedURL) {
                    uploadURL = recordedURL
                } else {
                    uploadURL = nil
                }

                if let uploadURL,
                   let wavData = try? Data(contentsOf: uploadURL),
                   let text = await client.transcribeAudio(
                       data: wavData,
                       filename: "drop.wav",
                       mimeType: "audio/wav"
                   ) {
                    callback?(prefix + text)
                    self?.voiceStatusMessage = nil
                } else {
                    self?.voiceStatusMessage = nil
                }
            }
        } else {
            if let recordedURL {
                try? FileManager.default.removeItem(at: recordedURL)
            }
            if wasRecording {
                voiceStatusMessage = nil
            }
        }
        onTextUpdated = nil
    }

    public func awaitCaptureStarted() async {
        if let task = startTask {
            await task.value
        }
    }

    public func awaitPendingTranscription() async {
        if let task = pendingASRTask {
            await task.value
            pendingASRTask = nil
        }
    }

    public func cancelCapture() {
        pendingASRTask?.cancel()
        pendingASRTask = nil
        stopCapture(finalizeWithASRIfNeeded: false)
        voiceStatusMessage = nil
    }
}
