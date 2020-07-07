//
//  Camera.swift
//  SimpleDALPlugin
//
//  Created by Kevin Doveton on 4/7/20.
//  Copyright © 2020 com.kdoveton. All rights reserved.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import Vision

class Camera: NSObject {
  let sequenceHandler = VNSequenceRequestHandler()
  var captureSession: AVCaptureSession;

  override init() {
    self.captureSession = AVCaptureSession()
    self.captureSession.sessionPreset = AVCaptureSession.Preset.high
  }

  func start() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: // The user has previously granted access to the camera.
      self.setupCaptureSession()

    case .notDetermined: // The user has not yet been asked for camera access.
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted {
          self.setupCaptureSession()
        }
      }

    case .denied: // The user has previously denied access.
      print("no access to camera, denied")
      return
    case .restricted: // The user can't grant access due to restrictions.
      print("no access to camera, restricted")
      return
    }
  }

  func setupCaptureSession() {
    let deviceDescoverySession = AVCaptureDevice.DiscoverySession.init(deviceTypes: [
      AVCaptureDevice.DeviceType.builtInWideAngleCamera,
      AVCaptureDevice.DeviceType.externalUnknown
    ],
        mediaType: AVMediaType.video,
        position: AVCaptureDevice.Position.unspecified)

    do {
      captureSession.beginConfiguration()

      if captureSession.canSetSessionPreset(AVCaptureSession.Preset.high) {
        captureSession.sessionPreset = AVCaptureSession.Preset.high
        print("set preset")
      } else {
        print("no preset")
      }
      
      let imageQueue = DispatchQueue(label: "sample-buffer")


      for device in deviceDescoverySession.devices {
        // prevent the camera detecting itself as an input source
        if device.manufacturer == "Kevin Doveton" {
          continue
        }
        let captureInput = try AVCaptureDeviceInput(device: device)

        if !captureSession.canAddInput(captureInput) {
          print("Can't add input")
          return;
        }

        captureSession.addInputWithNoConnections(captureInput)
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: imageQueue)
        videoOutput.connection(with: AVMediaType.video)?.videoOrientation = AVCaptureVideoOrientation.landscapeRight
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        
        if !captureSession.canAddOutput(videoOutput) {
          print("can not add output")
          return
        }
        
        captureSession.addOutputWithNoConnections(videoOutput)
        
        for port in captureInput.ports {
        
          if port.mediaType == .video {
            let connection = AVCaptureConnection(inputPorts: [port], output: videoOutput)

            if captureSession.canAddConnection(connection) {
              captureSession.addConnection(connection)
              let camera = SingleCamera(connection: connection)
              camera.makeCameraInactive()
              self.allCameras.append(camera)
            }
          }
        }

        print("added connection")
      }

      captureSession.commitConfiguration()
      captureSession.startRunning()
      
      lock.lock()
      if let cam = self.allCameras.first {
        log("Camera is active")
        cam.makeCameraActive()
      }
      lock.unlock()
      log(captureSession.connections)
      log(self.allCameras.count)
    } catch {
      log("encountered an error")
    }
  }


  func stop() {
    self.captureSession.stopRunning()
    self.captureSession.inputs.forEach { input in
      self.captureSession.removeInput(input)
    }
  }

  private var previewLayer = CALayer()
  func getPreviewLayer() -> CALayer {
    let preview = self.previewLayer
    preview.contents = self.lastGoodImage
    preview.contentsGravity = CALayerContentsGravity.center
    
    return preview
  }
  
  private var lastGoodImage: CVImageBuffer?;
  private var currentConnection: AVCaptureConnection?;
  func getLastImage() -> CVImageBuffer? {
    return self.lastGoodImage
  }
  
  var lastGoodSample: CMSampleBuffer?
  
  var allCameras: [SingleCamera] = []
}

