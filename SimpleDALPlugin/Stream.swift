//
//  Stream.swift
//  SimpleDALPlugin
//
//  Created by 池上涼平 on 2020/04/25.
//  Copyright © 2020 com.seanchas116. All rights reserved.
//

import Foundation

class Stream: Object {
    var objectID: CMIOObjectID = 0
    let name = "MultiCam"
    let width = 1280
    let height = 720
    let frameRate = 60

    private var sequenceNumber: UInt64 = 0
    private var queueAlteredProc: CMIODeviceStreamQueueAlteredProc?
    private var queueAlteredRefCon: UnsafeMutableRawPointer?

    private lazy var formatDescription: CMVideoFormatDescription? = {
        var formatDescription: CMVideoFormatDescription?
        let error = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32ARGB,
            width: Int32(width), height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard error == noErr else {
            log("CMVideoFormatDescriptionCreate Error: \(error)")
            return nil
        }
        return formatDescription
    }()

    private lazy var clock: CFTypeRef? = {
        var clock: Unmanaged<CFTypeRef>? = nil

        let error = CMIOStreamClockCreate(
            kCFAllocatorDefault,
            "MultiCam clock" as CFString,
            Unmanaged.passUnretained(self).toOpaque(),
            CMTimeMake(value: 1, timescale: 10),
            100, 10,
            &clock);
        guard error == noErr else {
            log("CMIOStreamClockCreate Error: \(error)")
            return nil
        }
        return clock?.takeUnretainedValue()
    }()

    private lazy var queue: CMSimpleQueue? = {
        var queue: CMSimpleQueue?
        let error = CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: 30,
            queueOut: &queue)
        guard error == noErr else {
            log("CMSimpleQueueCreate Error: \(error)")
            return nil
        }
        return queue
    }()

    private lazy var timer: DispatchSourceTimer = {
      let interval = 1.0 / Double(frameRate)
      let timer = DispatchSource.makeTimerSource()
      let repeatTime = 1000 / frameRate
      timer.schedule(deadline: .now() + interval, repeating: .milliseconds(repeatTime))
        timer.setEventHandler(handler: { [weak self] in
            self?.enqueueBuffer()
        })
        return timer
    }()

    lazy var properties: [Int : Property] = [
        kCMIOObjectPropertyName: Property(name),
        kCMIOStreamPropertyFormatDescription: Property(formatDescription!),
        kCMIOStreamPropertyFormatDescriptions: Property([formatDescription!] as CFArray),
        kCMIOStreamPropertyDirection: Property(UInt32(0)),
        kCMIOStreamPropertyFrameRate: Property(Float64(frameRate)),
        kCMIOStreamPropertyFrameRates: Property(Float64(frameRate)),
        kCMIOStreamPropertyMinimumFrameRate: Property(Float64(frameRate)),
        kCMIOStreamPropertyFrameRateRanges: Property(AudioValueRange(mMinimum: Float64(frameRate), mMaximum: Float64(frameRate))),
        kCMIOStreamPropertyClock: Property(CFTypeRefWrapper(ref: clock!)),
    ]
  
  var camera: Camera = Camera()

    func start() {
      self.camera.start()
      timer.resume()
    }

    func stop() {
      self.camera.stop()
      timer.suspend()
      log("stopping")
    }

    func copyBufferQueue(queueAlteredProc: CMIODeviceStreamQueueAlteredProc?, queueAlteredRefCon: UnsafeMutableRawPointer?) -> CMSimpleQueue? {
        self.queueAlteredProc = queueAlteredProc
        self.queueAlteredRefCon = queueAlteredRefCon
        return self.queue
    }

    private func createPixelBuffer() -> CVPixelBuffer? {
      if let image = self.camera.getLastImage() {
        return image
      }
      
      // fall back if no frames available yet
      let pixelBuffer = CVPixelBuffer.create(size: CGSize(width: width, height: height))
      return pixelBuffer
    }

    private func enqueueBuffer() {
      guard let queue = queue else {
          log("queue is nil")
          return
      }

      guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
          log("queue is full")
          return
      }
      
      // attempt to use the cameras sample time
//      if let ls = self.camera.lastGoodSample {
//        let sample: Unmanaged<CMSampleBuffer> = Unmanaged.passRetained(ls)
//
//        CMSimpleQueueEnqueue(queue, element: sample.toOpaque())
//        queueAlteredProc?(objectID, sample.toOpaque(), queueAlteredRefCon)
//        return
//      }

      guard let pixelBuffer = createPixelBuffer() else {
          log("pixelBuffer is nil")
          return
      }

      let scale = UInt64(frameRate) * 100
      let duration = CMTime(value: CMTimeValue(scale / UInt64(frameRate)), timescale: CMTimeScale(scale))
      let timestamp = CMTime(value: duration.value * CMTimeValue(sequenceNumber), timescale: CMTimeScale(scale))

      var timing = CMSampleTimingInfo(
          duration: duration,
          presentationTimeStamp: timestamp,
          decodeTimeStamp: timestamp
      )

      var error = noErr

      error = CMIOStreamClockPostTimingEvent(timestamp, mach_absolute_time(), false, clock)
      guard error == noErr else {
          log("CMSimpleQueueCreate Error: \(error)")
          return
      }

      var formatDescription: CMFormatDescription?
      error = CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: pixelBuffer,
          formatDescriptionOut: &formatDescription)
      guard error == noErr else {
          log("CMVideoFormatDescriptionCreateForImageBuffer Error: \(error)")
          return
      }

      var sampleBufferUnmanaged: Unmanaged<CMSampleBuffer>? = nil
      error = CMIOSampleBufferCreateForImageBuffer(
          kCFAllocatorDefault,
          pixelBuffer,
          formatDescription,
          &timing,
          sequenceNumber,
          UInt32(kCMIOSampleBufferNoDiscontinuities),
          &sampleBufferUnmanaged
      )
      guard error == noErr else {
          log("CMIOSampleBufferCreateForImageBuffer Error: \(error)")
          return
      }
    
      CMSimpleQueueEnqueue(queue, element: sampleBufferUnmanaged!.toOpaque())
      queueAlteredProc?(objectID, sampleBufferUnmanaged!.toOpaque(), queueAlteredRefCon)
      sequenceNumber += 1
    }
}
