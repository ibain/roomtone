import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox

@MainActor
final class DualTrackAudioCapturer: NSObject, AudioCapturing {
    private var streams: [SCStream] = []
    private var streamOutput: SystemAudioOutput?
    /// Retained so SCStream outputs are not deallocated mid-capture.
    private var systemStreamOutputs: [SystemAudioOutput] = []
    private var streamDelegate: StreamErrorDelegate?
    private var engine: AVAudioEngine?
    private var micTapInstalled = false
    /// Touched from audio callbacks + writer queue; lifetime owned on MainActor.
    nonisolated(unsafe) private var micWriter: WAVWriter?
    nonisolated(unsafe) private var systemWriter: WAVWriter?
    private var config: CaptureConfiguration?
    private var startedAt: Date?
    /// Wall-clock origin for mic + system WAV timelines (writer queue).
    nonisolated(unsafe) private var timelineAnchor: Date?
    nonisolated(unsafe) private var timelineSampleRate: Double = 48_000
    /// Only one SCStream may write system audio — multi-display used to double-length the file.
    nonisolated(unsafe) private var activeSystemStreamID: Int?
    nonisolated(unsafe) private var paused = false
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    /// Set from audio callback queue; used to detect silent/broken system capture.
    nonisolated(unsafe) private var systemAudioBuffersReceived = 0
    private let writerQueue = DispatchQueue(label: "com.ibain.roomtone.wav")
    /// When true, hot-follow macOS default input (headphones / AirPods mid-call), like Slack/Zoom.
    private var followsSystemDefaultInput = false
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var activeInputDeviceID: AudioDeviceID = 0

