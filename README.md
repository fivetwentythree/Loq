# Loq

A macOS experiment for **AirPods Pro 2** that tests whether headphone motion (`CMHeadphoneMotionManager`) carries enough information to distinguish silently mouthed words.

It uses a small-vocabulary template recognizer, without a language model. It is not a general silent-speech transcriber. You train it on your own motion, then evaluate whether those words are distinguishable from chance.

Loq builds on [Subvox](https://github.com/joeblau/subvox) by Joe Blau. The original MIT license and copyright notice are retained in [LICENSE](LICENSE).

## Build & run

Open the included `Loq.xcodeproj` in Xcode 16 or later, choose the **Loq** scheme and **My Mac**, and press **⌘R**. No XcodeGen installation, package downloads, developer-team selection, or provisioning updates are needed for this local build.

With XcodeBuildMCP already installed:

```sh
xcodebuildmcp macos build --project-path ./Loq.xcodeproj --scheme Loq --derived-data-path ./build
xcodebuildmcp macos launch --app-path ./build/Build/Products/Debug/Loq.app
xcodebuildmcp macos test --project-path ./Loq.xcodeproj --scheme Loq --derived-data-path ./build
```

Requires macOS 14+ and motion-capable AirPods connected to the Mac. The app uses local ad-hoc signing and App Sandbox. It has microphone input permission but no network entitlement. `ENABLE_HARDENED_RUNTIME` is enabled in the configuration; Xcode disables Hardened Runtime for ad-hoc signing, so this local build does not provide that protection or notarization. Distribution requires an appropriate signing identity and separate validation. `project.yml` remains available for developers who already use XcodeGen; it is not required.

## AirPods Pro 2 setup

1. Wear both AirPods and connect them to this Mac. In **System Settings → Sound → Output**, select your AirPods. Keep them connected to the Mac instead of letting another device take over.
2. Open **Sensors** and choose **Start Motion**. Allow Motion & Fitness if macOS asks. The status should change to **Receiving motion**, with a non-zero measured sample rate and the left/right AirPod shown as the source.
3. Turn your head gently to check the live plots. Leave the microphone off for initial training; it is not needed for motion capture.
4. Open **Train**, select two or three words, then hold **Space**, mouth the word, and release. Alternatively, click the capture button to start and click again to finish. Record 8–10 takes per word in a mixed order.
5. Choose **Evaluate**. Compare accuracy with chance and the permutation results. If there is useful signal, open **Decode** and use **Hold Space** first. Auto-detect requires a fresh two-second noise calibration after connection interruptions or pauses.

**Pause All** stops motion, microphone, transcription, and any recording. **Stop Recording & Mic** ends the recording and microphone capture. Closing the window quits the app; backgrounding it pauses sensors. Returning to the app does not silently restart them.

### If no motion arrives

- Check the AirPods are being worn and are the Mac's sound output. Use **Refresh** to update the displayed audio devices.
- Use **Retry Connection**, or disconnect and reconnect the AirPods. The app watches for connections even when no headphones were present at launch and retries interrupted streams.
- If access was denied, enable Loq in **Privacy & Security → Motion & Fitness**, then retry.
- Use the Mac microphone for reference audio. Choosing an AirPods microphone changes the Bluetooth audio profile and may interrupt motion. Stop the mic before changing inputs.
- A sample rate dropping to zero means the app is not receiving current motion. Old readings are cleared rather than displayed as a healthy stream.

### Optional reference audio

**Start Mic** starts only microphone capture and the level meter. The default input prefers the Mac's built-in microphone or another non-Bluetooth input. You can explicitly select another device while the mic is stopped.

**Transcribe on this Mac** is a separate opt-in after the mic starts. It requires local English speech recognition. If on-device recognition is unsupported or fails, transcription stops with an explanation; there is no server fallback. Speech permission is only requested when you enable transcription. The microphone stays off at launch.

## Screens

| Screen | What it does |
|---|---|
| **Sensors** | AirPods setup, live acceleration/rotation/attitude plots, measured sample rate, sensor ear, optional microphone controls, and session recording. |
| **Train** | Pick a word, hold **Space**, mouth it, release. Each take is stored as a template. **Evaluate** runs leave-one-out classification and a 500× label-permutation test, then shows accuracy against chance, a p-value and a confusion matrix. The feature checkboxes (acceleration / rotation / attitude) let you test which channels carry the signal. |
| **Decode** | Hold Space or use calibrated auto-detect. Each segment is matched against your templates. An optional on-device microphone transcript provides a comparison. |

## How decoding works

1. **Segmentation** (`CaptureController`). Space-hold, or an energy trigger above a calibrated noise floor with pre-roll and hangover.
2. **Features** (`MotionFeatures`). Per frame: user acceleration (3), rotation rate (3), and attitude change since the start of the segment (3). Each channel is mean-centered, and quiet lead-in and lead-out frames are trimmed.
3. **Matching** (`DTW`, `TemplateClassifier`). Each channel is z-scaled across the training set. Matching is 1-nearest-neighbour per word, using dynamic time warping with a Sakoe–Chiba band. A segment is rejected if the best distance is above *max distance* or the margin to the runner-up is below *min confidence*.
4. **Is it real?** (`Evaluation`). The leave-one-out accuracy is compared with the same procedure run on shuffled labels. If p < 0.05, the motion stream distinguishes your words better than chance.

## Experiment protocol

Use **Record Session** in the toolbar or on the Sensors screen once motion is streaming. In the sandboxed app, recordings are stored under `~/Library/Containers/local.subvox/Data/Documents/Subvox/Sessions/<timestamp>-<condition>-<id>/`. **Show Last Session** reveals the actual folder in Finder:

- `motion.csv`: every motion sample and its sensor ear. `t` is seconds from session start.
- `audio.caf`: microphone audio, if the mic is running.
- `events.csv`: every Space-held segment, with its label or prediction.
- `meta.json`: condition, prompt, and the audio start offset for aligning audio with motion.

Suggested runs: the same 5-word script under **Normal speech**, **Whisper** and **Silent mouthing**, 10 reps each. Then, in Train, compare the Evaluate results across feature sets.

The training set is stored under `~/Library/Containers/local.subvox/Data/Library/Application Support/Subvox/dataset.json`. The app does not import an upstream installation's dataset from outside its sandbox automatically. Older dataset records without a sensor-location field remain readable.

Loq intentionally retains the `local.subvox` bundle identifier and the `Subvox` storage folders from the earlier local build. This preserves your existing training takes, recordings, and macOS permission identity when upgrading to Loq. The app, Xcode targets, and scheme are named Loq.

These are ordinary local files, without app-level encryption or automatic deletion. Clear Transcript clears the displayed transcript, not saved recordings. Delete recording folders yourself when no longer needed; your backup/sync configuration still applies. Session names include a unique suffix to avoid overwriting back-to-back recordings, and exported labels are quoted and neutralized for spreadsheet formulas.

## Validation

On 31 October 2026, a connected pair identified by the user as AirPods Pro 2 streamed live motion from the **right AirPod at approximately 50 Hz**. The live plots and pause control were checked with the microphone off. Automated tests cover connection after launch, stale-stream recovery, disconnects, ignored late callbacks, motion permissions, sensor-ear changes, microphone selection, local-only speech requests, legacy motion data, CSV escaping, and the numerical decoder.

This does not establish decoding accuracy for a particular person's words. Microphone capture and live speech recognition require a separate hardware check; the automated speech test verifies the no-server request policy.

## Known limits

- Headphone motion is processed and its sample rate varies; use the measured rate rather than assuming a fixed value. This app uses the public motion stream, not a raw speech accelerometer or the inward-facing microphone.
- Templates are user- and session-specific. Re-seating the AirPods can shift the signal.
- Choosing AirPods as the mic input switches them to the Bluetooth headset (HFP) profile.
