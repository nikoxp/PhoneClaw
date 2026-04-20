import AVFoundation
import Foundation
import Observation

struct AudioCaptureSnapshot: Sendable {
    let pcm: [Float]
    let sampleRate: Double
    let channelCount: Int
    let duration: TimeInterval
}

@MainActor
@Observable
final class AudioCaptureService {
    private static let preferredSampleRate: Double = 16_000
    private static let maxStoredSeconds: Double = 30

    var permissionStatus: AppPermissionStatus = .notDetermined
    var isCapturing = false
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var capturedSampleCount = 0
    var bufferedSampleCount = 0
    var duration: TimeInterval = 0
    var peakLevel: Float = 0
    var statusText = ""
    var lastErrorMessage: String?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private let pcmLock = NSLock()
    @ObservationIgnored private var rollingPCM: [Float] = []

    init() {
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        switch audioSession.recordPermission {
        case .granted:
            permissionStatus = .granted
        case .denied:
            permissionStatus = .denied
        case .undetermined:
            permissionStatus = .notDetermined
        @unknown default:
            permissionStatus = .restricted
        }
    }

    @discardableResult
    func toggleCapture() async -> Bool {
        if isCapturing {
            stopCapture()
            return true
        } else {
            return await startCapture()
        }
    }

    @discardableResult
    func startCapture() async -> Bool {
        refreshPermissionStatus()
        if permissionStatus == .notDetermined {
            let granted = await requestPermission()
            guard granted else {
                lastErrorMessage = "麦克风权限未授予，无法开始录音。"
                return false
            }
        }

        guard permissionStatus.isGranted else {
            lastErrorMessage = "麦克风权限不可用，请到系统设置中开启。"
            return false
        }

        guard !isCapturing else { return true }

        resetCaptureState()
        lastErrorMessage = nil
        statusText = "准备录音..."

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try audioSession.setPreferredSampleRate(Self.preferredSampleRate)
            try audioSession.setActive(true)

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            sampleRate = inputFormat.sampleRate
            channelCount = Int(inputFormat.channelCount)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.handleIncomingPCM(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isCapturing = true
            updateStatusText()
            return true
        } catch {
            stopCapture(deactivateSession: false)
            lastErrorMessage = "启动录音失败：\(error.localizedDescription)"
            statusText = lastErrorMessage ?? ""
            return false
        }
    }

    @discardableResult
    func stopCapture(deactivateSession: Bool = true) -> AudioCaptureSnapshot? {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        if deactivateSession {
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        }

        let snapshot = latestSnapshot()
        isCapturing = false
        peakLevel = 0

        if let snapshot, snapshot.duration > 0 {
            statusText = String(
                format: "已录制 %.1f 秒音频（%.0f Hz，%d 声道），可以直接发送给模型。",
                snapshot.duration,
                snapshot.sampleRate,
                snapshot.channelCount
            )
        } else if lastErrorMessage == nil {
            statusText = ""
        }

        return snapshot
    }

    func clearStatus() {
        statusText = ""
        lastErrorMessage = nil
    }

    func consumeLatestSnapshot() -> AudioCaptureSnapshot? {
        let raw = rawSnapshot()
        resetCaptureState()
        clearStatus()
        guard let raw else { return nil }
        let resampled = resampleTo16kHz(raw)
        return normalizeAudio(resampled)
    }

    func latestSnapshot() -> AudioCaptureSnapshot? {
        rawSnapshot()
    }

    /// 原始 PCM snapshot（不重采样，用于 UI 展示时长/状态）
    private func rawSnapshot() -> AudioCaptureSnapshot? {
        pcmLock.lock()
        let pcm = rollingPCM
        pcmLock.unlock()

        guard !pcm.isEmpty, sampleRate > 0 else { return nil }
        return AudioCaptureSnapshot(
            pcm: pcm,
            sampleRate: sampleRate,
            channelCount: 1,
            duration: Double(pcm.count) / sampleRate
        )
    }

