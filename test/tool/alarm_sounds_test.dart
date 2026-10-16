// Synthesizes the alarm sounds and writes them where each platform bundles
// them, android/app/src/main/res/raw/ and ios/Runner/Sounds/:
//
//   IBEX_WRITE_SOUNDS=1 flutter test test/tool/alarm_sounds_test.dart
//
// Each sound is built to be told apart from the others, and from ordinary
// notifications, by ear:
//   fuel:  a bright bell arpeggio, played twice. "Time to eat."
//   alarm: fast beeps in groups of four, like an alarm clock. "Check
//          where you are."
//   sos:   a rising siren. "Someone needs help."
// Most of the energy is at 1-4 kHz, where phone speakers are loudest and
// ears most sensitive, and every sound peaks just below full scale.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/services/alarm_audio.dart';

const rate = 22050;

/// Highest partial frequency kept: below the Nyquist limit (11 025 Hz) so
/// nothing aliases, and above what phone speakers play loudly anyway.
const _topHz = 9500.0;

final _write = Platform.environment['IBEX_WRITE_SOUNDS'] != null;

/// The WAV file for each sound, as bundled with the app.
Uint8List synthesize(AlarmSound sound) => _wav(switch (sound) {
  AlarmSound.fuel => _fuel(),
  AlarmSound.alarm => _alarm(),
  AlarmSound.sos => _sos(),
});

/// Glockenspiel-like strikes of G6 C7 E7 G7, then the same again, softly
/// saturated: bells die away fast, and this keeps the chime about as loud
/// as the alarms.
Float64List _fuel() {
  const notes = [1568.0, 2093.0, 2637.0, 3136.0];
  final out = Float64List((2.6 * rate).round());
  for (final start in const [0.0, 1.05]) {
    for (var i = 0; i < notes.length; i++) {
      _bell(out, start + i * 0.13, notes[i], ring: i == 3 ? 1.0 : 0.8);
    }
  }
  return _saturate(out, 2);
}

/// A struck metal bar: inharmonic partials, the higher ones dying first.
void _bell(Float64List out, double at, double freq, {required double ring}) {
  const partials = [(1.0, 1.0, 1.0), (2.756, 0.5, 0.4), (5.404, 0.25, 0.15)];
  final from = (at * rate).round();
  for (var n = 0; from + n < out.length; n++) {
    final t = n / rate;
    final attack = math.min(1.0, t / 0.002);
    var v = 0.0;
    for (final (ratio, amp, decay) in partials) {
      final f = freq * ratio;
      if (f > _topHz) continue;
      v += amp * math.exp(-t / (ring * decay)) * math.sin(2 * math.pi * f * t);
    }
    out[from + n] += attack * v;
  }
}

/// Four groups of four quick 2.9 kHz beeps.
Float64List _alarm() {
  const beep = 0.075, gap = 0.045, pause = 0.28;
  const group = 4 * beep + 3 * gap + pause;
  final out = Float64List(((4 * group - pause) * rate).round());
  for (var g = 0; g < 4; g++) {
    for (var b = 0; b < 4; b++) {
      final at = g * group + b * (beep + gap);
      final from = (at * rate).round();
      final length = (beep * rate).round();
      for (var n = 0; n < length; n++) {
        final t = n / rate;
        const f = 2900.0;
        out[from + n] =
            _fade(n, length, 0.003) *
            (math.sin(2 * math.pi * f * t) +
                0.25 * math.sin(2 * math.pi * 2 * f * t) +
                0.3 * math.sin(2 * math.pi * 3 * f * t));
      }
    }
  }
  return out;
}

/// Five "whoops": a square-wave siren gliding up from 650 Hz to 1.9 kHz,
/// then dropping back.
Float64List _sos() {
  const cycle = 0.62, rise = 0.5, low = 650.0, high = 1900.0;
  const total = 5 * cycle;
  final out = Float64List((total * rate).round());
  var phase = 0.0;
  for (var n = 0; n < out.length; n++) {
    final t = (n / rate) % cycle;
    final up = t < rise ? t / rise : 1 - (t - rise) / (cycle - rise);
    final f = low * math.pow(high / low, up);
    phase += 2 * math.pi * f / rate;
    var v = 0.0;
    for (var k = 1; k * f < _topHz; k += 2) {
      v += _taper(k * f) * math.sin(k * phase) / k;
    }
    out[n] = _fade(n, out.length, 0.01) * v;
  }
  return out;
}

/// Weight for a partial at [hz]: 1 up to 7 kHz, then fading smoothly to 0
/// at [_topHz], so partials don't click in and out as the pitch glides.
double _taper(double hz) {
  const from = 7000.0;
  if (hz <= from) return 1;
  return 0.5 + 0.5 * math.cos(math.pi * (hz - from) / (_topHz - from));
}

/// tanh soft clipping: quiet parts get up to [drive] times louder, peaks
/// stay put.
Float64List _saturate(Float64List x, double drive) {
  var peak = 0.0;
  for (final s in x) {
    peak = math.max(peak, s.abs());
  }
  final k = 1 / _tanh(drive);
  return Float64List.fromList([for (final s in x) k * _tanh(drive * s / peak)]);
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// Raised-cosine fade in and out over [seconds], so tones start and stop
/// without clicks.
double _fade(int n, int length, double seconds) {
  final ramp = seconds * rate;
  final edge = math.min(n, length - 1 - n);
  if (edge >= ramp) return 1;
  return 0.5 - 0.5 * math.cos(math.pi * edge / ramp);
}

/// 16-bit mono PCM, scaled to peak at -1 dBFS.
Uint8List _wav(Float64List samples) {
  var peak = 0.0;
  for (final s in samples) {
    peak = math.max(peak, s.abs());
  }
  final gain = math.pow(10, -1 / 20) * 32767 / peak;
  final data = ByteData(44 + samples.length * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i] * gain).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Where each platform bundles [sound].
List<File> bundled(AlarmSound sound) => [
  File('android/app/src/main/res/raw/${sound.file}.wav'),
  File('ios/Runner/Sounds/${sound.file}.wav'),
];

void main() {
  test('write the alarm sounds', () {
    for (final sound in AlarmSound.values) {
      final wav = synthesize(sound);
      for (final f in bundled(sound)) {
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(wav);
      }
    }
  }, skip: _write ? false : 'set IBEX_WRITE_SOUNDS=1 to write');

  test('the bundled sounds are the ones synthesized here', () {
    for (final sound in AlarmSound.values) {
      final want = synthesize(sound);
      for (final f in bundled(sound)) {
        final got = f.readAsBytesSync();
        expect(got.length, want.length, reason: f.path);
        expect(got.sublist(0, 44), want.sublist(0, 44), reason: f.path);
        // Allow 1 LSB for sin() rounding differences between machines.
        final a = ByteData.sublistView(got), b = ByteData.sublistView(want);
        for (var i = 44; i < got.length; i += 2) {
          final d = a.getInt16(i, Endian.little) - b.getInt16(i, Endian.little);
          if (d.abs() > 1) fail('${f.path} differs at byte $i');
        }
      }
    }
  }, skip: _write ? 'writing them' : false);
}
