// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation

/// Keeps the process resident while a notification-sound capture is running.
/// Plays an inaudible looping buffer and relies on the `audio` background mode.
/// It is started only by an explicit capture action and stopped when capture
/// ends; it is not used to keep the app alive at launch.
final class AudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false
    private var buffer: AVAudioPCMBuffer?

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            pcm.frameLength = 44_100
            if let channels = pcm.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    memset(channels[channel], 0, Int(pcm.frameLength) * MemoryLayout<Float>.size)
                }
            }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(pcm, at: nil, options: [.loops], completionHandler: nil)
            player.play()
            buffer = pcm
            running = true
        } catch {
            running = false
            NSLog("GestaltX: audio keepalive failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        buffer = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
