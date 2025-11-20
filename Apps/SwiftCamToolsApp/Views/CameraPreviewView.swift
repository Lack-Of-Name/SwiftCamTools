#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import UIKit
import SwiftCamCore

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession?
    let orientation: AVCaptureVideoOrientation

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setVideoOrientation(orientation)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.session = session
        uiView.setVideoOrientation(orientation)
    }
}
#endif

#if canImport(UIKit) && canImport(AVFoundation)
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set {
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.session = newValue
        }
    }

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        guard let connection = previewLayer.connection else { return }
        if #available(iOS 17.0, *) {
            let angle = orientation.rotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }
}
#endif
