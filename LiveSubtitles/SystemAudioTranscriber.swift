import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech

enum LiveSubtitleError: LocalizedError {
    case speechPermissionDenied
    case screenCapturePermissionDenied
    case speechRecognizerUnavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Allow Speech Recognition in System Settings → Privacy & Security."
        case .screenCapturePermissionDenied:
            return "Allow Live Subtitles in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .speechRecognizerUnavailable:
            return "Speech recognition is not available for the selected language right now."
        case .noDisplay:
            return "No display is available for system audio capture."
        }
    }
}

final class SystemAudioTranscriber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias ResultHandler = @Sendable (String) -> Void

    private let audioQueue = DispatchQueue(label: "app.livesubtitles.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var resultHandler: ResultHandler?
    private var active = false

    func start(localeIdentifier: String, onResult: @escaping ResultHandler) async throws {
        guard !active else { return }
        let authorization = await requestSpeechAuthorization()
        guard authorization == .authorized else {
            throw LiveSubtitleError.speechPermissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw LiveSubtitleError.speechRecognizerUnavailable
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw LiveSubtitleError.screenCapturePermissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("tcc") || message.contains("declined") || message.contains("permission") {
                throw LiveSubtitleError.screenCapturePermissionDenied
            }
            throw error
        }
        guard let display = content.displays.first else {
            throw LiveSubtitleError.noDisplay
        }

        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.recognizer = recognizer
        self.resultHandler = onResult
        self.active = true
        beginRecognition()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        active = false
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        resultHandler = nil

        let stream = self.stream
        self.stream = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }

    private func beginRecognition() {
        guard active, let recognizer else { return }
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let transcription = result?.bestTranscription {
                let text = self.visibleCaption(from: transcription)
                if !text.isEmpty {
                    self.resultHandler?(text)
                }
            }

            if result?.isFinal == true || error != nil {
                self.audioQueue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.beginRecognition()
                }
            }
        }
    }

    /// Speech returns the whole current utterance on every partial result. Keeping
    /// all of it makes a subtitle overlay shrink until it is unreadable, so only
    /// retain a natural-looking tail that fits comfortably in a few lines.
    private func visibleCaption(from transcription: SFTranscription) -> String {
        let maximumCharacters = 150
        let maximumSegments = 24
        let recentSegments = transcription.segments.suffix(maximumSegments)
        var caption = recentSegments.map(\.substring).joined(separator: " ")

        while caption.count > maximumCharacters,
              let firstSpace = caption.firstIndex(of: " ") {
            caption.removeSubrange(caption.startIndex...firstSpace)
        }

        return caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, active, sampleBuffer.isValid else { return }
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
