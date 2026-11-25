import AVFoundation
import Foundation
import MindDockCore
import Speech

protocol VoiceCaptureSessionDriver: Sendable {
    var isHardwareActive: Bool { get }
    func start(
        recordFallbackFile: Bool,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws
    func stop() -> URL?
}

final class NativeSpeechCaptureDriver: VoiceCaptureSessionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var recordedFileURL: URL?
    private var hasInstalledTap = false

    var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasInstalledTap || (audioEngine?.isRunning ?? false) || audioEngine != nil
    }

    func start(
        recordFallbackFile: Bool,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = stop()

        let micGranted = await Self.requestMicrophonePermission()
        guard micGranted else {
            throw VoiceCaptureError.permissionDenied("Microphone access not granted")
        }

        let speechAuthorized = await Self.requestSpeechAuthorization()
        guard speechAuthorized || recordFallbackFile else {
            throw VoiceCaptureError.permissionDenied("Speech recognition permission not granted")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw VoiceCaptureError.hardwareUnavailable("No active audio input device")
        }

        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?

        if speechAuthorized,
           let recognizer = Self.makePreferredRecognizer(),
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
    func stop() -> URL? {
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

    private static func makePreferredRecognizer() -> SFSpeechRecognizer? {
        if let current = SFSpeechRecognizer(locale: Locale.current) {
            return current
        }
        if let zh = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) {
            return zh
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
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

enum VoiceCaptureError: Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case hardwareUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg), .hardwareUnavailable(let msg):
            return msg
        }
    }
}

@MainActor
final class VoiceCaptureController: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var voiceStatusMessage: String?

    private let driver: any VoiceCaptureSessionDriver
    private var intelligenceClient: (any IntelligenceClient)?
    private var hasASRFallbackEndpoint: Bool
    private var basePrefix: String = ""
    private var latestSessionTranscript: String = ""
    private var onTextUpdated: ((String) -> Void)?

    init(
        driver: any VoiceCaptureSessionDriver = NativeSpeechCaptureDriver(),
        intelligenceClient: (any IntelligenceClient)? = nil,
        hasASRFallbackEndpoint: Bool = false
    ) {
        self.driver = driver
        self.intelligenceClient = intelligenceClient
        self.hasASRFallbackEndpoint = hasASRFallbackEndpoint
    }

    func updateIntelligenceClient(
        _ client: (any IntelligenceClient)?,
        hasASRFallbackEndpoint: Bool
    ) {
        self.intelligenceClient = client
        self.hasASRFallbackEndpoint = hasASRFallbackEndpoint
    }

    var isHardwareReleased: Bool {
        !isRecording && !driver.isHardwareActive
    }

    func toggleCapture(currentDraft: String, onTextUpdated: @escaping @MainActor (String) -> Void) {
        if isRecording {
            stopCapture(finalizeWithASRIfNeeded: true)
        } else {
            startCapture(currentDraft: currentDraft, onTextUpdated: onTextUpdated)
        }
    }

    func startCapture(currentDraft: String, onTextUpdated: @escaping @MainActor (String) -> Void) {
        stopCapture(finalizeWithASRIfNeeded: false)

        let trimmedPrefix = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.basePrefix = trimmedPrefix.isEmpty ? "" : "\(trimmedPrefix) "
        self.latestSessionTranscript = ""
        self.onTextUpdated = onTextUpdated
        self.isRecording = true
        self.voiceStatusMessage = "Listening…"

        let recordFallback = hasASRFallbackEndpoint
        let driver = self.driver

        Task { @MainActor [weak self] in
            guard let self, self.isRecording else {
                _ = driver.stop()
                return
            }
            do {
                try await driver.start(
                    recordFallbackFile: recordFallback,
                    onTranscript: { [weak self] text, isFinal in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
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
                            guard let self, self.isRecording else { return }
                            if self.latestSessionTranscript.isEmpty {
                                self.voiceStatusMessage = "Voice stopped: \(message)"
                            }
                            self.stopCapture(finalizeWithASRIfNeeded: true)
                        }
                    }
                )
            } catch {
                _ = driver.stop()
                self.isRecording = false
                self.voiceStatusMessage = error.localizedDescription
            }
        }
    }

    func stopCapture(finalizeWithASRIfNeeded: Bool = false) {
        let recordedURL = driver.stop()
        let wasRecording = isRecording
        isRecording = false

        let needsASRFallback = finalizeWithASRIfNeeded
            && wasRecording
            && latestSessionTranscript.isEmpty
            && hasASRFallbackEndpoint

        if needsASRFallback, let recordedURL, let client = intelligenceClient {
            voiceStatusMessage = "Transcribing audio…"
            let prefix = basePrefix
            let callback = onTextUpdated
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: recordedURL) }
                if let audioData = try? Data(contentsOf: recordedURL),
                   let text = await client.transcribeAudio(
                       data: audioData,
                       filename: recordedURL.lastPathComponent,
                       mimeType: "audio/x-caf"
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

    func cancelCapture() {
        stopCapture(finalizeWithASRIfNeeded: false)
        voiceStatusMessage = nil
    }
}
