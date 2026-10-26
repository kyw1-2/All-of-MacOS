import AppKit
import AVFoundation

/// A stable graph per hardware output. App membership changes only the render
/// bus, never AVAudioEngine's connections while media is playing.
@MainActor
final class SharedOutputRenderer {
    static let shared = SharedOutputRenderer()
    nonisolated static let sampleRate: Double = 48000

    final class SourceToken {
        let id: UUID
        fileprivate let uid: String
        let isAirPlay: Bool
        let deviceID: AudioDeviceID
        fileprivate init(id: UUID, uid: String, deviceID: AudioDeviceID, isAirPlay: Bool = false) {
            self.id = id; self.uid = uid; self.deviceID = deviceID; self.isAirPlay = isAirPlay
        }
    }

    private final class DeviceGraph {
        let engine: AVAudioEngine
        let bus: AppAudioRenderBus
        let node: AVAudioSourceNode
        let deviceID: AudioDeviceID
        var observer: NSObjectProtocol?
        var failure: String?
        init(engine: AVAudioEngine, bus: AppAudioRenderBus, node: AVAudioSourceNode, deviceID: AudioDeviceID) {
            self.engine = engine; self.bus = bus; self.node = node; self.deviceID = deviceID
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
    private var graphs: [String: DeviceGraph] = [:]
    private var airPlayOutputs: [String: AirPlayOutputRenderer] = [:]
    var activeDeviceUIDs: [String] { Array(Set(graphs.keys).union(airPlayOutputs.keys)) }

    /// Start asynchronously before creating a muting process tap. A real HAL
    /// render callback must arrive before this returns ready.
    func prepareAirPlay(device: AudioOutputDevice) -> AirPlayOutputRenderer.State {
        if let old = airPlayOutputs[device.uid], old.deviceID != device.id {
            guard old.bus.isEmpty else { return .failed("AirPlay device reconnected. Reconnect audio processing.") }
            old.stop(); airPlayOutputs.removeValue(forKey: device.uid)
        }
        if airPlayOutputs[device.uid] == nil {
            airPlayOutputs[device.uid] = AirPlayOutputRenderer(deviceID: device.id) {
                if #available(macOS 14.2, *) { AppAudioEngine.shared.requestSync() }
            }
        }
        return airPlayOutputs[device.uid]!.state
    }

    func airPlayFailure(_ token: SourceToken) -> String? {
        guard token.isAirPlay else { return nil }
        guard let output = airPlayOutputs[token.uid] else {
            return "AirPlay disconnected. Native playback restored."
        }
        if case .failed(let message) = output.state { return message }
        return nil
    }

    func releaseUnusedAirPlayOutputs(keeping uids: Set<String>) {
        for (uid, output) in Array(airPlayOutputs) where !uids.contains(uid) && output.bus.isEmpty {
            output.stop(); airPlayOutputs.removeValue(forKey: uid)
        }
    }

    func resetAirPlayFailures() {
        for (uid, output) in Array(airPlayOutputs) where output.bus.isEmpty {
            if case .failed = output.state {
                output.stop(); airPlayOutputs.removeValue(forKey: uid)
            }
        }
    }

    func addSource(uid: String, device: AudioOutputDevice,
                   render: @escaping AppAudioRenderBus.Render) -> SourceToken? {
        if AudioOutputRestore.transportType(of: device.id) == kAudioDeviceTransportTypeAirPlay {
            guard case .ready = prepareAirPlay(device: device), let output = airPlayOutputs[uid] else { return nil }
            let id = UUID()
            output.bus.add(id: id, render: render)
            return SourceToken(id: id, uid: uid, deviceID: device.id, isAirPlay: true)
        }
        if let existing = graphs[uid], existing.deviceID != device.id {
            // A reconnected device may reuse its UID with a different object ID.
            // The caller first moves/removes its old sources; never overwrite them.
            guard existing.bus.isEmpty else { return nil }
            existing.engine.stop()
            graphs.removeValue(forKey: uid)
        }
        if graphs[uid] == nil {
            guard let graph = makeGraph(uid: uid, device: device) else { return nil }
            graphs[uid] = graph
        }
        guard let graph = graphs[uid], graph.failure == nil, graph.engine.isRunning else { return nil }
        let id = UUID()
        graph.bus.add(id: id, render: render)
        return SourceToken(id: id, uid: uid, deviceID: device.id)
    }

    private func makeGraph(uid: String, device: AudioOutputDevice) -> DeviceGraph? {
        let engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else { return nil }
        var deviceID = device.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
              output.outputFormat(forBus: 0).channelCount > 0,
              output.outputFormat(forBus: 0).sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else { return nil }
        let bus = AppAudioRenderBus()
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            bus.render(frames: Int(frames), output: buffers)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch { engine.stop(); return nil }
        let graph = DeviceGraph(engine: engine, bus: bus, node: node, deviceID: device.id)
        graph.observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak graph] _ in
            // Defer out of AVAudioEngine's notification stack.
            DispatchQueue.main.async { [weak self, weak graph] in
                guard let self, let graph, self.graphs[uid] === graph else { return }
                self.recover(graph, uid: uid)
            }
        }
        return graph
    }

