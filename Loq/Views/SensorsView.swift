import CoreAudio
import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var startButtonFocused: Bool

    var body: some View {
        let motion = model.motion
        let span = motion.latest.map { ($0.t - 8)...$0.t }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check your AirPods").font(.title2.weight(.semibold))
                    Text("Connect AirPods Pro 2 and check live motion before training. Silent-word decoding is an experiment: start with a few words and compare the evaluation against chance.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 16) {
                    motionCard
                    MicrophoneCard()
                }

                GroupBox("Live motion (last 8 s)") {
                    VStack(spacing: 12) {
                        SignalPlot(title: "User acceleration (g)", samples: motion.history,
                                   channels: SignalPlot.acceleration, span: span, minScale: 0.01)
                        SignalPlot(title: "Rotation rate (rad/s)", samples: motion.history,
                                   channels: SignalPlot.rotation, span: span, minScale: 0.05)
                        SignalPlot(title: "Attitude (rad)", samples: motion.history,
                                   channels: SignalPlot.attitude, span: span, minScale: 0.1)
                    }
                    .padding(6)
                }

                RecordingCard()
            }
            .padding(20)
        }
    }

    private var motionCard: some View {
        let motion = model.motion
        return GroupBox("AirPods Pro 2 · motion") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Status", value: motion.status.label)
                LabeledContent("Sound output", value: model.audio.outputDeviceName ?? "Refresh to check")
                LabeledContent("Sample rate", value: String(format: "%.1f Hz", motion.sampleRate))
                LabeledContent("Samples", value: "\(motion.sampleCount)")
                if let location = motion.latest?.sensorLocation {
                    LabeledContent("Motion source", value: location)
                }
                if let s = motion.latest {
                    LabeledContent("Gravity", value: String(format: "%.2f, %.2f, %.2f", s.gx, s.gy, s.gz))
                }
                Text(motion.status.guidance)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(motion.isEnabled ? "Pause All" : "Start Motion") {
                        motion.isEnabled ? model.pauseSensors() : model.startMotion()
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($startButtonFocused)
                    Button("Retry Connection", action: model.retryMotion)
                }
                .defaultFocus($startButtonFocused, true)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct MicrophoneCard: View {
    var body: some View {
        GroupBox("Microphone · optional") {
            MicrophoneControls().padding(6)
        }
    }
}

struct MicrophoneControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var audio = model.audio
        return VStack(alignment: .leading, spacing: 12) {
                Picker("Input", selection: $audio.selectedDeviceID) {
                    Text(audio.recommendedDevice.map { "Recommended: \($0.name)" } ?? "Recommended: non-Bluetooth mic")
                        .tag(AudioDeviceID?.none)
                    ForEach(audio.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(audio.isRunning || audio.isStarting || model.recorder.isRecording)
                HStack {
                    Button(audio.isStarting ? "Starting Mic…" : audio.isRunning ? "Stop Mic" : "Start Mic") {
                        Task { await model.toggleMic() }
                    }
                    .disabled(audio.isStarting)
                    Button("Refresh", systemImage: "arrow.clockwise") { audio.refreshDevices() }
                        .labelStyle(.iconOnly)
                    LevelMeter(value: Double(audio.level))
                }
                Toggle("Transcribe on this Mac", isOn: Binding(
                    get: { model.transcriber.isRunning || model.transcriber.isStarting },
                    set: { _ in Task { await model.toggleTranscription() } }))
                    .disabled(!audio.isRunning || model.transcriber.isStarting)
                if let name = audio.activeDeviceName {
                    Text("Capturing from \(name)").font(.caption).foregroundStyle(.secondary)
                }
                if let error = audio.error ?? model.transcriber.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Use the Mac microphone alongside AirPods motion. Choosing an AirPods microphone changes its Bluetooth audio profile and may interrupt motion. Stop the mic before changing inputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Motion works with the mic off. Transcription is optional and stays on this Mac; server recognition is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecordingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var recorder = model.recorder
        GroupBox("Experiment recording") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Condition", selection: $recorder.condition) {
                        ForEach(SessionRecorder.Condition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(recorder.isRecording)
                }
                TextField("Prompt", text: $recorder.prompt, prompt: Text("yes no yes stop"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        model.toggleRecording()
                    } label: {
                        Label(recorder.isRecording ? "Stop Recording & Mic" : "Record Session",
                              systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    }
                    .tint(recorder.isRecording ? .red : .accentColor)
                    .disabled(!recorder.isRecording && model.motion.status != .streaming)

                    if recorder.isRecording, let startedAt = recorder.startedAt {
                        Text(startedAt, style: .timer).monospacedDigit()
                        Text("· \(recorder.motionCount) samples · \(recorder.eventCount) marks")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = recorder.lastSessionURL {
                        Button("Show Last Session") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                Text(model.audio.isRunning
                     ? "Motion + audio will be recorded. While recording, hold Space to mark each utterance."
                     : "Motion only — start the mic above to also record audio. Hold Space to mark each utterance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Recordings and training samples stay in local files until you delete them. Pausing all sensors or closing the window stops recording and the microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = recorder.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
