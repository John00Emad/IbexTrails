import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/crypto.dart';
import 'package:ibex_trails/core/event_code.dart';

void main() {
  test('round trip, small and gzipped payloads', () async {
    final c = await EventCipher.forCode('ABCDEFGHJK');
    final small = await c.seal({'hello': 'trail'});
    expect(await c.open(small), {'hello': 'trail'});

    final big = {'data': List.generate(2000, (i) => i)};
    final sealed = await c.seal(big);
    expect(sealed[1] & 1, 1, reason: 'gzip flag set');
    expect(await c.open(sealed), big);
  });

  test('same code derives the same topic; different codes do not', () async {
    final a1 = await EventCipher.forCode('ABCDEFGHJK');
    final a2 = await EventCipher.forCode('ABCDEFGHJK');
    final b = await EventCipher.forCode('ABCDEFGHJM');
    expect(a1.topicId, a2.topicId);
    expect(a1.topicId, isNot(b.topicId));
    expect(a1.topicId, isNot(contains('ABCDEFGHJK')));
    expect(await a2.open(await a1.seal('x')), 'x');
  });

  test('wrong key, tampering and junk are rejected', () async {
    final a = await EventCipher.forCode('ABCDEFGHJK');
    final b = await EventCipher.forCode('ABCDEFGHJM');
    final sealed = await a.seal({'secret': 1});
    expect(await b.open(sealed), isNull);
    final tampered = [...sealed]..[20] ^= 0xff;
    expect(await a.open(tampered), isNull);
    expect(await a.open([1, 2, 3]), isNull);
    expect(await a.open('{"t":"pos"}'.codeUnits), isNull);
  });

  test('event codes', () {
    final code = generateEventCode();
    expect(code, matches(RegExp(r'^[A-Z2-9]{5}-[A-Z2-9]{5}$')));
    expect(normalizeEventCode(code.toLowerCase()), code.replaceAll('-', ''));
    expect(normalizeEventCode(' abcde fghjk '), 'ABCDEFGHJK');
    expect(normalizeEventCode('ABCDE-FGHJ'), isNull);
    expect(normalizeEventCode('ABCDE-FGHJ0'), isNull, reason: '0 not allowed');
    expect(formatEventCode('ABCDEFGHJK'), 'ABCDE-FGHJK');
  });

  test('finds the event code in an invite or scanned QR text', () {
    expect(
      findEventCode(
        'Join my trail run "Friday team run" on IbexTrails.\n'
        'Event code: K7MPQ-W3XZA',
      ),
      'K7MPQW3XZA',
    );
    expect(findEventCode('code k7mpqw3xza please'), 'K7MPQW3XZA');
    // Words that look like codes but use letters codes never contain.
    expect(findEventCode('Hello there IbexTrails'), isNull);
    expect(findEventCode('https://example.com/photo123'), isNull);
    expect(findEventCode(''), isNull);
  });
}