    private func recover(_ graph: DeviceGraph, uid: String) {
        guard !graph.engine.isRunning else { return }
        guard AudioOutputService.devices().contains(where: { $0.uid == uid && $0.id == graph.deviceID }) else {
            graph.failure = "Audio output disconnected"
            return
        }
        graph.failure = nil
        do { try graph.engine.start() }
        catch { graph.failure = "Audio output could not restart: \(error.localizedDescription)" }
    }

    func isReady(_ token: SourceToken) -> Bool {
        if token.isAirPlay {
            guard let output = airPlayOutputs[token.uid], output.deviceID == token.deviceID, case .ready = output.state else { return false }
            return true
        }
        guard let graph = graphs[token.uid], graph.deviceID == token.deviceID else { return false }
        return graph.failure == nil && graph.engine.isRunning
    }

    /// Restarts a stopped engine in place: overload or a transient format
    /// change stops the HAL cycle, and starting again keeps the tap, the
    /// aggregate and every source node attached — no player sees device loss.
    @discardableResult
    func ensureRunning(token: SourceToken) -> Bool {
        // AirPlay failures release muting taps; only explicit recovery can
        // reopen the remote session. Never start a reconnect loop here.
        guard !token.isAirPlay, let graph = graphs[token.uid], graph.deviceID == token.deviceID else { return false }
        guard !graph.engine.isRunning else { return graph.failure == nil }
        graph.failure = nil
        do { try graph.engine.start() } catch {
            graph.failure = "Audio output restart failed: \(error.localizedDescription)"
        }
        return graph.failure == nil && graph.engine.isRunning
    }

    func removeSource(_ token: SourceToken) {
        if token.isAirPlay {
            airPlayOutputs[token.uid]?.bus.remove(id: token.id)
            return
        }
        guard let graph = graphs[token.uid] else { return }
        graph.bus.remove(id: token.id)
        // Keep an idle graph running for subsequent app playback. Explicit
        // shutdown and physical device removal release the hardware.
    }

    func rebindIfNeeded(devices: [AudioOutputDevice]) {
        for (uid, output) in Array(airPlayOutputs) {
            if !devices.contains(where: { $0.uid == uid && $0.id == output.deviceID }) {
                output.stop()
                airPlayOutputs.removeValue(forKey: uid)
            }
        }
        for (uid, graph) in Array(graphs) {
            let present = devices.contains { $0.uid == uid && $0.id == graph.deviceID }
            if !present { graph.failure = "Audio output disconnected" }
            if !present || (graph.bus.isEmpty && (graph.failure != nil || !graph.engine.isRunning)) {
                // Retire a vanished object even while tokens still reference it.
                // A reconnect can preserve the UID while replacing the numeric ID.
                graph.bus.removeAll()
                graph.engine.stop()
                graphs.removeValue(forKey: uid)
            }
        }
    }

    func shutdown() {
        for output in airPlayOutputs.values { output.stop() }
        airPlayOutputs.removeAll()
        for graph in graphs.values { graph.engine.stop(); graph.bus.removeAll() }
        graphs.removeAll()
    }
}

/// Preallocated stereo summing bus. Control operations wait for an in-flight
/// render to finish; the realtime callback never waits, allocates, or edits an
/// AVAudioEngine graph. Removing a source is a barrier for its render closure.
final class AppAudioRenderBus {
    typealias Render = (Int, UnsafeMutablePointer<AudioBufferList>) -> Void
    private let lock = NSLock()
    private var sources: [(id: UUID, render: Render)] = []
    private let capacity = 32768
    private let scratch: UnsafeMutablePointer<Float>
    private let sum: UnsafeMutablePointer<Float>
    private let limiter = AudioPeakLimiter()
    init() {
        scratch = .allocate(capacity: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)
        sum = .allocate(capacity: capacity * 2)
        sum.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { scratch.deallocate(); sum.deallocate() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return sources.isEmpty }
    func add(id: UUID, render: @escaping Render) {
        lock.lock(); defer { lock.unlock() }; sources.append((id, render))
    }
    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }; sources.removeAll { $0.id == id }
    }
    func removeAll() { lock.lock(); defer { lock.unlock() }; sources.removeAll() }

    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, frames <= capacity, lock.try() else { return }
        defer { lock.unlock() }
        memset(sum, 0, frames * 2 * MemoryLayout<Float>.size)
        for source in sources {
            memset(scratch, 0, frames * 2 * MemoryLayout<Float>.size)
            var temporary = AudioBufferList(mNumberBuffers: 1, mBuffers:
                AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: scratch))
            withUnsafeMutablePointer(to: &temporary) { source.render(frames, $0) }
            for index in 0..<(frames * 2) {
                sum[index] += scratch[index].isFinite ? scratch[index] : 0
            }
        }
        for frame in 0..<frames {
            var left = sum[frame * 2], right = sum[frame * 2 + 1]
            limiter.process(left: &left, right: &right)
            sum[frame * 2] = left; sum[frame * 2 + 1] = right
        }
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channel = 0
        for buffer in buffers {
            let width = Int(buffer.mNumberChannels)
            guard width > 0 else { continue }
            defer { channel += width }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / (4 * width))
            for frame in 0..<count {
                for offset in 0..<width {
                    let index = channel + offset
                    data[frame * width + offset] = channels == 1 ? (sum[frame * 2] + sum[frame * 2 + 1]) * 0.5
                        : (index < 2 ? sum[frame * 2 + index] : 0)
                }
            }
        }
    }
}
