import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Spoken navigation cues ("Sharp left in 60 metres"). Plays over music
/// (ducking it) and never throws: if speech isn't available the app simply
/// stays quiet and relies on vibration and notifications.
class Voice {
  FlutterTts? _tts;
  Future<void>? _init;

  Future<void> _setUp() async {
    try {
      final tts = FlutterTts();
      await tts.setLanguage('en-US');
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1);
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.duckOthers,
        ], IosTextToSpeechAudioMode.voicePrompt);
      }
      _tts = tts;
    } on Object catch (e) {
      debugPrint('Voice cues unavailable: $e');
    }
  }

  Future<void> say(String text) async {
    await (_init ??= _setUp());
    try {
      await _tts?.stop();
      await _tts?.speak(text);
    } on Object catch (e) {
      debugPrint('Voice cue failed: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _tts?.stop();
    } on Object {
      // Nothing to clean up.
    }
  }
}
