import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/core/protocol.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/run_library.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

Position _fix(GeoPoint p, DateTime t) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: t,
  accuracy: 5,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 90,
  headingAccuracy: 10,
  speed: 3,
  speedAccuracy: 1,
);

/// A point every 15 s from 06:00 local time.
List<DateTime> _times(int n, {DateTime? from}) {
  final t0 = from ?? DateTime(2026, 10, 3, 6);
  return [for (var i = 0; i < n; i++) t0.add(Duration(seconds: 15 * i))];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('ibex_runs');
    RunLibrary.debugDirectory = dir;
  });
  tearDown(() {
    RunLibrary.debugDirectory = null;
    dir.deleteSync(recursive: true);
  });

  /// A solo run whose GPS reports [points] at [times].
  Future<(RunSession, StreamController<Position>)> startRun() async {
    final gps = StreamController<Position>();
    final session = await RunSession.solo(
      await AppSettings.load(),
      Notifier(),
      locationSource: () => gps.stream,
    );
    return (session, gps);
  }

  test('a run is on disk while recorded, and kept when it ends', () async {
    final (session, gps) = await startRun();
    session.startRecording();
    final pts = eastLine(1500);
    final times = _times(pts.length);
    for (var i = 0; i < 20; i++) {
      gps.add(_fix(pts[i], times[i]));
    }
    await pumpEventQueue();
    expect(session.recorded, hasLength(20));

    // Mid-run, the file already holds the track.
    final file = (await session.trackFile())!;
    expect(file.parent.path, dir.path);
    expect(parseGpx(file.readAsStringSync()).track, hasLength(20));

    for (var i = 20; i < pts.length; i++) {
      gps.add(_fix(pts[i], times[i]));
    }
    await pumpEventQueue();
    final saved = (await session.leave())!;
    await gps.close();

    expect(saved.file.path, file.path);
    expect(saved.name, 'Morning run');
    expect(saved.start, times.first);
    expect(saved.distance, closeTo(1500, 2));
    expect(saved.elapsed, Duration(seconds: 15 * (pts.length - 1)));
    final gpx = parseGpx(saved.file.readAsStringSync());
    expect(gpx.name, 'Morning run');
    expect(gpx.track, hasLength(pts.length));
    expect(gpx.times.last, times.last.toUtc());

    final listed = await RunLibrary.list();
    expect(listed.single.id, saved.id);
    expect(listed.single.distance, saved.distance);
    expect(listed.single.elapsed, saved.elapsed);
  });

  test('a run shorter than 100 m is not kept', () async {
    final (session, gps) = await startRun();
    session.startRecording();
    final pts = eastLine(80, step: 40);
    final times = _times(pts.length);
    for (var i = 0; i < pts.length; i++) {
      gps.add(_fix(pts[i], times[i]));
    }
    await pumpEventQueue();
    final file = (await session.trackFile())!;
    expect(file.existsSync(), isTrue);

    expect(await session.leave(), isNull);
    await gps.close();
    expect(file.existsSync(), isFalse);
    expect(await RunLibrary.list(), isEmpty);
  });

  test('nothing is kept unless the run is recorded', () async {
    final (session, gps) = await startRun();
    final pts = eastLine(1500);
    final times = _times(pts.length);
    for (var i = 0; i < pts.length; i++) {
      gps.add(_fix(pts[i], times[i]));
    }
    await pumpEventQueue();
    expect(session.isRecording, isFalse);
    expect(session.distanceRun, closeTo(1500, 2));

    // The track can still be exported, as a temporary copy.
    final copy = (await session.trackFile())!;
    expect(copy.parent.path, isNot(dir.path));
    expect(parseGpx(copy.readAsStringSync()).track, hasLength(pts.length));

    expect(await session.leave(), isNull);
    await gps.close();
    expect(dir.listSync(), isEmpty);
    expect(await RunLibrary.list(), isEmpty);
  });

  test('each recording in a run is kept on its own', () async {
    final (session, gps) = await startRun();
    final pts = eastLine(1500);
    final times = _times(pts.length);
    Future<void> runTo(int from, int to) async {
      for (var i = from; i < to; i++) {
        gps.add(_fix(pts[i], times[i]));
      }
      await pumpEventQueue();
    }

    // 0-300 m not recorded, 300-800 m recorded, 800-1000 m not, then
    // 1000-1500 m recorded until the run ends.
    await runTo(0, 6);
    session.startRecording();
    expect(session.isRecording, isTrue);
    await runTo(6, 17);
    expect(session.recordingDistance, closeTo(500, 1));
    final first = (await session.stopRecording())!;
    expect(session.isRecording, isFalse);
    expect(session.recordingDistance, 0);
    expect(first.distance, closeTo(500, 1));
    expect(first.start, times[6]);
    expect(parseGpx(first.file.readAsStringSync()).track, hasLength(11));

    await runTo(17, 20);
    session.startRecording();
    await runTo(20, pts.length);
    final second = (await session.leave())!;
    await gps.close();
    expect(second.file.path, isNot(first.file.path));
    expect(second.distance, closeTo(500, 1));
    expect(second.start, times[20]);
    // The run itself counted every metre.
    expect(session.distanceRun, closeTo(1500, 2));

    final listed = await RunLibrary.list();
    expect(listed.map((r) => r.id), [second.id, first.id]);
  });

  test('a solo run keeps a group run waiting to be rejoined', () async {
    final settings = await AppSettings.load();
    final waiting = ActiveEvent(
      code: 'ABCD2345',
      role: Role.runner,
      startedAt: DateTime(2026, 10, 3, 6),
    );
    settings.activeEvent = waiting;
    final (session, gps) = await startRun();
    await session.leave();
    await gps.close();
    expect((await AppSettings.load()).activeEvent?.code, waiting.code);
  });

  test('stopping a recording with no track keeps nothing', () async {
    final (session, gps) = await startRun();
    session.startRecording();
    expect(await session.stopRecording(), isNull);
    expect(await session.stopRecording(), isNull);
    expect(session.isRecording, isFalse);
    session.dispose();
    await gps.close();
    expect(await RunLibrary.list(), isEmpty);
  });

  test('runs can be renamed and deleted', () async {
    final pts = eastLine(1200);
    final times = _times(pts.length);
    final w = await TrackWriter.create('Morning run', pts, times);
    final run = (await RunLibrary.finish(
      w.file,
      name: 'Morning run',
      points: pts,
      times: times,
    ))!;

    final renamed = await RunLibrary.rename(run, 'Wadi Degla loop');
    expect(renamed.name, 'Wadi Degla loop');
    expect(renamed.exportName, 'Wadi Degla loop 2026-10-03.gpx');
    expect(parseGpx(run.file.readAsStringSync()).name, 'Wadi Degla loop');
    expect((await RunLibrary.list()).single.name, 'Wadi Degla loop');

    final details = await RunLibrary.open(renamed);
    expect(details.stats.distance, closeTo(1200, 2));
    expect(details.route.name, 'Wadi Degla loop');

    await RunLibrary.delete(renamed);
    expect(run.file.existsSync(), isFalse);
    expect(await RunLibrary.list(), isEmpty);
  });

  test('files not in the index are read, and cut-off ones mended', () async {
    final pts = eastLine(1000);
    // An export from an older version of the app...
    File('${dir.path}/run_2026-09-01T07-00-00.gpx').writeAsStringSync(
      writeGpx(
        name: 'Old export',
        points: pts,
        times: _times(pts.length, from: DateTime(2026, 9, 1, 7)),
      ),
    );
    // ...a run cut off mid-write when the app was killed...
    final full = writeGpx(
      name: 'Cut short',
      points: pts,
      times: _times(pts.length, from: DateTime(2026, 10, 2, 7)),
    );
    File('${dir.path}/run_2026-10-02T07-00-00.gpx')
        .writeAsStringSync(full.substring(0, full.length - 60));
    // ...and a file that isn't GPX at all.
    File('${dir.path}/notes.gpx').writeAsStringSync('hello');

    final runs = await RunLibrary.list();
    expect(runs.map((r) => r.name), ['Cut short', 'Old export']);
    expect(runs.last.distance, closeTo(1000, 1));
    expect(runs.first.distance, closeTo(950, 1));
    expect(File('${dir.path}/.index.json').existsSync(), isTrue);

    final details = await RunLibrary.open(runs.first);
    expect(details.gpx.track, hasLength(pts.length - 1));

    // Listed again from the index, without reading the files.
    final again = await RunLibrary.list();
    expect(again.map((r) => r.distance), runs.map((r) => r.distance));
  });

  test('the writer adds to the same file, also after a restart', () async {
    final pts = eastLine(600);
    final times = _times(pts.length);
    final w = await TrackWriter.create(
      'Morning run',
      pts.sublist(0, 5),
      times.sublist(0, 5),
    );
    await w.append('Morning run', pts.sublist(0, 9), times.sublist(0, 9));
    expect(w.written, 9);
    expect(parseGpx(w.file.readAsStringSync()).track, hasLength(9));

    // The app is killed in the middle of a write, then the run resumes.
    final text = w.file.readAsStringSync();
    w.file.writeAsStringSync(text.substring(0, text.length - 50));
    final (again, gpx) = (await TrackWriter.resume(w.id))!;
    expect(again.file.path, w.file.path);
    expect(gpx.name, 'Morning run');
    expect(gpx.track, hasLength(8));

    await again.append(
      'Morning run',
      [...gpx.track, ...pts.sublist(9)],
      [...gpx.times, ...times.sublist(9)],
    );
    expect(parseGpx(again.file.readAsStringSync()).track, hasLength(12));

    // A new name rewrites the file.
    await again.append(
      'Sunday long run',
      [...gpx.track, ...pts.sublist(9)],
      [...gpx.times, ...times.sublist(9)],
    );
    expect(parseGpx(again.file.readAsStringSync()).name, 'Sunday long run');

    expect(await TrackWriter.resume('missing.gpx'), isNull);
    expect(await TrackWriter.resume('../escape.gpx'), isNull);
  });
}
