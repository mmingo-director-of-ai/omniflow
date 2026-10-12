import AVFoundation
import UIKit
import Foundation

/// Opt-in device diagnostics. Never include book text, titles, or audio samples.
@MainActor
enum ReaderVoiceTrace {
    static func record(_ event: String, _ details: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["OMNIFLOW_READER_TRACE"] == "1" else { return }
        let session = AVAudioSession.sharedInstance()
        var fields = details
        fields["event"] = event
        fields["time"] = Date().timeIntervalSince1970
        fields["appState"] = UIApplication.shared.applicationState.rawValue
        fields["category"] = session.category.rawValue
        fields["mode"] = session.mode.rawValue
        fields["outputSampleRate"] = session.sampleRate
        fields["outputs"] = session.currentRoute.outputs.map { $0.portType.rawValue }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(Data("READER_TRACE ".utf8) + data + Data("\n".utf8))
    }
}
