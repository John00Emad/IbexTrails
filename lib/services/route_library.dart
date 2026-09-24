import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/gpx.dart';
import '../core/route.dart';

class SavedRoute {
  const SavedRoute(this.file, this.name, this.modified);
  final File file;
  final String name;
  final DateTime modified;
}

/// GPX files the user has imported, kept on the device so routes can be
/// reused and work without a connection.
class RouteLibrary {
  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/routes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Parses [gpxText], saves it and returns the route. Throws
  /// [GpxFormatException] for invalid files.
  static Future<TrailRoute> import(String gpxText, {String? fileName}) async {
    final gpx = parseGpx(gpxText);
    final fallback = _stripExtension(fileName) ?? 'Route';
    final route = TrailRoute.fromGpx(gpx, fallbackName: fallback);
    final dir = await _dir();
    final safe = route.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await File('${dir.path}/${safe.isEmpty ? 'route' : safe}_$stamp.gpx')
        .writeAsString(gpxText);
    return route;
  }

  static Future<List<SavedRoute>> list() async {
    final dir = await _dir();
    final out = <SavedRoute>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.gpx')) continue;
      final stat = await e.stat();
      out.add(SavedRoute(e, _displayName(e), stat.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  static Future<TrailRoute> load(SavedRoute saved) async {
    final gpx = parseGpx(await saved.file.readAsString());
    return TrailRoute.fromGpx(gpx, fallbackName: saved.name);
  }

  static Future<void> delete(SavedRoute saved) => saved.file.delete();

  /// Saves a recorded run as GPX and returns the file.
  static Future<File> saveRecording(String name, String gpxText) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/recordings');
    if (!await dir.exists()) await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}/run_${stamp.substring(0, 19)}.gpx');
    return file.writeAsString(gpxText);
  }

  static String _displayName(File f) {
    final base = f.uri.pathSegments.last;
    final noExt = _stripExtension(base)!;
    return noExt.replaceFirst(RegExp(r'_\d{10,}$'), '').replaceAll('_', ' ');
  }

  static String? _stripExtension(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
