import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Wire format version for encrypted envelopes.
const _envelopeVersion = 1;
const _flagGzip = 0x01;
const _nonceLength = 12;
const _macLength = 16;

/// End-to-end encryption for one event.
///
/// Everything published to the relay (positions, route, announcements) is
/// sealed with AES-256-GCM using a key derived from the event code, so the
/// relay operator and anyone else listening only see opaque bytes on a
/// hashed topic name. Only people who were given the event code can read or
/// forge messages.
class EventCipher {
  EventCipher._(this.topicId, this._key);

  /// Opaque identifier used in topic names, derived from the event code.
  final String topicId;
  final SecretKey _key;

  static final _aes = AesGcm.with256bits();

  /// Derives the topic id and key from a normalized event code.
  static Future<EventCipher> forCode(String normalizedCode) async {
    final topicHash = await Sha256().hash(
      utf8.encode('ibextrails/topic/v1/$normalizedCode'),
    );
    final topicId = topicHash.bytes
        .take(12)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 20000,
      bits: 256,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(normalizedCode)),
      nonce: utf8.encode('ibextrails/key/v1'),
    );
    return EventCipher._(topicId, key);
  }

  /// Encrypts a JSON-encodable object. Large payloads are gzipped first.
  Future<Uint8List> seal(Object json) async {
    var plain = utf8.encode(jsonEncode(json));
    var flags = 0;
    if (plain.length > 512) {
      plain = Uint8List.fromList(gzip.encode(plain));
      flags |= _flagGzip;
    }
    final box = await _aes.encrypt(plain, secretKey: _key);
    final out = BytesBuilder(copy: false)
      ..addByte(_envelopeVersion)
      ..addByte(flags)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Decrypts an envelope produced by [seal]. Returns null if the bytes are
  /// not a valid envelope for this event (wrong key, tampered, other app).
  Future<Object?> open(List<int> bytes) async {
    if (bytes.length < 2 + _nonceLength + _macLength) return null;
    if (bytes[0] != _envelopeVersion) return null;
    final flags = bytes[1];
    final nonce = bytes.sublist(2, 2 + _nonceLength);
    final cipherText = bytes.sublist(
      2 + _nonceLength,
      bytes.length - _macLength,
    );
    final mac = Mac(bytes.sublist(bytes.length - _macLength));
    try {
      var plain = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: _key,
      );
      if (flags & _flagGzip != 0) plain = gzip.decode(plain);
      return jsonDecode(utf8.decode(plain));
    } on SecretBoxAuthenticationError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
