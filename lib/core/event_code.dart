import 'dart:math' as math;

/// Alphabet without look-alike characters (no 0/O, 1/I/L, U/V).
const _alphabet = 'ABCDEFGHJKMNPQRSTWXYZ23456789';

/// Number of characters in an event code: 10 chars from 29 symbols ≈ 48 bits.
const eventCodeLength = 10;

/// Generates a new random event code such as `K7MPQ-W3XZA`.
String generateEventCode([math.Random? random]) {
  final rng = random ?? math.Random.secure();
  final chars = List.generate(
    eventCodeLength,
    (_) => _alphabet[rng.nextInt(_alphabet.length)],
  );
  return formatEventCode(chars.join());
}

/// Uppercases and strips spaces/dashes. Returns null if the result is not a
/// valid code.
String? normalizeEventCode(String input) {
  final cleaned = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (cleaned.length != eventCodeLength) return null;
  for (final c in cleaned.split('')) {
    if (!_alphabet.contains(c)) return null;
  }
  return cleaned;
}

/// `K7MPQW3XZA` -> `K7MPQ-W3XZA`.
String formatEventCode(String normalized) {
  final half = normalized.length ~/ 2;
  return '${normalized.substring(0, half)}-${normalized.substring(half)}';
}