    func availableMicrophones() -> [AudioSourceOption] {
        // Always offer system default first — follows macOS input (built-in, AirPods, etc.).
        var options = [
            AudioSourceOption(
                id: "default",
                name: "System Default (follows macOS)",
                kind: .microphone
            )
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        options.append(contentsOf: discovery.devices.map {
            AudioSourceOption(id: $0.uniqueID, name: $0.localizedName, kind: .microphone)
        })
        return options
    }

    func start(configuration: CaptureConfiguration) async throws -> ActiveRecording {
        RoomtoneLog.session("start recording: \(configuration.meetingDirectory.lastPathComponent)")

        // Mic permission first; screen permission comes via system picker (no "bypass" dialog).
        let micOK = await CapturePermissions.requestMicrophoneAccess()
        if !micOK {
            RoomtoneLog.write("microphone permission denied")
            throw CapturePermissions.PermissionError.microphoneDenied
        }

        // Display picker grants Screen Recording TCC (required on Sequoia+).
        let consentFilter = try await ContentSharingPickerCoordinator.shared.pickFilter()
        RoomtoneLog.write("Roomtone picker filter style=\(Self.describeFilterStyle(consentFilter.style))")

        self.config = configuration
        self.paused = false
        self.systemAudioBuffersReceived = 0
        self.activeSystemStreamID = nil
        self.timelineSampleRate = configuration.sampleRate

        let systemURL = configuration.meetingDirectory.appendingPathComponent("system.wav")
        let micURL = configuration.meetingDirectory.appendingPathComponent("microphone.wav")

        systemWriter = try WAVWriter(fileURL: systemURL, sampleRate: configuration.sampleRate)
        micWriter = try WAVWriter(fileURL: micURL, sampleRate: configuration.sampleRate)
        // Shared clock starts when writers exist — pad silence if a track lags.
        let anchor = Date()
        self.startedAt = anchor
        self.timelineAnchor = anchor

        do {
            // After consent: capture EVERY display so meeting audio isn't stuck on one monitor.
            try await startSystemCaptureAllDisplays(
                sampleRate: configuration.sampleRate,
                fallbackFilter: consentFilter
            )
            try startMicrophone(configuration: configuration)
            _ = await waitForSystemAudio(timeoutSeconds: 0.4)
            if systemAudioBuffersReceived == 0 {
                RoomtoneLog.write("Roomtone: no system audio buffers yet — play meeting audio / check display pick")
            }
        } catch {
            await abortPartialStart()
            throw error
        }

        return ActiveRecording(startedAt: startedAt!)
    }

    private func abortPartialStart() async {
        removeDefaultInputListener()
        stopMicrophoneEngine()
        await stopAllStreams()
        ContentSharingPickerCoordinator.shared.endSession()
        micWriter?.close()
        systemWriter?.close()
        micWriter = nil
        systemWriter = nil
        config = nil
        startedAt = nil
        timelineAnchor = nil
        activeSystemStreamID = nil
        systemStreamOutputs = []
    }

    private func stopAllStreams() async {
        for stream in streams {
            try? await stream.stopCapture()
        }
        streams = []
        streamOutput = nil
        streamDelegate = nil
        systemStreamOutputs = []
    }

    func pause() {
        paused = true
        engine?.pause()
    }

    func resume() {
        paused = false
        try? engine?.start()
    }

    func stop() async throws -> CaptureResult {
        paused = true
        removeDefaultInputListener()
        followsSystemDefaultInput = false
        stopMicrophoneEngine()
        await stopAllStreams()
        ContentSharingPickerCoordinator.shared.endSession()

        let duration = Date().timeIntervalSince(startedAt ?? Date())
        let sampleRate = config?.sampleRate ?? timelineSampleRate
        let targetFrames = AVAudioFramePosition(max(0, duration) * sampleRate)
        // Finish both WAVs on the same wall-clock length before closing.
        writerQueue.sync {
            try? self.micWriter?.padToFrameCount(targetFrames)
            try? self.systemWriter?.padToFrameCount(targetFrames)
            self.micWriter?.close()
            self.systemWriter?.close()
            self.micWriter = nil
            self.systemWriter = nil
        }

        guard let configuration = config else {
            throw CaptureError.notRecording
        }
        let systemURL = configuration.meetingDirectory.appendingPathComponent("system.wav")
        let micURL = configuration.meetingDirectory.appendingPathComponent("microphone.wav")
        let combinedURL = configuration.meetingDirectory.appendingPathComponent("combined.wav")

        // Mix off the main actor — sample loops are CPU heavy even for short clips.
        try await Task.detached(priority: .userInitiated) {
            try WAVWriter.mixMonoFiles(
                systemURL: systemURL,
                microphoneURL: micURL,
                outputURL: combinedURL,
                sampleRate: sampleRate
            )
        }.value

        config = nil
        startedAt = nil
        timelineAnchor = nil
        activeSystemStreamID = nil
        return CaptureResult(
            durationSeconds: duration,
            systemURL: systemURL,
            microphoneURL: micURL,
            combinedURL: combinedURL
        )
    }

    func currentLevels() -> AudioLevels {
        AudioLevels(microphone: micLevel, system: systemLevel)
    }

    private func startMicrophone(configuration: CaptureConfiguration) throws {
        followsSystemDefaultInput = (configuration.microphoneDeviceID == nil || configuration.microphoneDeviceID == "default")

        let engine = AVAudioEngine()
        // MUST touch input + output before prepare(). Empty graph →
        // AVAE: "inputNode != nullptr || outputNode != nullptr".
        let input = engine.inputNode
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 0 // record-only; no speaker feedback

        if followsSystemDefaultInput {
            // Engine already uses macOS default input — don't poke CurrentDevice.
            activeInputDeviceID = Self.systemDefaultInputDeviceID() ?? 0
        } else if let micID = configuration.microphoneDeviceID {
            // prepare once so input AudioUnit exists, then pin device.
            try attachMicGraph(engine: engine)
            engine.prepare()
            try Self.setInputDeviceUID(micID, on: input)
            activeInputDeviceID = Self.deviceID(forUID: micID) ?? 0
        }

        try attachMicGraph(engine: engine)
        try installMicTap(on: engine)

        // Logged before start() because that call is what fails, and its error
        // names neither device.
        let inputEndpoint = Self.endpoint(
            for: activeInputDeviceID != 0
                ? activeInputDeviceID
                : (Self.systemDefaultInputDeviceID() ?? 0),
            input: true
        )
        let outputEndpoint = Self.endpoint(
            for: Self.systemDefaultOutputDeviceID() ?? 0,
            input: false
        )
        let graphFormat = input.inputFormat(forBus: 0)
        RoomtoneLog.write(
            "mic preflight: input=\(inputEndpoint?.summary ?? "unknown")"
            + " output=\(outputEndpoint?.summary ?? "unknown")"
            + " graph=\(graphFormat.channelCount) ch @ \(graphFormat.sampleRate) Hz"
            + " deviceID=\(activeInputDeviceID) followsDefault=\(followsSystemDefaultInput)"
            + " fileRate=\(configuration.sampleRate) Hz"
        )
        if let inputEndpoint, let outputEndpoint, inputEndpoint.rate != outputEndpoint.rate {
            RoomtoneLog.write(
                "mic preflight: note input and output sample rates differ"
                + " (\(Int(inputEndpoint.rate)) vs \(Int(outputEndpoint.rate)))"
                + " — recording has succeeded in this state before, so this alone is not a fault"
            )
        }

        do {
            try engine.start()
        } catch {
            RoomtoneLog.write(
                "mic engine start FAILED: \((error as NSError).domain)"
                + " \((error as NSError).code) — \(error.localizedDescription)"
            )
            throw CaptureError.micEngineUnstartable(
                input: inputEndpoint,
                output: outputEndpoint,
                underlying: error
            )
        }
        self.engine = engine
        micTapInstalled = true
        RoomtoneLog.write("mic engine started")

        if followsSystemDefaultInput {
            installDefaultInputListener()
        }
    }

    private func stopMicrophoneEngine() {
        guard let engine else {
            micTapInstalled = false
            return
        }
        engine.stop()
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        self.engine = nil
    }

    /// Connect muted input→mixer so the engine graph always has input + output nodes.
    private func attachMicGraph(engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let mixer = engine.mainMixerNode
        engine.disconnectNodeOutput(input)
        let format = try micHardwareFormat(input)
        engine.connect(input, to: mixer, format: format)
    }

    private func micHardwareFormat(_ input: AVAudioInputNode) throws -> AVAudioFormat {
        var format = input.inputFormat(forBus: 0)
        if format.channelCount == 0 || format.sampleRate == 0 {
            format = input.outputFormat(forBus: 0)
        }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError.micDeviceUnavailable
        }
        return format
    }

