import Foundation
import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import SwiftCamCore

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var mode: CaptureMode = .longExposure {
        didSet { applyPreset(for: mode) }
    }
    @Published var settings: ExposureSettings = ExposureSettings(iso: 1600, duration: 2_000_000_000, bracketOffsets: [-1, 0, 1])
    @Published var histogram: HistogramModel = HistogramModel(samples: [])
    @Published var lastError: CameraError?
    @Published var isControlDrawerPresented: Bool = false
    @Published var showGridOverlay: Bool = true

    var session: AVCaptureSession? {
        service.session
    }

    private let service = CameraServiceBridge()

    init() {
        applyPreset(for: mode)
    }

    func prepareSession() async {
        await service.prepare()
    }

    func capture() {
        service.capture(mode: mode, settings: settings) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let photo):
                if let buffer = photo.pixelBuffer {
                    self.histogram = HistogramModel(samples: sampleLuma(from: buffer))
                }
            case .failure(let error):
                self.lastError = error
            }
        }
    }

    private func sampleLuma(from buffer: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values: [Double] = []
        for row in 0..<height {
            let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in stride(from: 0, to: width * 4, by: 4) {
                values.append(Double(rowPointer[column]) / 255.0)
            }
        }
        return values
    }

    // MARK: - Manual Control Helpers

    var isoValue: Double {
        Double(settings.iso)
    }

    var shutterSeconds: Double {
        Double(settings.duration) / 1_000_000_000.0
    }

    var noiseReduction: Double {
        Double(settings.noiseReductionLevel)
    }

    func updateISO(_ value: Double) {
        updateSettings { $0.iso = Float(value) }
    }

    func updateShutter(seconds: Double) {
        updateSettings { $0.duration = CMTimeValue(seconds * 1_000_000_000.0) }
    }

    func updateNoiseReduction(_ value: Double) {
        updateSettings { $0.noiseReductionLevel = Float(value) }
    }

    func toggleDrawer() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isControlDrawerPresented.toggle()
        }
    }

    func resetManualControls() {
        applyPreset(for: mode)
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
    }

    private func secondsToDuration(_ seconds: Double) -> CMTimeValue {
        CMTimeValue(seconds * 1_000_000_000.0)
    }

    private func updateSettings(_ mutation: (inout ExposureSettings) -> Void) {
        var copy = settings
        mutation(&copy)
        settings = copy
    }
}
