# Codex instructions — FingerBall-Analysis

## First read
Read [docs/FingerBall_Capture_V1_Codex_Handoff.md](docs/FingerBall_Capture_V1_Codex_Handoff.md) before making any iOS changes. Preserve all existing notebooks under `notebooks/`. Do not rename or overwrite Python/Colab research assets.

## Active project
Build a real SwiftUI + AVFoundation Xcode app under `FingerBallCapture-iOS/`. Initial real device: iPad Air 5th generation, M1, 256GB. Support iPhone and iPad. Enumerate actual rear camera formats and record original 1080p/240fps when supported; never silently downgrade. Record actual frame PTS with source timebase, raw video, capture metadata, subject pseudonymous ID, throw number and view type. Use MultipeerConnectivity for controller/recorder paired start and stop; each device records independently to local storage. LED sync is explicitly **out of scope**.

## Research integrity
- Remote Wi-Fi start is not frame-level time synchronization. Later ML-based event alignment (ball release and, when visible, stride-foot contact) has a research tolerance target of ±1–2 frames at 240fps, which must be measured, never presumed.
- Two-camera video is future teacher data for a **single-camera + single-IMU** model. Independent manual labels and model estimates have distinct provenance.
- Stage2H corrects 2D XY only; WiLoR and MediaPipe 3D coordinates are inferred, **not measured 3D ground truth**. Do not invent occluded joints, frames, or timing.
- Do not commit subject video, personally identifying records, secrets or MANO license-restricted assets.

## Workflow
- Build the iOS app with a genuine `.xcodeproj`, sources, privacy permissions/Bonjour metadata, reproducible test fixtures and README.
- Prefer feature branch `feature/fingerball-capture-v1` and a PR. Do not force-push; keep existing README history and notebooks intact.
- Capture and storage first; Hand/Pose/Ball analysis as future module protocols, not fake working inference.
- Report build/test steps actually executed. The iOS simulator cannot validate real 240fps camera behavior; real-device validation is mandatory before claiming that feature works.