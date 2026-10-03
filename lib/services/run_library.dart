import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/geo.dart';
import '../core/gpx.dart';
import '../core/route.dart';
import '../core/run_stats.dart';

/// A run kept on this phone, as listed in My runs.
class SavedRun {
  const SavedRun({
    required this.file,
    required this.name,
    required this.start,
    required this.distance,
    this.elapsed,
    this.moving,
    this.ascent = 0,
  });

  /// The run's GPX file.
  final File file;
  final String name;
  final DateTime start;

  /// Metres.
  final double distance;
  final Duration? elapsed;
  final Duration? moving;
  final double ascent;

  /// The file name, which identifies the run.
  String get id => file.uri.pathSegments.last;

  /// A readable name for a copy of the file, e.g. `Wadi loop 2026-10-03.gpx`.
  String get exportName {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '').trim();
    final day = start.toLocal().toIso8601String().substring(0, 10);
    return '${safe.isEmpty ? 'Run' : safe} $day.gpx';
  }

  Map<String, Object?> _toJson() => {
    'n': name,
    's': start.millisecondsSinceEpoch,
    'd': distance,
    if (elapsed != null) 'e': elapsed!.inSeconds,
    if (moving != null) 'm': moving!.inSeconds,
    'a': ascent,
  };

  static SavedRun? _fromJson(File file, Map<String, Object?> json) {
    try {
      Duration? seconds(Object? v) =>
          v == null ? null : Duration(seconds: (v as num).toInt());
      return SavedRun(
        file: file,
        name: json['n'] as String,
        start: DateTime.fromMillisecondsSinceEpoch((json['s'] as num).toInt()),
        distance: (json['d'] as num).toDouble(),
        elapsed: seconds(json['e']),
        moving: seconds(json['m']),
        ascent: (json['a'] as num?)?.toDouble() ?? 0,
      );
    } on Object {
      return null;
    }
  }
}

/// A run read back from its file, ready to show.
class RunDetails {
  const RunDetails(this.gpx, this.stats, this.route);

  final GpxData gpx;
  final RunStats stats;

  /// The track as a route: drawn on the map and the elevation profile, and
  /// followed when running it again.
  final TrailRoute route;
}

/// Your runs, kept on the phone as GPX files in `<documents>/recordings`.
///
/// A hidden index (`.index.json`) remembers each run's name and numbers, so
/// the list opens without reading every file.
class RunLibrary {
  RunLibrary._();

  /// Where runs are kept, instead of the app's documents folder.
  @visibleForTesting
  static Directory? debugDirectory;

  /// Shorter runs aren't kept (e.g. an organizer who never left the start).
  static const minDistance = 100.0;

  static Future<Directory> directory() async {
    final dir =
        debugDirectory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/recordings',
        );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _queue = Future.value();

  /// Runs [job] after any earlier change, so index updates don't overwrite
  /// each other.
  static Future<T> _serial<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Every run, newest first.
  ///
  /// Files missing from the index, or changed since (exports from older
  /// versions, runs cut short when the app was closed), are read in the
  /// background and added. Files that aren't readable GPX are left out.
  static Future<List<SavedRun>> list() => _serial(() async {
    final dir = await directory();
    final index = await _readIndex(dir);
    final files = <File, FileStat>{};
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.gpx')) {
        files[e] = await e.stat();
      }
    }
    final ids = {for (final f in files.keys) f.uri.pathSegments.last};
    var changed = index.keys.any((id) => !ids.contains(id));
    index.removeWhere((id, _) => !ids.contains(id));

