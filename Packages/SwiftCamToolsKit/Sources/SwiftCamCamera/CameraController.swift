#if canImport(AVFoundation) && canImport(Combine)
import Foundation
import AVFoundation
import Combine
import SwiftCamCore
import SwiftCamImaging

public final class CameraController: NSObject, ObservableObject {
    public enum PipelineState {
        case idle
        case running
        case capturing
        case error(CameraError)
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "SwiftCamTools.CameraController")
    private var photoOutput = AVCapturePhotoOutput()
    private let fusionEngine: ImageFusionEngine
    private let configuration: AppConfiguration

    @Published public private(set) var state: PipelineState = .idle
    @Published public private(set) var lastExposure: ExposureSettings = ExposureSettings()

    public init?(configuration: AppConfiguration = AppConfiguration(), fusionEngine: ImageFusionEngine? = nil) {
        guard let reducer = AdaptiveNoiseReducer() else {
            return nil
        }
        let resolvedEngine = fusionEngine ?? ImageFusionEngine(reducer: reducer)
        self.fusionEngine = resolvedEngine
        self.configuration = configuration
        super.init()
        session.sessionPreset = .photo
    }

    public var captureSession: AVCaptureSession {
        session
    }

    public func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            do {
                self.session.inputs.forEach { self.session.removeInput($0) }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    self.state = .error(.configurationFailed("No back camera"))
                    return
                }
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
                self.photoOutput.isHighResolutionCaptureEnabled = true
                self.state = .running
                self.session.startRunning()
            } catch {
                self.state = .error(.configurationFailed(error.localizedDescription))
            }
        }
    }

    private var captureCompletion: ((Result<AVCapturePhoto, CameraError>) -> Void)?

    public func capture(mode: CaptureMode, settings: ExposureSettings, completion: @escaping (Result<AVCapturePhoto, CameraError>) -> Void) {
        lastExposure = settings
        captureCompletion = completion
        sessionQueue.async {
            let photoSettings: AVCapturePhotoSettings
            switch mode {
            case .bracketed:
                let bracketSettings: [AVCaptureBracketedStillImageSettings] = settings.bracketOffsets.map { offset in
                    AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: offset)
                }
                let bracket = AVCapturePhotoBracketSettings(rawPixelFormatType: 0, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc], bracketedSettings: bracketSettings)
                bracket.isLensStabilizationEnabled = true
                photoSettings = bracket
            case .raw:
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: kCVPixelFormatType_14Bayer_RGGB)
            default:
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
            self.state = .capturing
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.state = .error(.captureFailed(error.localizedDescription)) }
            captureCompletion?(.failure(.captureFailed(error.localizedDescription)))
            return
        }
        DispatchQueue.main.async { self.state = .running }
        captureCompletion?(.success(photo))
    }
}
#endif
