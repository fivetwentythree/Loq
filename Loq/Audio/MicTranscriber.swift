import AVFoundation
import Observation
import Speech

/// Continuous speech-to-text from the microphone. Used as the reference ("ground truth")
/// next to the motion decoder, and to test whether whispering is enough for input.
@MainActor @Observable
final class MicTranscriber {
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var text = ""
    private(set) var isOnDevice = false
    private(set) var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let box = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private weak var sink: AudioSink?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var generation = 0

    func start(sink: AudioSink) async {
        guard !isRunning, !isStarting else { return }
        error = nil
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            error = "On-device English recognition is unavailable. Use motion without transcription; server recognition is disabled."
            return
        }
        generation += 1
        let run = generation
        isStarting = true
        defer { if generation == run || isRunning { isStarting = false } }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == run else { return }
        guard status == .authorized else {
            error = "Allow Speech Recognition for Loq in Privacy & Security, then try again."
            return
        }
        guard recognizer.isAvailable else {
            error = "Local speech recognition is unavailable. Try again later or use motion only."
            return
        }

        self.sink = sink
        sinkID = sink.add { [box] buffer, _ in box.append(buffer) }
        isRunning = true
        startTask()
    }

    func stop() {
        isRunning = false
        isStarting = false
        isOnDevice = false
        generation += 1
        if let sinkID { sink?.remove(sinkID) }
        sinkID = nil
        box.set(nil)
        task?.cancel()
        task = nil
    }

    func clear() {
        finalized = ""
        text = ""
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        guard let request = Self.onDeviceRequest(supported: recognizer.supportsOnDeviceRecognition) else {
            stop()
            error = "On-device recognition became unavailable. Transcription stopped; no server fallback is allowed."
            return
        }
        generation += 1

        isOnDevice = true
        box.set(request)

        task?.cancel()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self, generation: generation))
    }

    static func onDeviceRequest(supported: Bool) -> SFSpeechAudioBufferRecognitionRequest? {
        guard supported else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    private func handle(generation: Int, partial: String?, isFinal: Bool, errorDescription: String?) {
        guard generation == self.generation, isRunning else { return }
        if let partial {
            text = finalized + partial
        }
        if isFinal || errorDescription != nil {
            if let partial, !partial.isEmpty { finalized += partial + " " }
            text = finalized
            if let errorDescription {
                stop()
                error = "Local transcription stopped: \(errorDescription). Try turning transcription on again, or use motion only."
                return
            }
            // Successful tasks end on silence/timeout; keep listening locally.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.startTask()
            }
        }
    }

    nonisolated private static func resultHandler(owner: MicTranscriber, generation: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void
    {
        { [weak owner] result, error in
            let partial = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                owner?.handle(generation: generation, partial: partial, isFinal: isFinal, errorDescription: errorDescription)
            }
        }
    }
}

/// The current recognition request, appended to from the audio thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}
