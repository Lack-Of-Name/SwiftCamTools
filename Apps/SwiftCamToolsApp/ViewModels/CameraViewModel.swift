#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(Combine)
import Foundation
import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import SwiftCamCore
#if canImport(UIKit)
import UIKit
typealias CameraPreviewImage = UIImage
#else
typealias CameraPreviewImage = AnyObject
#endif

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var mode: CaptureMode = .longExposure {
        didSet {
            guard mode != oldValue else { return }
            cancelCountdown(resetMode: true)
            applyPreset(for: mode)
        }
    }
    @Published var settings: ExposureSettings = ExposureSettings(iso: 1600, duration: 2_000_000_000, bracketOffsets: [-1, 0, 1])
    @Published var histogram: HistogramModel = HistogramModel(samples: [])
    @Published var frameRate: Double = 0
    @Published var lastError: CameraError?
    @Published var isControlsPanelPresented: Bool = false
    @Published var showGridOverlay: Bool = true
    @Published var isCapturing: Bool = false
    @Published var lastCapturedPreview: CameraPreviewImage?
    @Published var isPerformanceConstrained: Bool = false
    @Published var exposureWarning: String?
    @Published var countdownMode: CaptureCountdown = .off
    @Published var countdownSecondsRemaining: Int?
    @Published var previewOrientation: CameraOrientation = .portrait

    var session: AVCaptureSession? { service.session }

    private let service = CameraServiceBridge()
    private let photoSaver = PhotoSaver()
    private var exposureUpdateWorkItem: DispatchWorkItem?
    private var overExposureStrikes = 0
    private var histogramBackoffStrikes = 0
    private var performanceProfile: PerformanceProfile = .full
    private var safetyLimits: ExposureSafetyLimits = ExposureSafetyLimits.forMode(.auto)
    private var countdownTask: Task<Void, Never>?
    private let previewStabilizationEnabled = false
    private let previewDiagnosticsEnabled = false

    init() {
        service.delegate = self
        service.setHistogramEnabled(previewDiagnosticsEnabled)
        applyPreset(for: mode)
    }

    func prepareSession() async {
        await service.prepare()
    }

    var isCaptureLocked: Bool { isCapturing || countdownSecondsRemaining != nil }

    func capture() {
        guard !isCapturing else { return }
        guard countdownSecondsRemaining == nil else { return }
        if mode == .longExposure, countdownMode.seconds > 0 {
            startCountdown()
        } else {
            performCaptureNow()
        }
    }

    func cycleCountdownMode() {
        countdownMode = countdownMode.next()
    }

    private func handleCapturedPhoto(_ photo: AVCapturePhoto) {
        guard let data = photo.fileDataRepresentation() else {
            lastError = .captureFailed("Unable to read captured photo data.")
            return
        }

#if canImport(UIKit)
        if let image = UIImage(data: data) {
            lastCapturedPreview = image
        }
#endif

        photoSaver.savePhotoData(data) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                if case .failure(let error) = result {
                    self.lastError = error
                }
            }
        }
    }

    // MARK: - Manual Control Helpers

    var isoValue: Double { Double(settings.iso) }
    var isAutoISOEnabled: Bool { settings.autoISO }
    var shutterSeconds: Double { Double(settings.duration) / 1_000_000_000.0 }
    var noiseReduction: Double { Double(settings.noiseReductionLevel) }

    func updateISO(_ value: Double) {
        updateSettings { $0.iso = Float(value) }
    }

    func setAutoISO(_ enabled: Bool) {
        updateSettings { $0.autoISO = enabled }
    }

    func updateShutter(seconds: Double) {
        updateSettings { $0.duration = CMTimeValue(seconds * 1_000_000_000.0) }
    }

    func updateNoiseReduction(_ value: Double) {
        updateSettings { $0.noiseReductionLevel = Float(value) }
    }

    func toggleControlsPanel() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isControlsPanelPresented.toggle()
        }
    }

    func resetManualControls() {
        applyPreset(for: mode)
    }

    func openMostRecentPhoto() {
#if canImport(UIKit)
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
#endif
    }

    func updateDeviceOrientation(_ orientation: UIDeviceOrientation) {
#if canImport(UIKit)
        guard let cameraOrientation = orientation.cameraOrientation else { return }
        guard cameraOrientation != previewOrientation else { return }
        previewOrientation = cameraOrientation
        service.updateVideoOrientation(cameraOrientation)
#endif
    }

    private func applyPreset(for mode: CaptureMode) {
        switch mode {
        case .auto:
            settings = ExposureSettings(iso: 400, duration: secondsToDuration(0.02), bracketOffsets: [])
        case .longExposure:
            settings = ExposureSettings(iso: 1600, duration: secondsToDuration(2.0), bracketOffsets: [-1, 0, 1], noiseReductionLevel: 0.7)
        case .bracketed:
            settings = ExposureSettings(iso: 800, duration: secondsToDuration(0.5), bracketOffsets: [-2, 0, 2], noiseReductionLevel: 0.5)
        case .raw:
            settings = ExposureSettings(iso: 200, duration: secondsToDuration(0.125), bracketOffsets: [], noiseReductionLevel: 0.3)
        }
        safetyLimits = ExposureSafetyLimits.forMode(mode)
    }

    private func secondsToDuration(_ seconds: Double) -> CMTimeValue {
        CMTimeValue(seconds * 1_000_000_000.0)
    }

    private func updateSettings(_ mutation: (inout ExposureSettings) -> Void) {
        var copy = settings
        mutation(&copy)
        copy.iso = safetyLimits.clamp(iso: copy.iso)
        copy.duration = safetyLimits.clamp(duration: copy.duration)
        settings = copy
        schedulePreviewUpdate()
    }

    private func schedulePreviewUpdate() {
        exposureUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let previewSettings = self.makePreviewSettings(from: self.settings)
            self.service.applyPreview(settings: previewSettings)
        }
        exposureUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: workItem)
    }

    private func handleExposureDiagnostics(with histogram: HistogramModel) {
        guard !histogram.bins.isEmpty else { return }
        let highlightRatio = histogram.highlightRatio
        if highlightRatio >= safetyLimits.highlightRatioThreshold {
            overExposureStrikes += 1
            histogramBackoffStrikes += 1
            exposureWarning = "Whiteout detected"
            if overExposureStrikes >= safetyLimits.recoveryFrameBudget {
                performWhiteoutRecovery(reason: "Histogram highlight ratio \(highlightRatio)")
            }
            if histogramBackoffStrikes >= 2 {
                service.updateHistogramThrottle(milliseconds: 200)
            }
        } else {
            overExposureStrikes = 0
            histogramBackoffStrikes = 0
            exposureWarning = nil
            if performanceProfile == .full {
                service.updateHistogramThrottle(milliseconds: 80)
            }
        }
    }

    private func performWhiteoutRecovery(reason: String) {
        exposureWarning = "Recovering exposure…"
        if !isAutoISOEnabled {
            setAutoISO(true)
        }
        let reducedISO = max(80, Double(settings.iso) / 2)
        let reducedShutter = max(0.05, shutterSeconds / 2)
        updateSettings { current in
            current.iso = safetyLimits.clamp(iso: Float(reducedISO))
            current.duration = safetyLimits.clamp(duration: secondsToDuration(reducedShutter))
        }
        service.recoverFromWhiteout(reason: reason, revertToAutoExposure: true)
        overExposureStrikes = 0
        histogramBackoffStrikes = 0
    }

    private func applyPerformanceState(_ state: CameraPerformanceState) {
        frameRate = state.frameRate
        guard previewStabilizationEnabled else {
            isPerformanceConstrained = false
            return
        }
        let desiredProfile: PerformanceProfile = state.isConstrained ? .constrained : .full
        guard desiredProfile != performanceProfile else { return }
        performanceProfile = desiredProfile
        switch desiredProfile {
        case .full:
            isPerformanceConstrained = false
            service.updateHistogramThrottle(milliseconds: 80)
            service.setPreviewQuality(.fullResolution)
        case .constrained:
            isPerformanceConstrained = true
            service.updateHistogramThrottle(milliseconds: 150)
            service.setPreviewQuality(.responsive)
        }
    }

    private func performCaptureNow() {
        cancelCountdown()
        isCapturing = true
        service.capture(mode: mode, settings: settings) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let photo):
                    self.handleCapturedPhoto(photo)
                case .failure(let error):
                    self.lastError = error
                }
                self.isCapturing = false
            }
        }
    }

    private func startCountdown() {
        guard countdownSecondsRemaining == nil else { return }
        let duration = countdownMode.seconds
        guard duration > 0 else {
            performCaptureNow()
            return
        }
        countdownSecondsRemaining = duration
        generateCountdownFeedback()
        cancelCountdownTask()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCountdownLoop()
        }
    }

    private func cancelCountdown(resetMode: Bool = false) {
        cancelCountdownTask()
        countdownSecondsRemaining = nil
        if resetMode && mode != .longExposure {
            countdownMode = .off
        }
    }

    @MainActor
    private func runCountdownLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }

            guard let remaining = countdownSecondsRemaining else {
                cancelCountdownTask()
                return
            }

            if remaining <= 1 {
                countdownSecondsRemaining = nil
                cancelCountdownTask()
                performCaptureNow()
                return
            } else {
                countdownSecondsRemaining = remaining - 1
                generateCountdownFeedback()
            }
        }
    }

    private func cancelCountdownTask() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func generateCountdownFeedback() {
#if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
#endif
    }

    private func makePreviewSettings(from _: ExposureSettings) -> ExposureSettings {
        var preview = ExposureSettings()
        preview.duration = safetyLimits.clampPreview(duration: secondsToDuration(1.0 / 60.0))
        preview.autoISO = true
        preview.iso = safetyLimits.minISO
        return preview
    }

    deinit {
        countdownTask?.cancel()
    }
}
#endif
#if canImport(AVFoundation)
extension CameraViewModel: CameraServiceBridgeDelegate {
    nonisolated func cameraServiceBridge(_ bridge: CameraServiceBridge, didUpdateHistogram histogram: HistogramModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.histogram = histogram
            self.handleExposureDiagnostics(with: histogram)
        }
    }

    nonisolated func cameraServiceBridge(_ bridge: CameraServiceBridge, didUpdatePerformance state: CameraPerformanceState) {
        Task { @MainActor [weak self] in
            self?.applyPerformanceState(state)
        }
    }
}
#endif

private enum PerformanceProfile {
    case full
    case constrained
}
