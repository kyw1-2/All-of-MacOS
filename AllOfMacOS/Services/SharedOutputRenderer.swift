import AppKit
import AVFoundation

/// One shared AVAudioEngine per output device, with one source node per
/// tapped app. This is SoundSource's architecture and the fix for the
/// auto-pause bug: per-session engines start/stop on every attach, and each
/// engine start is a HAL configuration change that makes every video player
/// on the system pause. A pooled engine starts once when the first app needs
/// that device and stays running; app attach/detach only adds or removes a
/// source node on the already-running graph.
@MainActor
final class SharedOutputRenderer {
    static let shared = SharedOutputRenderer()

    final class SourceToken {
        let id = UUID()
        fileprivate var engine: AVAudioEngine?
        fileprivate var node: AVAudioSourceNode?
        fileprivate var uid: String = ""
    }

    private struct DeviceGraph {
        let engine: AVAudioEngine
        var outputDeviceID: AudioDeviceID
        var sources: [UUID: (node: AVAudioSourceNode, remove: () -> Void)]
    }

    private var graphs: [String: DeviceGraph] = [:]

    var activeDeviceUIDs: [String] { Array(graphs.keys) }

    /// Adds a render source on the given output device, starting (or reusing)
    /// that device's shared engine. Returns nil if the device has no playable
    /// output unit.
    func addSource(uid: String, device: AudioOutputDevice, format: AVAudioFormat,
                   render: @escaping (_ frameCount: Int, _ buffers: UnsafeMutablePointer<AudioBufferList>) -> Void) -> SourceToken? {
        let token = SourceToken()
        let graph: DeviceGraph
        if let existing = graphs[uid] {
            graph = existing
        } else {
            let engine = AVAudioEngine()
            let output = engine.outputNode
            guard let unit = output.audioUnit else { return nil }
            var deviceID = device.id
            let routeStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                   kAudioUnitScope_Global, 0, &deviceID,
                                                   UInt32(MemoryLayout<AudioDeviceID>.size))
            guard routeStatus == noErr,
                  output.outputFormat(forBus: 0).channelCount > 0,
                  output.outputFormat(forBus: 0).sampleRate > 0 else { return nil }
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
                render(Int(frameCount), buffers)
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            // Leave the mixer-to-output connection negotiated by AVAudioEngine;
            // it performs channel/sample-rate conversion for the device.
            engine.prepare()
            do { try engine.start() } catch { return nil }
            graphs[uid] = DeviceGraph(engine: engine, outputDeviceID: device.id, sources: [:])
            graphs[uid]?.sources[token.id] = (source, {})
            token.engine = engine
            token.node = source
            token.uid = uid
            return token
        }
        graphs[uid] = graph
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            render(Int(frameCount), buffers)
            return noErr
        }
        graph.engine.attach(source)
        graph.engine.connect(source, to: graph.engine.mainMixerNode, format: format)
        if !graph.engine.isRunning { try? graph.engine.start() }
        token.engine = graph.engine
        token.node = source
        token.uid = uid
        graphs[uid] = graph
        return token
    }

    func removeSource(_ token: SourceToken) {
        guard var graph = graphs[token.uid] else { return }
        if let node = token.node {
            graph.engine.detach(node)
        }
        graph.sources.removeValue(forKey: token.id)
        if graph.sources.isEmpty {
            graph.engine.stop()
            graphs.removeValue(forKey: token.uid)
        } else {
            graphs[token.uid] = graph
        }
    }

    /// The system default output moved: re-bind every graph whose device
    /// disappeared, keeping engines and sources alive where possible.
    func rebindIfNeeded(devices: [AudioOutputDevice]) {
        for (uid, graph) in graphs where !devices.contains(where: { $0.uid == uid }) {
            guard let replacement = devices.first else { continue }
            let output = graph.engine.outputNode
            guard let unit = output.audioUnit else { continue }
            var deviceID = replacement.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                var moved = graph
                graphs.removeValue(forKey: uid)
                moved.outputDeviceID = replacement.id
                graphs[replacement.uid] = moved
            }
        }
    }
}