    private func installMicTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        _ = try micHardwareFormat(input)

        // nil format = node's native format (avoids silent taps from mismatched ASBD).
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if self.paused { return }
            let level = pcmRMS(buffer)
            Task { @MainActor in self.micLevel = level }
            nonisolated(unsafe) let bufferToWrite = buffer
            self.writerQueue.async {
                self.padWriterToWallClock(self.micWriter)
                try? self.micWriter?.write(buffer: bufferToWrite)
            }
        }
    }

    private func installDefaultInputListener() {
        removeDefaultInputListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleSystemDefaultInputChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            defaultInputListener = block
        }
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultInputListener = nil
    }

    private func handleSystemDefaultInputChanged() {
        guard followsSystemDefaultInput, let engine else { return }
        guard let newID = Self.systemDefaultInputDeviceID(), newID != activeInputDeviceID else { return }

        let wasRunning = engine.isRunning
        let shouldRun = wasRunning && !paused
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        if wasRunning {
            engine.stop()
        }
        do {
            try Self.setInputDeviceID(newID, on: engine.inputNode)
            activeInputDeviceID = newID
            try attachMicGraph(engine: engine)
            try installMicTap(on: engine)
            micTapInstalled = true
            if shouldRun {
                try engine.start()
            }
        } catch {
            // Best-effort hot-swap; keep recording on previous device if switch fails.
            try? self.recoverMicTap(engine: engine, shouldRun: shouldRun)
        }
    }

    private func recoverMicTap(engine: AVAudioEngine, shouldRun: Bool) throws {
        try attachMicGraph(engine: engine)
        try installMicTap(on: engine)
        micTapInstalled = true
        if shouldRun {
            try engine.start()
        }
    }

    /// Consent filter from picker, then stream every display so secondary-monitor audio isn't missed.
    private func startSystemCaptureAllDisplays(
        sampleRate: Double,
        fallbackFilter: SCContentFilter
    ) async throws {
        await stopAllStreams()
        systemAudioBuffersReceived = 0
        activeSystemStreamID = nil

        let streamConfig = makeSystemStreamConfiguration(sampleRate: sampleRate)

        let delegate = StreamErrorDelegate { error in
            RoomtoneLog.write("Roomtone SCStream stopped with error: \(error)")
        }
        self.streamDelegate = delegate

        var filters: [SCContentFilter] = []
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            filters = content.displays.map {
                SCContentFilter(display: $0, excludingApplications: [], exceptingWindows: [])
            }
            RoomtoneLog.write("Roomtone: capturing \(filters.count) display(s) for system audio")
        } catch {
            RoomtoneLog.write("Roomtone: display enum failed (\(error.localizedDescription)) — using picker filter")
        }
        if filters.isEmpty {
            filters = [fallbackFilter]
        }

        systemStreamOutputs = []
        for (index, filter) in filters.enumerated() {
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
            let streamOutput = SystemAudioOutput(
                streamID: index,
                onAudio: { [weak self] streamID, buffer in
                    self?.handleSystemAudio(streamID: streamID, buffer: buffer)
                },
                onRawAudio: { count, decodeOK in
                    if count == 1 {
                        RoomtoneLog.write("Roomtone SCStream audio callback #1 decodeOK=\(decodeOK)")
                    }
                }
            )
            if index == 0 { self.streamOutput = streamOutput }
            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: writerQueue)
            try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: writerQueue)
            try await stream.startCapture()
            streams.append(stream)
            systemStreamOutputs.append(streamOutput)
        }
        RoomtoneLog.write("Roomtone SCStream(s) started count=\(streams.count) capturesAudio=true")
    }

    private func handleSystemAudio(streamID: Int, buffer: AVAudioPCMBuffer) {
        systemAudioBuffersReceived += 1
        if paused { return }
        let level = pcmRMS(buffer)
        Task { @MainActor in self.systemLevel = level }
        nonisolated(unsafe) let bufferToWrite = buffer
        writerQueue.async {
            self.padWriterToWallClock(self.systemWriter)
            // Lock onto first stream that carries real audio; until then only stream 0
            // may write (keeps silence on the clock without doubling length).
            let hasSignal = level > 0.015
            if hasSignal, self.activeSystemStreamID == nil {
                self.activeSystemStreamID = streamID
                RoomtoneLog.write("Roomtone: system audio source locked to display stream \(streamID)")
            }
            let active = self.activeSystemStreamID
            if let active, active != streamID {
                return
            }
            if active == nil, streamID != 0 {
                return
            }
            do {
                try self.systemWriter?.write(buffer: bufferToWrite)
            } catch {
                RoomtoneLog.write("Roomtone system.wav write failed: \(error)")
            }
        }
    }

    /// Advance a writer with silence up to wall-clock now (shared mic/system timeline).
    nonisolated private func padWriterToWallClock(_ writer: WAVWriter?) {
        guard let writer, let anchor = timelineAnchor else { return }
        let elapsed = Date().timeIntervalSince(anchor)
        guard elapsed > 0 else { return }
        let target = AVAudioFramePosition(elapsed * timelineSampleRate)
        try? writer.padToFrameCount(target)
    }

    private func makeSystemStreamConfiguration(sampleRate: Double) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = Int(sampleRate)
        streamConfig.channelCount = 2
        // SCStream always emits video; keep it tiny and discard frames in the screen output.
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 3
        return streamConfig
    }

    private func waitForSystemAudio(timeoutSeconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if systemAudioBuffersReceived > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return systemAudioBuffersReceived > 0
    }

    private static func describeFilterStyle(_ style: SCShareableContentStyle) -> String {
        switch style {
        case .display: return "display"
        case .application: return "application"
        case .window: return "window"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The default input and output as CoreAudio sees them right now.
    static func defaultEndpoints() -> (input: AudioEndpoint?, output: AudioEndpoint?) {
        (
            endpoint(for: systemDefaultInputDeviceID() ?? 0, input: true),
            endpoint(for: systemDefaultOutputDeviceID() ?? 0, input: false)
        )
    }

    static func endpoint(for deviceID: AudioDeviceID, input: Bool) -> AudioEndpoint? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        _ = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }

        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate) != noErr {
            rateAddress.mScope = kAudioObjectPropertyScopeGlobal
            _ = AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate)
        }

        return AudioEndpoint(
            name: (name as String?) ?? "Unknown device",
            rate: rate,
            supportedRates: supportedRates(for: deviceID, scope: scope)
        )
    }

    private static func supportedRates(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        // Continuous ranges report min != max; only discrete rates are useful
        // for telling the user what to pick.
        return ranges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum)
    }

    private static func deviceID(forUID uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }
        for deviceID in deviceIDs {
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString?
            let err = withUnsafeMutablePointer(to: &uid) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            if err == noErr, (uid as String?) == uniqueID {
                return deviceID
            }
        }
        return nil
    }

    private static func setInputDeviceUID(_ uniqueID: String, on inputNode: AVAudioInputNode) throws {
        guard let deviceID = deviceID(forUID: uniqueID) else {
            throw CaptureError.micDeviceUnavailable
        }
        try setInputDeviceID(deviceID, on: inputNode)
    }

    private static func setInputDeviceID(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw CaptureError.micDeviceUnavailable
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CaptureError.micDeviceUnavailable }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case notRecording
        case micDeviceUnavailable
        case noSystemAudio
        case micEngineUnstartable(input: AudioEndpoint?, output: AudioEndpoint?, underlying: Error)
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available for system audio capture"
            case .notRecording: return "Not currently recording"
            case .micDeviceUnavailable: return "Could not use the selected microphone. Try System Default."
            case .noSystemAudio:
                return "No meeting/system audio received. In the share picker choose your Display (or the Zoom/Slack app), play audio, and check System Settings → Privacy → Screen & System Audio Recording for Roomtone."
            case .micEngineUnstartable(let input, let output, let underlying):
                return Self.startFailureMessage(input: input, output: output, underlying: underlying)
            }
        }

        /// Reports both endpoints and the likely causes without picking one.
        ///
        /// CoreAudio only says "couldn't be completed" here, and the same code
        /// covers a stalled audio daemon, a device that won't open, and a
        /// rate mismatch. Naming a single cause sends people down the wrong path.
        private static func startFailureMessage(
            input: AudioEndpoint?,
            output: AudioEndpoint?,
            underlying: Error
        ) -> String {
            var lines = ["Could not start the microphone."]
            if let input {
                lines.append("Input: \(input.summary)")
            }
            if let output {
                lines.append("Output: \(output.summary)")
            }
            lines.append("")
            lines.append("If the microphone also fails in other apps, macOS audio is stuck —"
                         + " run `sudo killall coreaudiod` in Terminal, or restart.")
            lines.append("Otherwise try another input device, or close apps that may hold the mic.")
            if let input, let output, input.rate != output.rate {
                let shared = input.supportedRates.filter { output.supportedRates.contains($0) }
                let hint = shared.isEmpty
                    ? "they share no common rate, so try a different input or output device"
                    : "matching them in Audio MIDI Setup ("
                        + shared.map { "\(Int($0)) Hz" }.joined(separator: " or ")
                        + ") may help"
                lines.append("These devices also run at different sample rates — \(hint).")
            }
            lines.append("")
            lines.append("Code \((underlying as NSError).code). Log: \(RoomtoneLog.fileURL.path)")
            return lines.joined(separator: "\n")
        }
    }
}

