import AVFoundation
import Foundation

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "LightWatch.CameraOutput")
    private var captureInterval: TimeInterval
    private var cameraUniqueID: String
    private var lastDeliveredAt: Date?
    private var isConfigured = false

    init(captureInterval: TimeInterval, cameraUniqueID: String) {
        self.captureInterval = captureInterval
        self.cameraUniqueID = cameraUniqueID
        super.init()
    }

    func start() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.startConfiguredSession()
            case .notDetermined:
                self.onStatus?("カメラ権限の許可待ちです。")
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    self?.outputQueue.async {
                        guard let self else { return }
                        if granted {
                            self.startConfiguredSession()
                        } else {
                            self.onError?("カメラ開始に失敗しました: \(CameraError.permissionDenied.localizedDescription)")
                        }
                    }
                }
            case .denied, .restricted:
                self.onError?("カメラ開始に失敗しました: \(CameraError.permissionDenied.localizedDescription)")
            @unknown default:
                self.onError?("カメラ開始に失敗しました: \(CameraError.permissionDenied.localizedDescription)")
            }
        }
    }

    private func startConfiguredSession() {
        do {
            if !isConfigured {
                try configureSession()
            }
            if !session.isRunning {
                session.startRunning()
                scheduleCameraControlsLock()
                onStatus?("カメラ監視を開始しました: \(activeCameraName())")
            }
        } catch {
            onError?("カメラ開始に失敗しました: \(error.localizedDescription)")
        }
    }

    func stop() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func update(captureInterval: TimeInterval, cameraUniqueID: String) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.captureInterval = captureInterval
            guard self.cameraUniqueID != cameraUniqueID else {
                return
            }
            self.cameraUniqueID = cameraUniqueID
            do {
                let wasRunning = self.session.isRunning
                try self.configureSession()
                if wasRunning && !self.session.isRunning {
                    self.session.startRunning()
                }
                self.onStatus?("カメラ設定を更新しました: \(self.activeCameraName())")
            } catch {
                self.onError?("カメラ設定の更新に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func configureSession() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.permissionDenied
        }

        let device: AVCaptureDevice?
        if cameraUniqueID.isEmpty {
            device = AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice(uniqueID: cameraUniqueID)
        }

        guard let device else {
            throw CameraError.deviceNotFound
        }

        prepareAutomaticCameraControls(for: device)

        session.beginConfiguration()
        session.sessionPreset = .low
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.inputUnavailable
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraError.outputUnavailable
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()
        isConfigured = true
    }

    private func prepareAutomaticCameraControls(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            onError?("カメラ自動調整の準備に失敗しました: \(error.localizedDescription)")
        }
    }

    private func scheduleCameraControlsLock() {
        outputQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.session.isRunning else { return }
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            self.lockCameraControls(for: input.device)
        }
    }

    private func lockCameraControls(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }

            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        } catch {
            onError?("カメラ露出固定に失敗しました: \(error.localizedDescription)")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        if let lastDeliveredAt, now.timeIntervalSince(lastDeliveredAt) < captureInterval {
            return
        }
        lastDeliveredAt = now
        onSampleBuffer?(sampleBuffer)
    }

    private func activeCameraName() -> String {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else {
            return "未設定"
        }
        return input.device.localizedName
    }
}

struct CameraDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
}

enum CameraDeviceCatalog {
    static func availableOptions() -> [CameraDeviceOption] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        .devices
            .map { CameraDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum CameraError: LocalizedError {
    case permissionDenied
    case deviceNotFound
    case inputUnavailable
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "カメラ権限がありません。"
        case .deviceNotFound:
            return "Webカメラが見つかりません。"
        case .inputUnavailable:
            return "カメラ入力を追加できません。"
        case .outputUnavailable:
            return "カメラ出力を追加できません。"
        }
    }
}
