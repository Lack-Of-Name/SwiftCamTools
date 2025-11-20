import Foundation
import SwiftCamCore

#if canImport(Photos)
import Photos

struct PhotoSaver {
    func savePhotoData(_ data: Data, completion: @escaping (Result<Void, CameraError>) -> Void) {
        func persistPhoto() {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, data: data, options: options)
            }) { success, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(.captureFailed(error.localizedDescription)))
                    } else if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(.captureFailed("Photo Library rejected the asset.")))
                    }
                }
            }
        }

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch currentStatus {
        case .authorized, .limited:
            persistPhoto()
        case .denied, .restricted:
            completion(.failure(.authorizationDenied))
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        persistPhoto()
                    } else {
                        completion(.failure(.authorizationDenied))
                    }
                }
            }
        @unknown default:
            completion(.failure(.authorizationDenied))
        }
    }
}
#else
struct PhotoSaver {
    func savePhotoData(_ data: Data, completion: @escaping (Result<Void, CameraError>) -> Void) {
        completion(.success(()))
    }
}
#endif
