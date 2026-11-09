# VPPBox

A Windows-first NVEncC GUI inspired by VapourBox's video-restoration workflow. VPPBox is an independent project: it does not include or depend on VapourSynth. Encoding is delegated to the user's local [rigaya NVEncC](https://github.com/rigaya/NVEnc).

## Features

- Dark VapourBox-inspired desktop workflow with comparison preview, video queue, processing log, settings panel, and a persistent **Go** action.
- Draggable before/after overlay preview, supported by a divider slider and user-loaded source/processed still images.
- Multi-file queue; input/output selection; H.264 and HEVC; CQP quality; audio copy.
- VPP settings for KNN denoise, deband, unsharp, and resize, with a generated NVEncC command preview.
- Quick starting presets for detail-preserving cleanup, debanding, and 1080p resize.
- Lightweight WPF/PowerShell version at `Scripts/VapourBox-HWEnc.ps1`.

The preview currently compares user-selected stills and does not render a processed frame automatically. VPP support varies by NVEncC version, GPU, and driver; check upstream help/docs for exact option support.

## Requirements

- Windows 10/11 x64
- rigaya NVEncC64 and supported NVIDIA GPU/driver
- Flutter stable with Windows desktop support for building the Flutter UI, or Windows PowerShell 5.1+ for the script edition

## Run Flutter from source

```powershell
flutter create --platforms=windows --project-name=vapourbox_hwenc .
flutter pub get
flutter run -d windows
