import AppKit
import AVFoundation
import Vision
import CoreImage

struct CameraSnapshot {
    var image: CGImage?
    var target: CGRect?
    var message = "Connect your Logitech C930e, then click Connect."
    var focus = 0, minimum = 0, maximum = 255, step = 5
    var sharpness = 0.0
    var confidence: Float = 0
    var connected = false, active = false, lost = false, acquiring = false
}

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onUpdate: ((CameraSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "com.left47.minifocus.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var usb: OpaquePointer?
    private var original = FocusUSBState()
    private var snapshot = CameraSnapshot()
    private var tracker: VNTrackObjectRequest?
    private var sequence = VNSequenceRequestHandler()
    private var sweep: FocusSweep?
    private var lower = 0, upper = 255, stableFocus = 0
    private var nextSweepAt = 0.0, lastProcessed = 0.0, lastFrameAt = 0.0, lastReadAt = 0.0
    private var wantsTracking = true
    private var acquisition = AcquisitionGate()
    private var acquiring: Bool { acquisition.isAcquiring }
    private var watchdog: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var diagnosticFrames = 0
    var diagnostic = false

    private func publish() {
        snapshot.acquiring = acquiring
        let value = snapshot
        DispatchQueue.main.async { self.onUpdate?(value) }
    }
    private func fail(_ message: String) {
        sweep = nil; acquisition.cancel(); snapshot.active = false; snapshot.message = message; publish()
    }
    func connect() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: queue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async {
                    if granted { self.configure() }
                    else { self.fail("Camera permission denied. Enable MiniFocus in System Settings → Privacy & Security → Camera.") }
                }
            }
        default: queue.async { self.fail("Enable MiniFocus in System Settings → Privacy & Security → Camera, then reconnect.") }
        }
    }
    private func configure() {
        guard usb == nil else { return }
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = focus_open(&original, &error, Int32(error.count)) else { fail(String(cString: error)); return }
        usb = handle
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .video, position: .unspecified).devices
        let candidates = cameras.filter { $0.localizedName.localizedCaseInsensitiveContains("C930") }
        guard candidates.count == 1, let device = candidates.first else {
            focus_close(handle); usb = nil
            fail("Could not identify exactly one C930e video device. Disconnect duplicate cameras and try again."); return
        }
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw NSError(domain: "MiniFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable. Close other camera settings apps and reconnect."]) }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw NSError(domain: "MiniFocus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot receive camera frames."]) }
            session.addOutput(output)
        } catch {
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            focus_close(handle); usb = nil; fail(error.localizedDescription); return
        }
        snapshot.focus = Int(original.focus); stableFocus = snapshot.focus
        snapshot.minimum = Int(original.minimum); snapshot.maximum = Int(original.maximum); snapshot.step = Int(original.step)
        lower = snapshot.minimum; upper = snapshot.maximum
        snapshot.connected = true
        snapshot.message = "Waiting for camera frames…"
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera interrupted."
            self?.queue.async { self?.holdForLoss("Camera error: \(detail) Reconnect to recover.") }
        }
        session.startRunning()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastFrameAt > 2 {
                self.holdForLoss("No camera frames. Check the connection and OBS camera settings, then reconnect.")
            }
        }
        watchdog = timer; timer.resume(); publish()
        if diagnostic { print("DIAGNOSTIC connected: \(device.localizedName); focus=\(snapshot.focus); range=\(lower)...\(upper); step=\(snapshot.step)"); fflush(stdout) }
    }
    func select(_ rectangle: CGRect) {
        queue.async {
            guard self.snapshot.connected else { return }
            self.pauseAtStable()
            self.snapshot.target = rectangle; self.snapshot.lost = false; self.snapshot.confidence = 1
            self.resetTracker(rectangle)
            self.startNow(wide: true, minimum: self.lower, maximum: self.upper)
            self.publish()
        }
    }
    private func resetTracker(_ rectangle: CGRect) {
        sequence = VNSequenceRequestHandler()
        tracker = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rectangle))
        tracker?.trackingLevel = .accurate
    }
    func setTracking(_ enabled: Bool) {
        queue.async {
            self.wantsTracking = enabled
            if let rect = self.snapshot.target { self.resetTracker(rect) }
        }
    }
    func start(wide: Bool, minimum: Int, maximum: Int) {
        queue.async { self.startNow(wide: wide, minimum: minimum, maximum: maximum) }
    }
    private func startNow(wide: Bool, minimum: Int, maximum: Int) {
            guard let usb = self.usb, self.snapshot.target != nil, !self.snapshot.lost,
                  ProcessInfo.processInfo.systemUptime - self.lastFrameAt < 2 else { return }
            let step = self.snapshot.step, hardwareMin = self.snapshot.minimum
            guard minimum >= hardwareMin, maximum <= self.snapshot.maximum, maximum > minimum,
                  (minimum-hardwareMin) % step == 0, (maximum-hardwareMin) % step == 0 else {
                self.snapshot.message = "Search limits must be within the camera range, on steps of \(step)."; self.publish(); return
            }
            self.lower = minimum; self.upper = maximum
            guard focus_manual(usb) != 0 else { self.fail("Could not disable native autofocus. Close other camera control apps and retry."); return }
            let clamped = min(max(self.snapshot.focus, minimum), maximum)
            guard self.move(to: clamped) else { return }
            self.stableFocus = clamped; self.snapshot.active = true
            self.beginSweep(wide: wide, at: ProcessInfo.processInfo.systemUptime)
            self.publish()
    }
    private func move(to position: Int) -> Bool {
        guard let usb = usb, focus_write(usb, Int32(position)) != 0 else {
            fail("Focus write failed. Tracking stopped; use Stop & restore, then reconnect."); return false
        }
        snapshot.focus = position; return true
    }
    private func beginSweep(wide: Bool, at time: Double) {
        let search = FocusSweep(current: snapshot.focus, minimum: lower, maximum: upper, step: snapshot.step, wide: wide)
        sweep = search; search.didMove(at: time)
        if wide { acquisition.begin() } else { acquisition.cancel() }
        snapshot.message = wide ? "Acquiring focus… hold the mini inside the fixed box until the search finishes." : "Following miniature • checking focus inside your selection"
    }
    private func pauseAtStable() {
        if snapshot.active, sweep != nil, snapshot.focus != stableFocus { _ = move(to: stableFocus) }
        snapshot.active = false; sweep = nil; acquisition.cancel()
    }
    func hold() {
        queue.async { self.pauseAtStable(); self.snapshot.message = "Holding focus. Click Start following to resume."; self.publish() }
    }
    private func holdForLoss(_ message: String) {
        pauseAtStable(); snapshot.lost = true; snapshot.message = message; publish()
    }
    func restore() {
        queue.async { self.restoreNow(); self.publish() }
    }
    private func restoreNow() {
        snapshot.active = false; sweep = nil; acquisition.cancel()
        guard let usb = usb else { return }
        if focus_restore(usb) != 0 {
            var position: Int32 = 0, automatic: Int32 = 0
            if focus_read(usb, &position, &automatic) != 0 { snapshot.focus = Int(position); stableFocus = Int(position) }
            snapshot.message = "Stopped. Original focus and autofocus settings restored."
        } else { snapshot.message = "Could not restore camera settings. Reconnect the camera or restore them in your camera settings app." }
    }
    func disconnect() {
        queue.async { self.disconnectNow(); self.publish() }
    }
    private func disconnectNow() {
        restoreNow(); watchdog?.cancel(); watchdog = nil
        if let observer = observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        if let usb = usb { focus_close(usb); self.usb = nil }
        snapshot.connected = false; snapshot.target = nil; snapshot.image = nil; tracker = nil
    }
    func shutdown() { queue.sync { disconnectNow() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        lastFrameAt = time
        guard time - lastProcessed >= 0.10, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = time
        if snapshot.image == nil { snapshot.message = "Live preview ready. Drag a tight box around the miniature." }
        let image = CIImage(cvPixelBuffer: buffer)
        snapshot.image = context.createCGImage(image, from: image.extent)
        if diagnostic {
            diagnosticFrames += 1
            if diagnosticFrames == 30 { print("DIAGNOSTIC PASS: received 30 analyzed frames; \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)); USB control still readable=\(checkUSB())"); fflush(stdout) }
        }
        if let previous = snapshot.target, !snapshot.lost {
            if sweep == nil, acquisition.releaseIfSettled(at: time) {
                resetTracker(previous)
                snapshot.message = "Following miniature • focus settled"
            }
            // Deliberate lens sweeps blur the tracker input. Acquire using the
            // selected fixed region, then initialize tracking from the sharp frame.
            if wantsTracking, !acquiring, let tracker = tracker {
                do {
                    try sequence.perform([tracker], on: buffer, orientation: .up)
                    guard let result = tracker.results?.first as? VNDetectedObjectObservation,
                          TargetGeometry.acceptable(result.boundingBox, after: previous, confidence: result.confidence) else {
                        holdForLoss("Target lost or obscured. Focus held; draw a new box to resume."); return
                    }
                    snapshot.target = result.boundingBox; snapshot.confidence = result.confidence
                    tracker.inputObservation = result
                } catch { holdForLoss("Tracking interrupted. Focus held; draw a new box to resume."); return }
            }
            if let rect = snapshot.target {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                if let address = CVPixelBufferGetBaseAddress(buffer) {
                    let bytes = address.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    snapshot.sharpness = FocusMetric.score(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), roi: rect) { x, y in
                        let i = y * rowBytes + x * 4
                        return Double(bytes[i]) * 0.0722 + Double(bytes[i+1]) * 0.7152 + Double(bytes[i+2]) * 0.2126
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            if snapshot.active {
                if time - lastReadAt > 2 {
                    lastReadAt = time
                    var position: Int32 = 0, automatic: Int32 = 0
                    guard let usb = usb, focus_read(usb, &position, &automatic) != 0, automatic == 0, Int(position) == snapshot.focus else {
                        // Do not fight another application's camera controls.
                        snapshot.active = false; sweep = nil; acquisition.cancel()
                        snapshot.message = "Camera focus changed outside MiniFocus. Close other camera controls, then restart following."
                        publish(); return
                    }
                }
                if let sweep = sweep {
                    switch sweep.add(score: snapshot.sharpness, at: time) {
                    case .waiting: break
                    case .move(let position):
                        if move(to: position) { sweep.didMove(at: time) }
                    case .finished(let position, _):
                        if move(to: position) {
                            if acquiring { acquisition.finishSweep(at: time) }
                            stableFocus = position; self.sweep = nil; nextSweepAt = time + 1.8
                            snapshot.message = acquiring ? "Focus acquired • letting the lens settle before tracking" : "Following miniature • focus settled"
                        }
                    }
                } else if time >= nextSweepAt { beginSweep(wide: false, at: time) }
            }
        }
        publish()
    }
    private func checkUSB() -> Bool {
        guard let usb = usb else { return false }
        var position: Int32 = 0, automatic: Int32 = 0
        return focus_read(usb, &position, &automatic) != 0
    }
}