/// A default audio device as CoreAudio currently reports it.
struct AudioEndpoint {
    let name: String
    let rate: Double
    let supportedRates: [Double]

    var summary: String {
        let supported = supportedRates.isEmpty
            ? "unknown"
            : supportedRates.map { String(Int($0)) }.joined(separator: "/")
        return "\(name) at \(Int(rate)) Hz (supports \(supported))"
    }
}

private final class StreamErrorDelegate: NSObject, SCStreamDelegate {
    let onError: (Error) -> Void
    init(onError: @escaping (Error) -> Void) { self.onError = onError }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput {
    let streamID: Int
    let onAudio: (Int, AVAudioPCMBuffer) -> Void
    let onRawAudio: (Int, Bool) -> Void
    private var rawCount = 0

    init(
        streamID: Int,
        onAudio: @escaping (Int, AVAudioPCMBuffer) -> Void,
        onRawAudio: @escaping (Int, Bool) -> Void
    ) {
        self.streamID = streamID
        self.onAudio = onAudio
        self.onRawAudio = onRawAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Intentionally discard video; registering .screen prevents SCK drop spam.
        guard type == .audio else { return }
        rawCount += 1
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else {
            onRawAudio(rawCount, false)
            return
        }
        onRawAudio(rawCount, true)
        if rawCount == 1 {
            let level = pcmRMS(buffer)
            RoomtoneLog.write("Roomtone system audio stream\(streamID): \(buffer.format.channelCount) ch @ \(buffer.format.sampleRate) Hz, firstRMS=\(level)")
        }
        onAudio(streamID, buffer)
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid else { return nil }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription else {
            return nil
        }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0 else { return nil }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: 1,
            interleaved: false
        ),
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
        let dst = mono.floatChannelData?[0] else {
            return nil
        }

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                mono.frameLength = frames
                let count = Int(frames)
                let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                let numBuffers = abl.count
                guard numBuffers > 0 else { return }

                if numBuffers > 1 || (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 {
                    for i in 0..<count {
                        var sum: Float = 0
                        var used = 0
                        for b in 0..<numBuffers {
                            guard let data = abl[b].mData else { continue }
                            if isFloat {
                                sum += data.assumingMemoryBound(to: Float.self)[i]
                            } else {
                                sum += Float(data.assumingMemoryBound(to: Int16.self)[i]) / Float(Int16.max)
                            }
                            used += 1
                        }
                        dst[i] = used > 0 ? sum / Float(used) : 0
                    }
                } else {
                    guard let data = abl[0].mData else { return }
                    let channels = Int(max(asbd.mChannelsPerFrame, 1))
                    if isFloat {
                        let src = data.assumingMemoryBound(to: Float.self)
                        for i in 0..<count {
                            var sum: Float = 0
                            for c in 0..<channels { sum += src[i * channels + c] }
                            dst[i] = sum / Float(channels)
                        }
                    } else {
                        let src = data.assumingMemoryBound(to: Int16.self)
                        for i in 0..<count {
                            var sum: Float = 0
                            for c in 0..<channels {
                                sum += Float(src[i * channels + c]) / Float(Int16.max)
                            }
                            dst[i] = sum / Float(channels)
                        }
                    }
                }
            }
        } catch {
            RoomtoneLog.write("Roomtone audio ABL extract failed: \(error)")
            return nil
        }

        guard mono.frameLength > 0 else { return nil }
        return mono
    }
}

/// Peak-ish RMS for meters (0…1). File-level so audio callbacks can call without actor hops.
nonisolated private func pcmRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    let n = Int(buffer.frameLength)
    guard n > 0 else { return 0 }
    let channels = Int(buffer.format.channelCount)
    guard channels > 0 else { return 0 }

    var sum: Float = 0
    var count = 0
    if let floatData = buffer.floatChannelData {
        for ch in 0..<channels {
            let data = floatData[ch]
            for i in 0..<n {
                let s = data[i]
                sum += s * s
                count += 1
            }
        }
    } else if let int16 = buffer.int16ChannelData {
        for ch in 0..<channels {
            let data = int16[ch]
            for i in 0..<n {
                let s = Float(data[i]) / Float(Int16.max)
                sum += s * s
                count += 1
            }
        }
    } else {
        return 0
    }
    guard count > 0 else { return 0 }
    return min(1, sqrt(sum / Float(count)) * 5)
}
