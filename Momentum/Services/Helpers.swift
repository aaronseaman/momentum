import Foundation
import EventKit
import AVFoundation
import MomentumKit
#if canImport(FoundationModels)
import FoundationModels
#endif
#if os(macOS)
import ServiceManagement
#endif

// MARK: - Calendar blocking

/// Write-only calendar access: Momentum adds focus blocks but never reads your calendar.
final class CalendarService {
    private let store = EKEventStore()

    func addFocusBlock(title: String, start: Date, minutes: Int) async -> Bool {
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return false }
            let event = EKEvent(eventStore: store)
            event.title = "Focus: \(title)"
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
            event.notes = "Blocked by Momentum. One small step."
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Ambient focus sound

/// Soft brown noise generated on device (no audio files, no network).
final class AmbientSound {
    private var engine: AVAudioEngine?

    private final class NoiseState {
        var last: Float = 0
        var seed: UInt32 = 0x9E37_79B9
        func next() -> Float {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let white = Float(seed) / Float(UInt32.max) * 2 - 1
            last = (last + 0.02 * white) / 1.02
            return last * 3.0
        }
    }

    func start(volume: Float = 0.35) {
        guard engine == nil else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let state = NoiseState()
        let source = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = state.next() * volume
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

// MARK: - On-device AI (Apple Intelligence)

struct OnDeviceGenerator: TextGenerator {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw AIError.unavailable("Apple Intelligence isn't available on this device right now.")
            }
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw AIError.unavailable("On-device AI needs iOS 26 or macOS 26 with Apple Intelligence.")
    }
}

// MARK: - Launch at login (macOS)

enum LaunchAtLogin {
    static var isEnabled: Bool {
        #if os(macOS)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }

    static func set(_ enabled: Bool) {
        #if os(macOS)
        if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        #endif
    }
}
