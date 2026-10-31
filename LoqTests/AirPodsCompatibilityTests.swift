import CoreAudio
import CoreMotion
import XCTest
@testable import Loq

@MainActor
final class AirPodsCompatibilityTests: XCTestCase {
    func testCanConnectAfterLaunchingWithoutHeadphones() {
        let source = TestMotionSource()
        source.isAvailable = false
        let service = HeadphoneMotionService(source: source, watchdogEnabled: false)
        service.start()
        XCTAssertEqual(service.status, .waiting)
        XCTAssertEqual(source.connectionStarts, 1)
        XCTAssertEqual(source.motionStarts, 0)

        source.isAvailable = true
        source.connection?(true)
        source.samples.last?(.success(MotionSample(t: 100)))
        XCTAssertEqual(service.status, .streaming)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.sampleCount, 1)
        service.stop()
    }

    func testStartIsIdempotentAndStopIgnoresLateCallbacks() {
        let source = TestMotionSource()
        let service = HeadphoneMotionService(source: source, watchdogEnabled: false)
        service.start()
        service.start()
        XCTAssertEqual(source.motionStarts, 1)
        let oldConnection = source.connection
        let oldSamples = source.samples.last
        service.stop()
        oldConnection?(true)
        oldSamples?(.success(MotionSample(t: 100)))
        XCTAssertEqual(service.status, .paused)
        XCTAssertNil(service.latest)
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(source.motionStarts, 1)
    }

    func testDisconnectClearsLiveDataAndOldStreamCannotResumeIt() {
        let source = TestMotionSource()
        let service = HeadphoneMotionService(source: source, watchdogEnabled: false)
        service.start()
        let oldSamples = source.samples.last
        oldSamples?(.success(MotionSample(t: 100)))
        source.connection?(false)
        oldSamples?(.success(MotionSample(t: 101)))
        XCTAssertEqual(service.status, .waiting)
        XCTAssertNil(service.latest)
        XCTAssertTrue(service.history.isEmpty)
        XCTAssertEqual(service.sampleRate, 0)
        service.stop()
    }

    func testStaleStreamIsMarkedAndRestartedUsingArrivalTime() {
        let source = TestMotionSource()
        var arrival = 100.0
        let service = HeadphoneMotionService(source: source, now: { arrival }, watchdogEnabled: false)
        service.start()
        let oldSamples = source.samples.last
        oldSamples?(.success(MotionSample(t: 1)))
        oldSamples?(.success(MotionSample(t: 1.04)))
        XCTAssertEqual(service.sampleRate, 25, accuracy: 0.001)
        arrival = 104
        service.checkConnection()
        XCTAssertEqual(service.status, .stalled)
        XCTAssertNil(service.latest)
        XCTAssertEqual(source.motionStarts, 2)
        oldSamples?(.success(MotionSample(t: 1.08)))
        XCTAssertNil(service.latest)
        source.samples.last?(.success(MotionSample(t: 5)))
        XCTAssertEqual(service.status, .streaming)
        XCTAssertEqual(service.history.count, 1)
        service.stop()
    }

    func testDeniedMotionDoesNotStartMonitoringAndCanBeRetriedAfterPermissionChanges() {
        let source = TestMotionSource()
        source.authorization = .denied
        let service = HeadphoneMotionService(source: source, watchdogEnabled: false)
        service.start()
        XCTAssertEqual(service.status, .denied)
        XCTAssertEqual(source.connectionStarts, 0)
        source.authorization = .authorized
        service.retry()
        XCTAssertEqual(source.motionStarts, 1)
        source.authorization = .denied
        service.checkConnection()
        XCTAssertEqual(service.status, .denied)
        XCTAssertFalse(service.isEnabled)
    }

    func testEarChangeCancelsCaptureAndCalibration() {
        let source = TestMotionSource()
        let service = HeadphoneMotionService(source: source, watchdogEnabled: false)
        let capture = CaptureController()
        var emitted = 0
        capture.onSegment = { _ in emitted += 1 }
        service.onSample = { capture.ingest($0) }
        service.onInterruption = { capture.cancel(resetCalibration: true) }
        service.start()
        var sample = MotionSample(t: 100)
        sample.sensorLocation = "Left AirPod"
        source.samples.last?(.success(sample))
        capture.begin()
        capture.calibrate()
        sample.t += 0.04
        sample.sensorLocation = "Right AirPod"
        source.samples.last?(.success(sample))
        XCTAssertFalse(capture.isCapturing)
        XCTAssertFalse(capture.isCalibrating)
        XCTAssertNil(capture.noiseFloor)
        XCTAssertEqual(emitted, 0)
        XCTAssertEqual(service.history.count, 1)
        service.stop()
    }

    func testRecommendedInputPrefersBuiltInEvenWhenAirPodsAreSystemDefault() {
        let airpods = AudioDevices.Device(id: 1, name: "AirPods Pro 2", transportType: kAudioDeviceTransportTypeBluetooth)
        let mac = AudioDevices.Device(id: 2, name: "Mac microphone", transportType: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertEqual(AudioDevices.recommendedInput(in: [airpods, mac], defaultID: 1), mac)
        XCTAssertNil(AudioDevices.recommendedInput(in: [airpods], defaultID: 1))
    }

    func testRecommendedInputAllowsExternalUSBAndRejectsBluetoothLE() {
        let bluetooth = AudioDevices.Device(id: 1, name: "Headset", transportType: kAudioDeviceTransportTypeBluetoothLE)
        let usb = AudioDevices.Device(id: 2, name: "USB mic", transportType: kAudioDeviceTransportTypeUSB)
        XCTAssertEqual(AudioDevices.recommendedInput(in: [bluetooth, usb], defaultID: 2), usb)
        XCTAssertNil(AudioDevices.recommendedInput(in: [], defaultID: nil))
    }

    func testSpeechRequestsCannotFallBackToServerRecognition() throws {
        XCTAssertNil(MicTranscriber.onDeviceRequest(supported: false))
        let request = try XCTUnwrap(MicTranscriber.onDeviceRequest(supported: true))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
    }

    func testOlderMotionDatasetsStillDecodeWithoutSensorLocation() throws {
        let original = MotionSample(t: 100)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MotionSample.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.sensorLocation)
    }
}

@MainActor
private final class TestMotionSource: HeadphoneMotionSource {
    var isAvailable = true
    var authorization: CMAuthorizationStatus = .authorized
    var connection: ((Bool) -> Void)?
    var samples: [(Result<MotionSample, Error>) -> Void] = []
    var connectionStarts = 0
    var motionStarts = 0

    func watchConnection(_ handler: @escaping (Bool) -> Void) {
        connection = handler
        connectionStarts += 1
    }
    func startMotion(_ handler: @escaping (Result<MotionSample, Error>) -> Void) {
        samples.append(handler)
        motionStarts += 1
    }
    func stopMotion() {}
    func stopWatchingConnection() { connection = nil }
}