let lock = NSLock()

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ out: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from input: AVCaptureConnection) {
    let camera: SingleCamera? = self.allCameras.first(where: { (camera: SingleCamera) -> Bool in
      return camera.connection === input
    })
    
//
//    lock.lock()
//    var thereIsAActiveCamera: Bool = false
//    for cam in self.allCameras {
//      if cam.active {
//        if thereIsAActiveCamera {
//          cam.makeCameraInactive()
//          continue
//        }
//
//        thereIsAActiveCamera = true
//      }
//    }
//
//    if !thereIsAActiveCamera {
//      camera?.makeCameraActive()
//    }
//    lock.unlock()
    
    guard let imageBuffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }
    
    if camera?.active ?? false {
      self.lastGoodSample = sampleBuffer
      self.lastGoodImage = imageBuffer
    }
    
    // check if we need to run face detection
    if camera?.lastFaceCheck != nil && (camera?.lastFaceCheck!.addingTimeInterval(0.5))! > Date() {
      return
    }
    
    let detectFaceRequest = VNDetectFaceLandmarksRequest(completionHandler: {(request: VNRequest, _: Error?) -> Void in
      let camera: SingleCamera? = self.allCameras.first(where: { (camera: SingleCamera) -> Bool in
        return camera.connection === input
      })
              
      if let c = camera {
        c.lastFaceCheck = Date()
        
        guard let results = request.results as? [VNFaceObservation] else {
          return
        }
        
        let foundLandmarks = results.count > 0
        if foundLandmarks {
          c.hasLeftEye = results[0].landmarks?.leftEye != nil && results[0].landmarks?.leftPupil != nil
          c.hasRightEye = results[0].landmarks?.rightEye != nil && results[0].landmarks?.rightPupil != nil
          c.confidence = results[0].landmarks?.confidence ?? 0

          if c.hasLeftEye && c.hasRightEye {
            var lastSwitch: Date? = nil;
            var highestConfidence = c.confidence
            for cam in self.allCameras {
              if cam.connection != input {
                if cam.active {
                  lastSwitch = cam.becameActiveAt!
                }

                if cam.confidence > highestConfidence && cam.active {
                  highestConfidence = cam.confidence
                }
              }
            }

            if highestConfidence == c.confidence && !c.active {
              if lastSwitch != nil && lastSwitch! > Date().addingTimeInterval(-3) {
                return
              }
              
              
              lock.lock()
              c.makeCameraActive()
              for cam in self.allCameras {
                if cam.connection != input {
                  cam.makeCameraInactive()
                }
              }
              lock.unlock()
            }
          }
        } else {
          c.hasLeftEye = false
          c.hasRightEye = false
          c.confidence = 0
        }
      }
    })
    
    do {
      try self.sequenceHandler.perform(
        [detectFaceRequest],
        on: imageBuffer
      )
    } catch {
      print(error.localizedDescription)
    }
  }
}

extension AVCaptureDevice {
    func set(frameRate: Double) {
      print(frameRate)
      print(activeFormat.videoSupportedFrameRateRanges.first!.minFrameRate)
    guard let range = activeFormat.videoSupportedFrameRateRanges.first,
        range.minFrameRate...range.maxFrameRate ~= frameRate
        else {
            print("Requested FPS is not supported by the device's activeFormat !")
            return
    }

    do { try lockForConfiguration()
        activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
        activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
        unlockForConfiguration()
    } catch {
        print("LockForConfiguration failed with error: \(error.localizedDescription)")
    }
  }
}

class SingleCamera {
  var hasLeftEye: Bool
  var hasRightEye: Bool
  var confidence: Float
  var connection: AVCaptureConnection
  var active: Bool
  var becameActiveAt: Date?
  var lastFaceCheck: Date?
  
  init(connection: AVCaptureConnection) {
    self.connection = connection
    self.hasLeftEye = false
    self.hasRightEye = false
    self.active = false
    self.confidence = 0
  }
  
  func makeCameraActive() {
    self.active = true
    self.becameActiveAt = Date()
  }
  
  func makeCameraInactive() {
    self.active = false
    self.becameActiveAt = nil
  }
}
