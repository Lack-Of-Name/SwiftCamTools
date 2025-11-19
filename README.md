# SwiftCamTools

SwiftCamTools is a minimalist iOS camera app tuned for manual or automated low-light shooting. It combines SwiftUI for UI, AVFoundation for capture control, and a Metal-based fusion stack for aggressive noise reduction without losing shadow detail.

## Highlights
- Camera-first UI modeled after the stock iOS Camera: minimalist preview, top utility bar, and shutter-centric bottom bar.
- Manual long-exposure, ISO, and noise controls stay tucked in a slider-based drawer so the main viewport stays clean.
- Long-exposure, bracketed, and RAW capture modes powered by `AVCapturePhotoOutput` presets.
- Configurable exposure graphs plus per-mode presets for rapid scene switching.
- Custom Metal/Accelerate fusion pipeline that can fall back to Apple's built-in fusion when Metal is unavailable.
- Modular package (`SwiftCamToolsKit`) that keeps camera, imaging, and domain logic reusable across future targets.

## Repository layout
```
SwiftCamTools
├── Apps/SwiftCamToolsApp         # SwiftUI application target
├── Packages/SwiftCamToolsKit     # Swift Package with Core/Imaging/Camera modules
├── Resources/Assets.xcassets     # Shared asset catalogs
├── Tests                         # UI/ViewModel level tests
├── project.yml                   # XcodeGen definition for the iOS app + tests
└── Outline.txt                   # Original product brief
```

## Dependencies
All dependencies are declared through Swift Package Manager so Xcode can resolve them automatically:

| Package | Why |
| --- | --- |
| [swift-collections](https://github.com/apple/swift-collections) | Deques and OrderedSets for exposure job queues |
| [swift-algorithms](https://github.com/apple/swift-algorithms) | Sliding window helpers for histogram smoothing |
| [MetalPetal](https://github.com/MetalPetal/MetalPetal) | GPU-accelerated denoise/fusion primitives |

System frameworks used by the modules: `AVFoundation`, `Photos`, `CoreImage`, `Metal`, `MetalPerformanceShaders`, `Accelerate`, `SwiftUI`, and `Combine`.

## UI overview

- **Top utility bar** — flash/timer/grid toggles plus a live histogram so shooters can stay exposed correctly without opening menus.
- **Bottom bar** — mode selector, oversized shutter button, and a slider icon that reveals the manual controls drawer.
- **Manual controls drawer** — ISO (100–6400), shutter (1/8s–8s), noise reduction mix, and a long-exposure toggle. Presets reset with a single tap to keep experimentation safe.
- **Grid overlay** — optional thirds grid stays out of the way but matches most tripod framing workflows.

## Getting started (macOS + Xcode)
1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you have not already: `brew install xcodegen`.
2. Generate the Xcode project from the blueprint:
   ```pwsh
   cd SwiftCamTools
   xcodegen generate
   ```
3. Open the newly created `SwiftCamTools.xcodeproj` in Xcode and select the *SwiftCamTools* scheme.
4. Trust camera + photo permissions when prompted on device; simulators cannot access true low-light sensors.

## Testing
Once the project is generated you can run the included unit tests from Xcode (`Product > Test`) or from the command line:
```pwsh
cd SwiftCamTools
xcodebuild test -scheme SwiftCamTools -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

> **Note:** These commands must be executed on macOS with Xcode installed. This repository currently contains project sources only and does not include a pre-generated `.xcodeproj`.

## Continuous Integration

The repository ships with `.github/workflows/ios-ci.yml`, a GitHub Actions workflow that runs on `macos-14` and performs the following for every push/PR targeting `main`:

1. Checks out the repo and selects Xcode 15.4.
2. Installs XcodeGen via Homebrew.
3. Generates `SwiftCamTools.xcodeproj` from `project.yml`.
4. Builds and tests the `SwiftCamTools` scheme on the iPhone 15 Pro simulator with signing disabled.

After pushing to GitHub, add the following badge at the top of this README (replace `<your-org>` with your account or organization name):

```markdown
[![iOS CI](https://github.com/<your-org>/SwiftCamTools/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/<your-org>/SwiftCamTools/actions/workflows/ios-ci.yml)
```
