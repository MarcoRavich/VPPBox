# VapourBox HWEnc

A Windows-first Flutter desktop GUI for rigaya's **NVEncC**, with editable NVENC VPP filters and a draggable before/after still-image comparison inspired by VapourBox.

This is an independent project. The interface borrows workflow ideas from [VapourBox](https://github.com/StuartCameronCode/VapourBox); it does not include or depend on VapourSynth. Video processing is delegated to the user's local [NVEncC](https://github.com/rigaya/NVEnc) executable.

## Current prototype

- Select an input video and output path.
- Build and run an NVEncC command without invoking a shell.
- Configure NVENC codec (H.264/HEVC), KNN denoise, deband, unsharp, and output resize.
- View the generated command and encoder output.
- Load original and processed still images and drag/click the divider or use the slider to compare them.

The comparison currently works with still images selected by the user; it is not yet a live frame preview or automatic NVEncC preview render. Filter availability depends on the NVEncC build and GPU. Check NVEncC's own help/options documentation for compatibility.

## Lightweight PowerShell version

`Scripts/VapourBox-HWEnc.ps1` provides an alternative WPF frontend for Windows PowerShell 5.1+. It offers the same quick NVEncC encode flow, a smaller set of common VPP controls, command preview, encoder log, and sliding original/processed still comparison. Put `NVEncC64.exe` beside the script or add it to `PATH`, then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Scripts\VapourBox-HWEnc.ps1
```

The PowerShell preview currently compares user-selected still images; it does not render a processed preview automatically.

## Flutter app requirements and run

- Windows 10/11 x64
- Flutter stable with Windows desktop support enabled
- rigaya NVEncC for Windows and a supported NVIDIA GPU/driver

From the repository root, generate the Windows runner once, then launch:

```powershell
flutter create --platforms=windows .
flutter pub get
flutter run -d windows
```

Enter the path to `NVEncC.exe` (or ensure it is available on `PATH`). Pick a video, set an output file, adjust filters, and start the encode. Use **Load original still** and **Load processed still** to populate the sliding comparison panel.

## Notes

- The command is passed as an argument list directly to the configured executable; no shell command string is evaluated.
- Initial VPP options are `--vpp-knn`, `--vpp-deband`, `--vpp-unsharp`, and `--output-res`. Filter parameter names/ranges are based on NVEncC's upstream options documentation and may vary by version.
- A future preview milestone can render the current frame with the selected VPP settings and feed both stills directly into the comparison widget.

## Credits and licensing

VapourBox is GPL-3.0; this project is also GPL-3.0. NVEnc is maintained by [rigaya](https://github.com/rigaya/NVEnc); consult the upstream project for its license and usage terms.
