import AVFoundation
import Foundation

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "LightWatch.CameraOutput")
    private var captureInterval: TimeInterval
    private var lastDeliveredAt: Date?
    private var isConfigured = false

    init(captureInterval: TimeInterval) {
        self.captureInterval = captureInterval
        super.init()
    }

    func start() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.isConfigured {
                    try self.configureSession()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } catch {
                self.onError?("カメラ開始に失敗しました: \(error.localizedDescription)")
            }
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

    func update(captureInterval: TimeInterval) {
        outputQueue.async { [weak self] in
            self?.captureInterval = captureInterval
        }
    }

    private func configureSession() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in
                semaphore.signal()
            }
            semaphore.wait()
        case .denied, .restricted:
            throw CameraError.permissionDenied
        @unknown default:
            throw CameraError.permissionDenied
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.deviceNotFound
        }

        session.beginConfiguration()
        session.sessionPreset = .low

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.inputUnavailable
        }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
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
