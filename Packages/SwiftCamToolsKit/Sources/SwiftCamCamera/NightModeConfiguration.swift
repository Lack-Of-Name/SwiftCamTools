import AVFoundation
import SwiftCamCore

public extension AVCaptureDevice {
    func applyNightPresets(style: NightCaptureStyle) throws {
        try self.lockForConfiguration()
        defer { self.unlockForConfiguration() }
        
        switch style {
        case .off:
            // Unlock configuration and return to .continuousAutoExposure
            if self.isExposureModeSupported(.continuousAutoExposure) {
                self.exposureMode = .continuousAutoExposure
            }
            if self.isFocusModeSupported(.continuousAutoFocus) {
                self.focusMode = .continuousAutoFocus
            }
            if self.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                self.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
        case .deepExposure, .lightTrails:
            // Lock the device configuration. Set specific "Handheld Night" values
            // ISO ~1200, Duration 1/15s - 1/30s
            
            let targetISO = min(max(1200.0, self.activeFormat.minISO), self.activeFormat.maxISO)
            let targetDuration = CMTime(value: 1, timescale: 30) // 1/30s
            
            // Ensure duration is within supported range
            let safeDuration = max(self.activeFormat.minExposureDuration, min(targetDuration, self.activeFormat.maxExposureDuration))
            
            self.setExposureModeCustom(duration: safeDuration, iso: targetISO, completionHandler: nil)
            
            if self.isFocusModeSupported(.locked) {
                self.focusMode = .locked
            }
            
            if self.isWhiteBalanceModeSupported(.locked) {
                self.whiteBalanceMode = .locked
            }
        }
    }
}
