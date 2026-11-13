import AVFoundation
import UIKit

class IPhoneCameraManager: NSObject {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private let context = CIContext()
  private var isRunning = false

  var onFrameCaptured: ((UIImage) -> Void)?

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.captureSession.stopRunning()
      self?.isRunning = false
    }
  }

  private func configureSession() {
    captureSession.beginConfiguration()
    // 720p instead of .medium (480x360): the live frames sent to the model are
    // downscaled anyway, but look_closely needs a sharp frame to read text from.
    captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    NSLog("[iPhoneCamera] Session configured")
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let image = UIImage(cgImage: cgImage)

    onFrameCaptured?(image)
  }
}
