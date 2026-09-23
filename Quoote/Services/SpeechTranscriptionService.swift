import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechTranscriptionService: ObservableObject {
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var error: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    func startTranscription() {
        guard !isTranscribing else { return }

        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available."
            return
        }
        self.recognizer = recognizer

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            engine.prepare()
            try engine.start()
        } catch {
            // Remove the tap installed above before bailing out; leaving it installed
            // would prevent a future startTranscription() call from adding its own tap.
            inputNode.removeTap(onBus: 0)
            self.error = "Microphone error: \(error.localizedDescription)"
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopTranscription()
                }
            }
        }

        self.audioEngine = engine
        self.request = request
        isTranscribing = true
        error = nil
    }

    func stopTranscription() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        request = nil
        recognitionTask = nil
        recognizer = nil

        try? AVAudioSession.sharedInstance().setActive(false)
        isTranscribing = false
    }
}
