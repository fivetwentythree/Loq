import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(AppModel.Screen.allCases, selection: screenSelection) { screen in
                Label(screen.rawValue, systemImage: screen.symbol).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.screen {
            case .sensors: SensorsView()
            case .train: TrainView()
            case .decode: DecodeView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                MotionStatusBadge(status: model.motion.status, rate: model.motion.sampleRate)
            }
            ToolbarItem {
                RecordToolbarButton()
            }
            ToolbarItem {
                if model.audio.isRunning {
                    Button("Stop Mic", systemImage: "mic.slash", action: model.stopMicrophone)
                        .help("Stop the microphone, transcription, and any recording")
                }
            }
            ToolbarItem {
                Button(model.hasActiveSensors ? "Pause All" : "Start Motion",
                       systemImage: model.hasActiveSensors ? "pause.circle" : "play.circle") {
                    model.hasActiveSensors ? model.pauseSensors() : model.startMotion()
                }
                .help(model.hasActiveSensors ? "Stop motion, microphone, transcription, and recording" : "Start AirPods motion; the microphone stays off")
            }
        }
        .navigationTitle(model.screen.rawValue)
    }

    private var screenSelection: Binding<AppModel.Screen?> {
        Binding(get: { model.screen }, set: { if let screen = $0 { model.screen = screen } })
    }
}

private struct RecordToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        Button {
            model.toggleRecording()
        } label: {
            Label(recorder.isRecording ? "Stop Recording & Mic" : "Record Session",
                  systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .tint(recorder.isRecording ? .red : nil)
        .disabled(!recorder.isRecording && model.motion.status != .streaming)
        .help("Record motion and optional microphone audio. Stop also turns off the microphone.")
    }
}
