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
    @Published var settings: ExposureSettings = CameraViewModel.defaultSettings
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
    @Published var nightCaptureStyle: NightCaptureStyle = .off
    @Published var isAutoNightDurationEnabled: Bool = true
    
    // MSR Parameters
    @Published var msrGain: Float = 12.0 { didSet { updateSettings { $0.msrGain = msrGain } } }
    @Published var msrOffset: Float = 0.0 { didSet { updateSettings { $0.msrOffset = msrOffset } } }
    @Published var msrSaturation: Float = 1.2 { didSet { updateSettings { $0.msrSaturation = msrSaturation } } }

    var session: AVCaptureSession? { service.session }

    private static let defaultAperture: Float = 1.8
    private static let defaultSettings = ExposureSettings(
        iso: 100,
        duration: CMTimeValue(1_000_000_000 / 60),
        bracketOffsets: [],
        noiseReductionLevel: 0.85,
        autoISO: true,
        aperture: defaultAperture,
        exposureBias: 0.0,
        autoFocus: true,
        autoAperture: true,
        colorSaturation: 1.0
    )
    private let service = CameraServiceBridge()
    private let photoSaver = PhotoSaver()
    private var exposureUpdateWorkItem: DispatchWorkItem?
    private var overExposureStrikes = 0
    private var histogramBackoffStrikes = 0
    private var performanceProfile: PerformanceProfile = .full
    private var safetyLimits: ExposureSafetyLimits = .longExposureDefaults
    private var countdownTask: Task<Void, Never>?
    private let previewStabilizationEnabled = false
    private let previewDiagnosticsEnabled = false
    private static let shutterPresetStops: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8, 15, 30, 60]
    private var lastAutoPreviewRefresh = Date.distantPast
    private let autoPreviewRefreshInterval: TimeInterval = 2.0

    init() {
        service.delegate = self
        service.setHistogramEnabled(previewDiagnosticsEnabled)
        schedulePreviewUpdate()
    }

    func prepareSession() async {
        await service.prepare()
        service.configureLowPowerPreview()
        
        // Update safety limits based on hardware
        let minISO = service.minISO
        let maxISO = service.maxISO
        let minDuration = service.minExposureDuration
        
        self.safetyLimits = ExposureSafetyLimits(
            minISO: minISO,
            maxISO: maxISO,
            minShutterSeconds: minDuration,
            maxShutterSeconds: 30.0, // Allow up to 30s for software long exposure
            previewMaxShutterSeconds: 0.08,
            highlightRatioThreshold: 0.88,
            recoveryFrameBudget: 4,
            recoveryISO: 400,
            recoveryShutterSeconds: 0.5
        )
        
        refreshPreviewExposure()
    }

    var isCaptureLocked: Bool { isCapturing || countdownSecondsRemaining != nil }

    func capture() {
        guard !isCapturing else { return }
        guard countdownSecondsRemaining == nil else { return }
        if countdownMode.seconds > 0 {
            startCountdown()
        } else {
            performCaptureNow()
        }
    }

    func cycleCountdownMode() {
        countdownMode = countdownMode.next()
    }

    private func handleCapturedData(_ data: Data) {
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
    var apertureValue: Double { Double(settings.aperture) }
    var exposureBiasValue: Double { Double(settings.exposureBias) }
    var saturationValue: Double { Double(settings.colorSaturation) }
    var isAutofocusEnabled: Bool { settings.autoFocus }
    var isAutoApertureEnabled: Bool { settings.autoAperture }
    
    var shutterPresets: [Double] {
        let min = service.minExposureDuration
        // If max is 0 (uninitialized), assume a safe default (e.g. 1.0s) so the slider isn't broken at startup.
        let max = service.maxExposureDuration > 0 ? service.maxExposureDuration : 1.0
        
        // Extended range of standard stops
        let stops = [
            1.0/8000.0, 1.0/4000.0, 1.0/2000.0, 1.0/1000.0, 1.0/500.0, 1.0/250.0, 1.0/125.0, 1.0/60.0, 1.0/30.0, 1.0/15.0,
            0.125, 0.25, 0.5, 1, 2, 4, 8, 15, 30, 60
        ]
        
        // Filter to device capabilities
        // We use a small epsilon for float comparison to avoid excluding valid values due to precision
        let valid = stops.filter { $0 >= min - 0.00001 && $0 <= max + 0.00001 }
        
        // Always return at least one value. If valid is empty, return the current setting or min.
        if valid.isEmpty {
            return [Swift.max(min, Swift.min(shutterSeconds, max))]
        }
        return valid
    }
    
    var isoRange: ClosedRange<Double> {
        Double(service.minISO)...Double(service.maxISO)
    }
    
    var shutterRange: ClosedRange<Double> {
        let min = service.minExposureDuration
        let max = service.maxExposureDuration > 0 ? service.maxExposureDuration : 1.0
        // Ensure range is valid
        return min...Swift.max(min + 0.0001, max)
    }

    func updateISO(_ value: Double) {
        updateSettings { $0.iso = Float(value) }
    }

    func setAutoISO(_ enabled: Bool) {
        updateSettings { $0.autoISO = enabled }
    }

    func updateShutter(seconds: Double) {
        updateSettings { $0.duration = CMTimeValue(seconds * 1_000_000_000.0) }
    }

    func updateAperture(_ value: Double) {
        updateSettings {
            $0.autoAperture = false
            $0.aperture = Float(value)
        }
    }

    func updateExposureBias(_ value: Double) {
        updateSettings { $0.exposureBias = Float(value) }
    }

    func updateSaturation(_ value: Double) {
        updateSettings { $0.colorSaturation = Float(value) }
    }

    func setAutofocusEnabled(_ enabled: Bool) {
        updateSettings { $0.autoFocus = enabled }
    }

    func setAutoApertureEnabled(_ enabled: Bool) {
        updateSettings {
            $0.autoAperture = enabled
            if enabled {
                $0.aperture = Self.defaultAperture
            }
        }
    }

    func toggleControlsPanel() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isControlsPanelPresented.toggle()
        }
    }

    func resetManualControls() {
        settings = Self.defaultSettings
        schedulePreviewUpdate()
    }

    func setAutoNightDurationEnabled(_ enabled: Bool) {
        isAutoNightDurationEnabled = enabled
    }

    func setNightCaptureStyle(_ style: NightCaptureStyle) {
        nightCaptureStyle = style
        service.applyNightPresets(style: style)
    }

    func updateLongExposure(seconds: Double) {
        updateSettings { $0.duration = self.secondsToDuration(seconds) }
    }
    
    var longExposureSeconds: Double {
        shutterSeconds
    }
    
    var longExposureRange: ClosedRange<Double> {
        1.0...30.0
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
            self.recordPreviewRefresh()
        }
        exposureUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: workItem)
    }

    private func refreshPreviewExposure() {
        let previewSettings = makePreviewSettings(from: settings)
        service.applyPreview(settings: previewSettings)
        recordPreviewRefresh()
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

        nudgeAutoPreviewIfNeeded()
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
        service.capture(settings: settings) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let data):
                    self.handleCapturedData(data)
                case .failure(let error):
                    self.lastError = error
                }
                self.isCapturing = false
                self.refreshPreviewExposure()
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

    private func cancelCountdown() {
        cancelCountdownTask()
        countdownSecondsRemaining = nil
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

    private func makePreviewSettings(from source: ExposureSettings) -> ExposureSettings {
        var preview = source
        
        // Clamp duration for responsive preview
        let originalDuration = Double(source.duration) / 1_000_000_000.0
        let previewDuration = safetyLimits.clampPreview(durationSeconds: originalDuration)
        preview.duration = secondsToDuration(previewDuration)
        
        // If manual exposure, compensate ISO for the shorter preview shutter
        if !source.autoISO {
            let exposureFactor = originalDuration / previewDuration
            let compensatedISO = Float(source.iso) * Float(exposureFactor)
            preview.iso = safetyLimits.clamp(iso: compensatedISO)
        }
        
        return preview
    }

    private func nudgeAutoPreviewIfNeeded() {
        guard settings.autoISO else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoPreviewRefresh) >= autoPreviewRefreshInterval else { return }
        refreshPreviewExposure()
    }

    private func recordPreviewRefresh() {
        lastAutoPreviewRefresh = Date()
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
