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

## Local workflows

### Windows/Linux (Swift Package only)
Use this path when you only need to touch the reusable modules under `Packages/SwiftCamToolsKit`:

```pwsh
cd Packages/SwiftCamToolsKit
swift build
swift test
```

The UI and capture layers are guarded with `#if canImport(...)`, so they compile out on non-Apple hosts.

### macOS + Xcode (full iOS app)
1. Install required tooling:
   ```bash
   brew install xcodegen xcbeautify
   ```
2. Generate the Xcode project from the blueprint:
   ```bash
   cd SwiftCamTools
   xcodegen generate
   ```
3. (Optional) Inspect available simulators so your destination matches the installed runtimes: `xcrun simctl list devices available`.
4. Build & test exactly like CI does:
   ```bash
   xcodebuild \
     -scheme SwiftCamTools \
     -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
     -derivedDataPath DerivedData \
     CODE_SIGNING_ALLOWED=NO \
     test | xcbeautify
   ```
5. Open `SwiftCamTools.xcodeproj` if you prefer to iterate inside Xcode.

Trust camera + photo permissions when prompted on a physical device; simulators cannot access true low-light sensors.

## Testing
Once the project is generated you can run the included unit tests from Xcode (`Product > Test`) or via the command shown above.

> **Note:** These commands must be executed on macOS with Xcode installed. This repository currently contains project sources only and does not include a pre-generated `.xcodeproj`.

## Continuous Integration

The repository ships with `.github/workflows/ios-ci.yml`, a GitHub Actions workflow that runs on `macos-latest` and performs the following for every push/PR targeting `main`:

1. Checks out the repo and selects the newest Xcode available on the runner.
2. Installs XcodeGen + xcbeautify via Homebrew, then prints the active Xcode version.
3. Generates `SwiftCamTools.xcodeproj` from `project.yml` and resolves Swift package dependencies up front (cached under `DerivedData/SourcePackages`).
4. Lists the available simulators so the `-destination` choice is always visible in the logs.
5. Runs `xcodebuild test` against the iPhone 15 Pro simulator (signing disabled) with output piped through `xcbeautify`, storing full logs and the `.xcresult` bundle as workflow artifacts.

### Manual IPA builds

Need a signed-off simulator `.ipa` without triggering CI automatically? The repository also includes `.github/workflows/manual-ipa.yml`, which exposes a **Run workflow** button in the Actions tab. It:

1. Installs the same toolchain as the CI job (latest macOS runner + Xcode).
2. Generates the Xcode project via XcodeGen and resolves all Swift packages.
3. Builds the `SwiftCamTools` scheme in Release for the requested simulator destination (defaults to iPhone 16 Pro / iOS 18.5).
4. Packages the resulting `SwiftCamTools.app` into a simulator-only `.ipa` (unsigned; not installable on physical devices) and uploads it as an artifact alongside the raw build log.

Launch it manually whenever you need a fresh build artifact without waiting for the CI pipeline.

After pushing to GitHub, add the following badge at the top of this README (replace `<your-org>` with your account or organization name):

```markdown
[![iOS CI](https://github.com/<your-org>/SwiftCamTools/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/<your-org>/SwiftCamTools/actions/workflows/ios-ci.yml)
```