    /// AVAudioConverter 重采样到 16kHz（Gemma 4 要求）
    private func resampleTo16kHz(_ snapshot: AudioCaptureSnapshot) -> AudioCaptureSnapshot {
        let targetRate: Double = Self.preferredSampleRate  // 16000
        let srcRate = snapshot.sampleRate

        // 已经是 16kHz
        if abs(srcRate - targetRate) < 1 { return snapshot }

        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: srcRate, channels: 1, interleaved: false
        ), let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return snapshot
        }

        let srcFrameCount = AVAudioFrameCount(snapshot.pcm.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrameCount) else {
            return snapshot
        }
        srcBuffer.frameLength = srcFrameCount
        memcpy(srcBuffer.floatChannelData![0], snapshot.pcm, snapshot.pcm.count * MemoryLayout<Float>.size)

        let dstFrameCount = AVAudioFrameCount(Double(srcFrameCount) * targetRate / srcRate)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrameCount) else {
            return snapshot
        }

        var error: NSError?
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }

        guard error == nil, let channelData = dstBuffer.floatChannelData else {
            return snapshot
        }

        let count = Int(dstBuffer.frameLength)
        let resampled = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        return AudioCaptureSnapshot(
            pcm: resampled,
            sampleRate: targetRate,
            channelCount: 1,
            duration: Double(count) / targetRate
        )
    }

    /// Peak normalization: 麦克风录音 peak 通常只有 0.03-0.05,
    /// 模型需要正常音量 (peak ~0.8) 才能正确分析内容。
    private func normalizeAudio(_ snapshot: AudioCaptureSnapshot) -> AudioCaptureSnapshot {
        let peak = snapshot.pcm.map { abs($0) }.max() ?? 0
        guard peak > 0.001 else { return snapshot }  // 静音不处理

        let targetPeak: Float = 0.8
        let gain = targetPeak / peak

        // 不放大已经够响的音频
        guard gain > 1.5 else { return snapshot }

        let normalized = snapshot.pcm.map { min(max($0 * gain, -1), 1) }
        return AudioCaptureSnapshot(
            pcm: normalized,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            duration: snapshot.duration
        )
    }

    private func requestPermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        refreshPermissionStatus()
        return granted
    }

    private func resetCaptureState() {
        pcmLock.lock()
        rollingPCM.removeAll(keepingCapacity: true)
        pcmLock.unlock()

        capturedSampleCount = 0
        bufferedSampleCount = 0
        duration = 0
        peakLevel = 0
        sampleRate = 0
        channelCount = 0
    }

    private func handleIncomingPCM(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let formatChannelCount = Int(buffer.format.channelCount)
        guard let channelData = buffer.floatChannelData else { return }

        let samples: [Float]
        if formatChannelCount <= 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            var mixed = Array(repeating: Float.zero, count: frameCount)
            let scale = 1.0 / Float(formatChannelCount)
            for channel in 0 ..< formatChannelCount {
                let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
                for index in 0 ..< frameCount {
                    mixed[index] += channelSamples[index] * scale
                }
            }
            samples = mixed
        }
        let rms = sqrt(samples.reduce(0) { $0 + ($1 * $1) } / Float(max(frameCount, 1)))
        let peak = samples.map { abs($0) }.max() ?? 0

        pcmLock.lock()
        rollingPCM.append(contentsOf: samples)
        let maxStoredSamples = Int(max(sampleRate, Self.preferredSampleRate) * Self.maxStoredSeconds)
        if rollingPCM.count > maxStoredSamples {
            rollingPCM.removeFirst(rollingPCM.count - maxStoredSamples)
        }
        let bufferedCount = rollingPCM.count
        pcmLock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            capturedSampleCount += frameCount
            bufferedSampleCount = bufferedCount
            if sampleRate == 0 {
                sampleRate = buffer.format.sampleRate
            }
            if channelCount == 0 {
                channelCount = 1
            }
            if sampleRate > 0 {
                duration = Double(capturedSampleCount) / sampleRate
            }
            peakLevel = max(rms, peak)
            updateStatusText()
        }
    }

    private func updateStatusText() {
        guard isCapturing else { return }
        statusText = String(
            format: "录音中 %.1f 秒 · %.0f Hz · 缓冲 %.1f 秒 PCM",
            duration,
            max(sampleRate, Self.preferredSampleRate),
            sampleRate > 0 ? Double(bufferedSampleCount) / sampleRate : 0
        )
    }
}
