import AVFoundation
import AudioToolbox
import Flutter
import UIKit
// Needed for FlutterLocalNotificationsPlugin.setPluginRegistrantCallback.
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let alarmAudio = AlarmAudio()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Notification buttons ("Ate it", "In 5 min") run in a background
    // engine; this gives it the plugins it needs.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    alarmAudio.listen(on: engineBridge.applicationRegistrar.messenger())
  }
}

/// Plays the alarm sounds (lib/services/alarm_audio.dart) at full volume,
/// through the silent switch and over music, and vibrates. A notification
/// sound can't do any of that.
final class AlarmAudio: NSObject, AVAudioPlayerDelegate {
  private var channel: FlutterMethodChannel?
  private var player: AVAudioPlayer?

  func listen(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ibextrails/alarm_audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "play",
        let name = (call.arguments as? [String: Any])?["name"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.play(name) ?? false)
    }
    self.channel = channel
  }

  private func play(_ name: String) -> Bool {
    guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return false }
    do {
      // Same session as the spoken turn warnings (lib/services/voice.dart):
      // playback ignores the silent switch, and mixing with ducking turns
      // music down instead of stopping it, and works in the background.
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
      try session.setActive(true)
      player?.stop()
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.volume = 1
      guard player.play() else { return false }
      self.player = player
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      return true
    } catch {
      NSLog("Alarm sound failed: \(error)")
      return false
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
    guard player === self.player else { return }
    self.player = nil
    // Lets the music come back up.
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