    final runs = <SavedRun>[];
    final stale = <File>[];
    for (final MapEntry(key: file, value: stat) in files.entries) {
      final entry = index[file.uri.pathSegments.last];
      final run = entry != null && _fresh(entry, stat)
          ? SavedRun._fromJson(file, entry)
          : null;
      if (run == null) {
        stale.add(file);
      } else {
        runs.add(run);
      }
    }
    if (stale.isNotEmpty) {
      final summaries = await compute(_summarize, [
        for (final f in stale) f.path,
      ]);
      for (var i = 0; i < stale.length; i++) {
        final id = stale[i].uri.pathSegments.last;
        final summary = summaries[i];
        final run = summary == null
            ? null
            : SavedRun._fromJson(stale[i], summary);
        if (run == null) {
          index.remove(id);
        } else {
          index[id] = _entry(run, files[stale[i]]!);
          runs.add(run);
        }
      }
      changed = true;
    }
    if (changed) await _writeIndex(dir, index);
    runs.sort((a, b) => b.start.compareTo(a.start));
    return runs;
  });

  /// Reads [run] back in the background (long runs take a moment).
  static Future<RunDetails> open(SavedRun run) =>
      compute(_open, (run.file.path, run.name));

  /// Renames [run], in the list and inside its GPX file.
  static Future<SavedRun> rename(SavedRun run, String name) =>
      _serial(() async {
        await compute(_rewriteNamed, (run.file.path, name));
        final renamed = SavedRun(
          file: run.file,
          name: name,
          start: run.start,
          distance: run.distance,
          elapsed: run.elapsed,
          moving: run.moving,
          ascent: run.ascent,
        );
        final index = await _readIndex(run.file.parent);
        index[run.id] = _entry(renamed, await run.file.stat());
        await _writeIndex(run.file.parent, index);
        return renamed;
      });

  static Future<void> delete(SavedRun run) => _serial(() async {
    if (await run.file.exists()) await run.file.delete();
    final index = await _readIndex(run.file.parent);
    if (index.remove(run.id) != null) {
      await _writeIndex(run.file.parent, index);
    }
  });

  /// Completes a recording: writes [file] once more under the run's final
  /// [name] and adds it to the list. Returns null, deleting the file, when
  /// the run is shorter than [minDistance].
  static Future<SavedRun?> finish(
    File file, {
    required String name,
    required List<GeoPoint> points,
    required List<DateTime?> times,
  }) {
    // Copies: the recording may still grow while this waits its turn.
    final pts = List.of(points);
    final ts = List.of(times.take(pts.length));
    return _serial(() async {
      final stats = RunStats.of(pts, ts);
      final id = file.uri.pathSegments.last;
      final index = await _readIndex(file.parent);
      if (pts.length < 2 || stats.distance < minDistance) {
        if (await file.exists()) await file.delete();
        if (index.remove(id) != null) await _writeIndex(file.parent, index);
        return null;
      }
      await _replace(file, writeGpx(name: name, points: pts, times: ts));
      final run = SavedRun(
        file: file,
        name: name,
        start: ts.nonNulls.firstOrNull ?? DateTime.now(),
        distance: stats.distance,
        elapsed: stats.elapsed,
        moving: stats.moving,
        ascent: stats.ascent,
      );
      index[id] = _entry(run, await file.stat());
      await _writeIndex(file.parent, index);
      return run;
    });
  }

  static File _indexFile(Directory dir) => File('${dir.path}/.index.json');

  static Future<Map<String, Map<String, Object?>>> _readIndex(
    Directory dir,
  ) async {
    try {
      final json = jsonDecode(await _indexFile(dir).readAsString()) as Map;
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is Map)
            e.key as String: (e.value as Map).cast<String, Object?>(),
      };
    } on Object {
      // Missing or unreadable: rebuilt from the files.
      return {};
    }
  }

  static Future<void> _writeIndex(
    Directory dir,
    Map<String, Map<String, Object?>> index,
  ) => _replace(_indexFile(dir), jsonEncode(index));

  /// Index entry for [run], with the file's size and time to notice when
  /// it changes outside the index.
  static Map<String, Object?> _entry(SavedRun run, FileStat stat) => {
    ...run._toJson(),
    'z': stat.size,
    't': stat.modified.millisecondsSinceEpoch,
  };

  static bool _fresh(Map<String, Object?> entry, FileStat stat) =>
      entry['z'] == stat.size &&
      entry['t'] == stat.modified.millisecondsSinceEpoch;
}

/// Keeps a run's GPX file up to date while it is recorded, so the run
/// survives the app being closed. New points go in just before the closing
/// tags, and the file is a complete GPX document after every write.
class TrackWriter {
  TrackWriter._(this.file, this._name);

  final File file;
  String _name;

  /// How many of the recording's points are in the file.
  int written = 0;

  /// The file name, which identifies the run.
  String get id => file.uri.pathSegments.last;

  /// Starts the file for a new recording, named after its start time.
  static Future<TrackWriter> create(
    String name,
    List<GeoPoint> points,
    List<DateTime?> times,
  ) async {
    final dir = await RunLibrary.directory();
    final start = (times.isEmpty ? null : times.first) ?? DateTime.now();
    final stamp = start
        .toLocal()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    var file = File('${dir.path}/run_$stamp.gpx');
    for (var n = 2; await file.exists(); n++) {
      file = File('${dir.path}/run_${stamp}_$n.gpx');
    }
    final w = TrackWriter._(file, name);
    await w.rewrite(name, points, times);
    return w;
  }

