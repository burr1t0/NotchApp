import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Real audio-reactive levels for the equalizer.
///
/// Uses a Core Audio *process tap* (macOS 14.2+): a read-only copy of
/// everything the system is playing, delivered through a private aggregate
/// device, without touching the actual output. Each ~21ms of audio is
/// windowed, run through a 2048-point FFT (Accelerate) and folded into a few
/// log-spaced bands (bass → treble). That's a few thousand multiply-adds per
/// hop — well under 1% CPU — and capture only runs while it's actually
/// needed (see `NotchWindowController`).
///
/// Needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription);
/// without it the tap delivers silence and the bars simply rest. Only band
/// levels are ever kept — no audio is stored or sent anywhere.
final class AudioLevelMonitor {
    static let bandCount = 5

    // Band edges in Hz: sub/bass, low-mid, mid, upper-mid, treble.
    private let bandEdges: [(low: Float, high: Float)] = [
        (35, 110), (110, 330), (330, 1_000), (1_000, 3_500), (3_500, 12_000)
    ]

    private let queue = DispatchQueue(label: "notchapp.audio-levels", qos: .userInteractive)
    private let levelsLock = NSLock()
    private var levels = [Float](repeating: 0, count: AudioLevelMonitor.bandCount)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    // Everything below is only touched on `queue`.
    private let fftSize = 2048
    private let hopSize = 1024
    private let log2n: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var ring: [Float]
    // Reused every hop instead of allocating fresh arrays 43 times a second.
    private var scratchFrame: [Float]
    private var scratchReal: [Float]
    private var scratchImag: [Float]
    private var scratchPower: [Float]
    private var ringWrite = 0
    private var samplesSinceHop = 0
    private var sampleRate: Float = 48_000
    private var binRanges: [(lo: Int, hi: Int)] = []
    private var smoothed = [Float](repeating: 0, count: AudioLevelMonitor.bandCount)
    private var references = [Float](repeating: 2e-3, count: AudioLevelMonitor.bandCount)

    /// Diagnostics for "the equalizer doesn't react": create an empty file
    /// `/tmp/notchapp_audio_debug` before capture starts and per-hop band
    /// levels get appended to `/tmp/notchapp_audio_debug.log`. Off otherwise.
    private var debugLogging = false

