import CoreMotion
import Observation

@MainActor
protocol HeadphoneMotionSource: AnyObject {
    var isAvailable: Bool { get }
    var authorization: CMAuthorizationStatus { get }
    func watchConnection(_ handler: @escaping (Bool) -> Void)
    func startMotion(_ handler: @escaping (Result<MotionSample, Error>) -> Void)
    func stopMotion()
    func stopWatchingConnection()
}

/// AirPods Pro 2 use the standard headphone-motion API, including its connection delegate.
@MainActor @Observable
final class HeadphoneMotionService {
    enum Status: Equatable {
        case unsupported, denied, paused, waiting, connecting, streaming, stalled
        case error(String)

        var label: String {
            switch self {
            case .unsupported: "Headphone motion unavailable"
            case .denied: "Motion access denied"
            case .paused: "Motion paused"
            case .waiting: "Waiting for AirPods"
            case .connecting: "Waiting for motion samples"
            case .streaming: "Receiving motion"
            case .stalled: "Motion interrupted"
            case .error(let message): message
            }
        }

        var guidance: String {
            switch self {
            case .denied:
                "Allow Loq in System Settings → Privacy & Security → Motion & Fitness, then retry."
            case .paused:
                "Start motion when you are ready. The microphone is optional."
            case .streaming:
                "Move your head gently and check the plots below. Then train a few words with the microphone off."
            case .unsupported, .waiting, .connecting, .stalled, .error:
                "Wear both AirPods Pro 2, connect them to this Mac, and select them as sound output. If no samples arrive, reconnect them and retry."
            }
        }
    }

    static let historySeconds: TimeInterval = 10
    static let staleSeconds: TimeInterval = 3

    private(set) var status: Status = .paused
    private(set) var isEnabled = false
    private(set) var isConnected = false
    private(set) var latest: MotionSample?
    private(set) var history: [MotionSample] = []
    private(set) var sampleRate: Double = 0
    private(set) var sampleCount = 0
    var onSample: ((MotionSample) -> Void)?
    var onInterruption: (() -> Void)?

    @ObservationIgnored private let source: any HeadphoneMotionSource
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let watchdogEnabled: Bool
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var rateWindow: [TimeInterval] = []
    @ObservationIgnored private var lastArrival: TimeInterval?
    @ObservationIgnored private var lastAttempt: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var streamGeneration = 0

    init(source: (any HeadphoneMotionSource)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         watchdogEnabled: Bool = true) {
        self.source = source ?? CoreMotionSource()
        self.now = now
        self.watchdogEnabled = watchdogEnabled
    }

    func start() {
        guard !isEnabled else { return }
        guard source.authorization != .denied, source.authorization != .restricted else {
            status = .denied
            return
        }
        isEnabled = true
        generation += 1
        let run = generation
        status = .waiting
        lastAttempt = now()
        // Register even when headphones are absent. Availability alone is not a connection check.
        source.watchConnection { [weak self] connected in
            guard let self, self.isEnabled, self.generation == run else { return }
            self.isConnected = connected
            if connected {
                self.beginStream()
            } else {
                self.source.stopMotion()
                self.streamGeneration += 1
                self.clearLiveData()
                self.status = .waiting
            }
        }
        if source.isAvailable { beginStream() }
        if watchdogEnabled {
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    self.checkConnection()
                }
            }
        }
    }

    func stop() {
        isEnabled = false
        generation += 1
        streamGeneration += 1
        watchdog?.cancel()
        watchdog = nil
        source.stopMotion()
        source.stopWatchingConnection()
        isConnected = false
        clearLiveData()
        status = .paused
    }

    func retry() {
        stop()
        start()
    }

    /// Also used by deterministic tests; arrival time avoids mistaking an old reading for live data.
    func checkConnection() {
        guard isEnabled else { return }
        if source.authorization == .denied || source.authorization == .restricted {
            stop()
            status = .denied
            return
        }
        let elapsed = now() - (lastArrival ?? lastAttempt)
        guard elapsed >= Self.staleSeconds else { return }
        if status == .streaming {
            clearLiveData()
            status = .stalled
        }
        if source.isAvailable || isConnected { beginStream() }
    }

    private func beginStream() {
        source.stopMotion()
        streamGeneration += 1
        let stream = streamGeneration
        lastAttempt = now()
        lastArrival = nil
        if status != .stalled { status = .connecting }
        source.startMotion { [weak self] result in
            guard let self, self.isEnabled, self.streamGeneration == stream else { return }
            switch result {
            case .success(let sample): self.ingest(sample)
            case .failure(let error):
                self.clearLiveData()
                let ns = error as NSError
                if self.source.authorization == .denied || self.source.authorization == .restricted
                    || (ns.domain == CMErrorDomain && ns.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)) {
                    self.stop()
                    self.status = .denied
                } else {
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func clearLiveData() {
        latest = nil
        history.removeAll()
        rateWindow.removeAll()
        lastArrival = nil
        sampleRate = 0
        onInterruption?()
    }

    private func ingest(_ sample: MotionSample) {
        // Reconnection or a sensor-ear change invalidates in-flight captures and calibration.
        if let latest, sample.t <= latest.t || sample.sensorLocation != latest.sensorLocation {
            clearLiveData()
        }
        lastArrival = now()
        latest = sample
        status = .streaming
        isConnected = true
        sampleCount += 1
        history.append(sample)
        history.removeAll { $0.t < sample.t - Self.historySeconds }
        rateWindow.append(sample.t)
        rateWindow.removeAll { $0 < sample.t - 1 }
        if let first = rateWindow.first, sample.t > first {
            sampleRate = Double(rateWindow.count - 1) / (sample.t - first)
        }
        onSample?(sample)
    }
}

@MainActor
private final class CoreMotionSource: NSObject, HeadphoneMotionSource, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var connectionHandler: ((Bool) -> Void)?
    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }

    func watchConnection(_ handler: @escaping (Bool) -> Void) {
        connectionHandler = handler
        manager.delegate = self
        manager.startConnectionStatusUpdates()
    }

    func startMotion(_ handler: @escaping (Result<MotionSample, Error>) -> Void) {
        manager.startDeviceMotionUpdates(to: .main) { motion, error in
            MainActor.assumeIsolated {
                if let error { handler(.failure(error)) }
                else if let motion { handler(.success(MotionSample(motion))) }
            }
        }
    }

    func stopMotion() { manager.stopDeviceMotionUpdates() }
    func stopWatchingConnection() {
        manager.stopConnectionStatusUpdates()
        connectionHandler = nil
        manager.delegate = nil
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.connectionHandler?(true) }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.connectionHandler?(false) }
    }
}