  /// Picks up recording [id] after the app was closed mid-run. Returns the
  /// writer and what the file holds so far, or null if the file is gone.
  static Future<(TrackWriter, GpxData)?> resume(String id) async {
    if (id.contains('/') || id.contains(r'\')) return null;
    final dir = await RunLibrary.directory();
    final file = File('${dir.path}/$id');
    if (!await file.exists()) return null;
    final gpx = _parseRun(await file.readAsString());
    final w = TrackWriter._(file, gpx.name ?? 'Run');
    // Also tidies up a file that was cut off mid-write.
    await w.rewrite(w._name, gpx.track, gpx.times);
    return (w, gpx);
  }

  /// Adds the points recorded since the last write. A new [name] (e.g. the
  /// event's, once it arrives) rewrites the file.
  Future<void> append(
    String name,
    List<GeoPoint> points,
    List<DateTime?> times,
  ) async {
    final count = points.length;
    if (name != _name) return rewrite(name, points, times);
    if (count <= written) return;
    final footer = ascii.encode(gpxFooter);
    final raf = await file.open(mode: FileMode.append);
    var appended = false;
    try {
      final end = await raf.length() - footer.length;
      if (end > 0) {
        await raf.setPosition(end);
        if (listEquals(await raf.read(footer.length), footer)) {
          await raf.truncate(end);
          await raf.setPosition(end);
          await raf.writeString(
            gpxTrackPoints(
                  points.sublist(written, count),
                  times.sublist(written, count),
                ) +
                gpxFooter,
          );
          appended = true;
        }
      }
    } finally {
      await raf.close();
    }
    if (appended) {
      written = count;
    } else {
      // Not the ending we wrote (changed outside the app?): start afresh.
      await rewrite(name, points, times);
    }
  }

  /// Writes the whole file again.
  Future<void> rewrite(
    String name,
    List<GeoPoint> points,
    List<DateTime?> times,
  ) async {
    final count = points.length;
    await _replace(
      file,
      writeGpx(
        name: name,
        points: points.sublist(0, count),
        times: times.sublist(0, count),
      ),
    );
    _name = name;
    written = count;
  }
}

/// Replaces [file]'s contents in one step, so a write cut short leaves the
/// old file rather than half a new one.
Future<void> _replace(File file, String text) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}

/// Parses a run file, mending one that was cut off mid-write.
GpxData _parseRun(String text) {
  try {
    return parseGpx(text);
  } on GpxFormatException {
    final mended = repairGpx(text);
    if (mended == null) rethrow;
    return parseGpx(mended);
  }
}

// ---- Run in a background isolate ------------------------------------------

/// Index entries (without file size and time) for the files at [paths];
/// null for files that aren't readable GPX.
List<Map<String, Object?>?> _summarize(List<String> paths) => [
  for (final path in paths) _summary(File(path)),
];

Map<String, Object?>? _summary(File file) {
  try {
    final gpx = _parseRun(file.readAsStringSync());
    final stats = RunStats.of(gpx.track, gpx.times);
    final start = gpx.times.nonNulls.firstOrNull ?? file.lastModifiedSync();
    return SavedRun(
      file: file,
      name: gpx.name ?? defaultRunName(start),
      start: start,
      distance: stats.distance,
      elapsed: stats.elapsed,
      moving: stats.moving,
      ascent: stats.ascent,
    )._toJson();
  } on Object {
    return null;
  }
}

RunDetails _open((String, String) args) {
  final (path, name) = args;
  final gpx = _parseRun(File(path).readAsStringSync());
  return RunDetails(
    gpx,
    RunStats.of(gpx.track, gpx.times),
    TrailRoute.fromPoints(name, gpx.track, waypoints: gpx.waypoints),
  );
}

void _rewriteNamed((String, String) args) {
  final (path, name) = args;
  final file = File(path);
  final gpx = _parseRun(file.readAsStringSync());
  final tmp = File('$path.tmp')
    ..writeAsStringSync(
      writeGpx(name: name, points: gpx.track, times: gpx.times),
      flush: true,
    );
  tmp.renameSync(path);
}