    init() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        scratchFrame = [Float](repeating: 0, count: fftSize)
        scratchReal = [Float](repeating: 0, count: fftSize / 2)
        scratchImag = [Float](repeating: 0, count: fftSize / 2)
        scratchPower = [Float](repeating: 0, count: fftSize / 2)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        computeBinRanges()
        installDefaultDeviceListener()
    }

    deinit {
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Latest smoothed band levels, each 0...1. Cheap and thread-safe, meant
    /// to be polled once per frame by the UI.
    func currentLevels() -> [Float] {
        if demoMode {
            // A made-up groove (120 bpm kick plus slower, offset bands) on the
            // recording's own clock, so every frame is reproducible.
            let t = DemoClock.levelTime
            var result = [Float]()
            for band in 0..<Self.bandCount {
                let phase = Double(band)
                let swell = 0.5 + 0.5 * sin(t * (1.3 + phase * 0.55) + phase * 2.1)
                var level = 0.22 + 0.5 * swell
                if band < 2 {
                    let kick = max(0, sin(t * 2 * Double.pi * 2 + phase))
                    level += 0.3 * kick * kick
                }
                result.append(Float(min(level, 1)))
            }
            return result
        }
        levelsLock.lock()
        defer { levelsLock.unlock() }
        return levels
    }

    /// Synthetic levels for recording the demo animation; no audio is touched.
    var demoMode = false

    func start() {
        guard !demoMode else { return }
        guard !running else { return }
        debugLogging = FileManager.default.fileExists(atPath: "/tmp/notchapp_audio_debug")
        guard createTapAndDevice() else {
            teardown()
            return
        }
        running = true
    }

    func stop() {
        guard running || tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        running = false
        teardown()
        queue.async { [weak self] in
            self?.resetState()
        }
        publish([Float](repeating: 0, count: Self.bandCount))
    }

    // MARK: - Setup

    private func createTapAndDevice() -> Bool {
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            log("no default output device")
            return false
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "NotchApp levels"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard status == noErr else {
            log("AudioHardwareCreateProcessTap failed: \(status)")
            return false
        }
        tapID = newTap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchApp levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString
            ]]
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
        guard status == noErr else {
            log("AudioHardwareCreateAggregateDevice failed: \(status)")
            return false
        }
        aggregateID = newAggregate

        if let format = Self.tapFormat(of: tapID) {
            sampleRate = Float(format.mSampleRate)
            queue.async { [weak self] in self?.computeBinRanges() }
        }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let procID else {
            log("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            return false
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            log("AudioDeviceStart failed: \(status)")
            return false
        }
        log("capture started, sampleRate=\(sampleRate)")
        return true
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The aggregate device is built around whichever output device was the
    /// default at start; if the user switches (AirPods, HDMI, ...) it has to
    /// be rebuilt or it would keep listening to the old one.
    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.teardown()
            self.running = false
            self.start()
        }
        defaultDeviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    }

    // MARK: - Audio processing (on `queue`)

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, let firstData = first.mData else { return }

        // Describe the source once, then mix to mono straight into the ring
        // buffer. Everything touched in the per-sample loop is a local or a
        // raw pointer: the previous version built a temporary `mono` array and
        // then hit several class properties per sample, each of which pays
        // Swift's dynamic exclusivity check — ~48,000 times a second.
        let left = firstData.assumingMemoryBound(to: Float.self)
        var rightPointer: UnsafeMutablePointer<Float>?
        var channelCount = 1
        let frameCount: Int
        if buffers.count >= 2, let secondData = buffers[1].mData {
            // Non-interleaved: one buffer per channel.
            rightPointer = secondData.assumingMemoryBound(to: Float.self)
            frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        } else {
            // Interleaved: channels share one buffer.
            channelCount = max(Int(first.mNumberChannels), 1)
            frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
        }
        let right = rightPointer
        let channels = channelCount
        let size = fftSize

        var consumed = 0
        while consumed < frameCount {
            // Copy up to the next hop boundary, then analyse.
            let chunk = min(frameCount - consumed, hopSize - samplesSinceHop)
            let start = ringWrite
            let offset = consumed

            ring.withUnsafeMutableBufferPointer { ringPointer in
                for i in 0..<chunk {
                    let frame = offset + i
                    let sample: Float
                    if let right {
                        sample = (left[frame] + right[frame]) * 0.5
                    } else if channels == 1 {
                        sample = left[frame]
                    } else {
                        var sum: Float = 0
                        for c in 0..<channels { sum += left[frame * channels + c] }
                        sample = sum / Float(channels)
                    }
                    ringPointer[(start + i) % size] = sample
                }
            }

            ringWrite = (start + chunk) % size
            samplesSinceHop += chunk
            consumed += chunk

            if samplesSinceHop >= hopSize {
                samplesSinceHop = 0
                analyze()
            }
        }
    }

    private func analyze() {
        guard let fftSetup else { return }
        let n = fftSize
        let half = n / 2
        let write = ringWrite

        // Oldest → newest, windowed, written into the reused frame buffer in
        // a single pass (no per-hop allocations: this runs ~43 times a second).
        ring.withUnsafeBufferPointer { ringPointer in
            window.withUnsafeBufferPointer { windowPointer in
                scratchFrame.withUnsafeMutableBufferPointer { frame in
                    let tail = n - write
                    for i in 0..<tail { frame[i] = ringPointer[write + i] * windowPointer[i] }
                    for i in 0..<write { frame[tail + i] = ringPointer[i] * windowPointer[tail + i] }
                }
            }
        }

        scratchReal.withUnsafeMutableBufferPointer { realPointer in
            scratchImag.withUnsafeMutableBufferPointer { imagPointer in
                scratchPower.withUnsafeMutableBufferPointer { powerPointer in
                    scratchFrame.withUnsafeBufferPointer { framePointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, powerPointer.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
        }
        let power = scratchPower

        var raw = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let range = binRanges[band]
            var sum: Float = 0
            for k in range.lo...range.hi { sum += power[k] }
            let meanPower = sum / Float(range.hi - range.lo + 1)
            raw[band] = meanPower.squareRoot() / Float(n)
        }

        // Each band is measured against *its own* slowly-decaying recent
        // peak, on a decibel scale 20 dB deep. Music's spectrum slopes
        // steeply (treble carries far less energy than bass), so a shared
        // reference leaves the upper bars pinned at rest; per-band
        // normalising lets every bar use its full travel, and the dB scale
        // (instead of a root curve that squashes everything toward the top)
        // keeps beats and phrasing visible as real movement.
        var target = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            references[band] = max(references[band] * 0.996, raw[band], 1e-3)
            guard raw[band] > 3e-4 else { continue }   // silence gate
            let decibels = 20 * log10(raw[band] / references[band])   // ≤ 0
            target[band] = max(0, 1 + decibels / 20)
        }

        // Fast attack, quicker release: punchy but not twitchy.
        for band in 0..<Self.bandCount {
            let coefficient: Float = target[band] > smoothed[band] ? 0.8 : 0.25
            smoothed[band] += (target[band] - smoothed[band]) * coefficient
        }

        publish(smoothed)

        if debugLogging {
            log(String(format: "raw=%@ refs=%@ levels=%@",
                       raw.map { String(format: "%.4f", $0) }.joined(separator: ","),
                       references.map { String(format: "%.4f", $0) }.joined(separator: ","),
                       smoothed.map { String(format: "%.2f", $0) }.joined(separator: ",")))
        }
    }

    private func publish(_ newLevels: [Float]) {
        levelsLock.lock()
        levels = newLevels
        levelsLock.unlock()
    }

    private func resetState() {
        ring = [Float](repeating: 0, count: fftSize)
        ringWrite = 0
        samplesSinceHop = 0
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        references = [Float](repeating: 2e-3, count: Self.bandCount)
    }

    private func computeBinRanges() {
        let binHz = sampleRate / Float(fftSize)
        let maxBin = fftSize / 2 - 1
        binRanges = bandEdges.map { edge in
            let lo = min(max(Int(edge.low / binHz), 1), maxBin)
            let hi = min(max(Int(edge.high / binHz), lo), maxBin)
            return (lo, hi)
        }
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(of tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    private func log(_ message: String) {
        guard debugLogging else { return }
        let line = "\(Date()) \(message)\n"
        let path = "/tmp/notchapp_audio_debug.log"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
