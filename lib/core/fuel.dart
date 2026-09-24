import 'dart:math' as math;

/// Something a runner eats or drinks, with nutrition per serving. Values
/// should come from the product label: accurate logging depends on them.
class FuelItem {
  const FuelItem({
    required this.id,
    required this.name,
    this.carbs = 0,
    this.fluidMl = 0,
    this.sodiumMg = 0,
  });

  final String id;
  final String name;

  /// Carbohydrate per serving (g).
  final double carbs;
  final double fluidMl;
  final double sodiumMg;

  bool get isFood => carbs > 0;

  FuelItem copyWith({
    String? name,
    double? carbs,
    double? fluidMl,
    double? sodiumMg,
  }) => FuelItem(
    id: id,
    name: name ?? this.name,
    carbs: carbs ?? this.carbs,
    fluidMl: fluidMl ?? this.fluidMl,
    sodiumMg: sodiumMg ?? this.sodiumMg,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'c': carbs,
    'f': fluidMl,
    's': sodiumMg,
  };

  static FuelItem fromJson(Map json) => FuelItem(
    id: json['id'] as String,
    name: json['n'] as String,
    carbs: (json['c'] as num?)?.toDouble() ?? 0,
    fluidMl: (json['f'] as num?)?.toDouble() ?? 0,
    sodiumMg: (json['s'] as num?)?.toDouble() ?? 0,
  );
}

/// Typical values; runners should edit them to match what they carry.
const defaultFuelItems = [
  FuelItem(id: 'gel', name: 'Energy gel', carbs: 25, sodiumMg: 50),
  FuelItem(id: 'chew', name: 'Chew (1 piece)', carbs: 8, sodiumMg: 15),
  FuelItem(
    id: 'drink',
    name: 'Sports drink 500 ml',
    carbs: 30,
    fluidMl: 500,
    sodiumMg: 250,
  ),
  FuelItem(id: 'date', name: 'Medjool date', carbs: 18),
  FuelItem(id: 'banana', name: 'Banana', carbs: 27),
  FuelItem(id: 'sips', name: 'Water, a few sips', fluidMl: 150),
  FuelItem(id: 'water', name: 'Water 500 ml', fluidMl: 500),
];

/// The runner's fuelling strategy.
class FuelPlan {
  const FuelPlan({
    this.enabled = true,
    this.carbsPerHour = 60,
    this.fluidMlPerHour = 500,
    this.intervalMin = 20,
    this.firstAfterMin = 30,
    this.hotDay = false,
    this.items = defaultFuelItems,
  });

  final bool enabled;
  final double carbsPerHour;
  final double fluidMlPerHour;

  /// Minutes between reminders.
  final int intervalMin;

  /// Minutes into the run before the first reminder.
  final int firstAfterMin;

  /// Heat raises fluid needs; common in the desert.
  final bool hotDay;
  final List<FuelItem> items;

  double get effectiveFluidPerHour => fluidMlPerHour * (hotDay ? 1.5 : 1);

  FuelItem? item(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// General guidance on carbohydrate per hour by run duration.
  static String guidance(Duration duration) {
    if (duration.inMinutes < 75) return 'Under 75 min: 0–30 g/h is plenty.';
    if (duration.inMinutes <= 150) return '1–2.5 h: aim for 30–60 g/h.';
    return 'Over 2.5 h: 60–90 g/h if your gut is trained for it.';
  }

  FuelPlan copyWith({
    bool? enabled,
    double? carbsPerHour,
    double? fluidMlPerHour,
    int? intervalMin,
    int? firstAfterMin,
    bool? hotDay,
    List<FuelItem>? items,
  }) => FuelPlan(
    enabled: enabled ?? this.enabled,
    carbsPerHour: carbsPerHour ?? this.carbsPerHour,
    fluidMlPerHour: fluidMlPerHour ?? this.fluidMlPerHour,
    intervalMin: intervalMin ?? this.intervalMin,
    firstAfterMin: firstAfterMin ?? this.firstAfterMin,
    hotDay: hotDay ?? this.hotDay,
    items: items ?? this.items,
  );

  Map<String, Object?> toJson() => {
    'on': enabled,
    'cph': carbsPerHour,
    'fph': fluidMlPerHour,
    'int': intervalMin,
    'first': firstAfterMin,
    'hot': hotDay,
    'items': [for (final i in items) i.toJson()],
  };

  static FuelPlan fromJson(Map json) => FuelPlan(
    enabled: json['on'] as bool? ?? true,
    carbsPerHour: (json['cph'] as num?)?.toDouble() ?? 60,
    fluidMlPerHour: (json['fph'] as num?)?.toDouble() ?? 500,
    intervalMin: (json['int'] as num?)?.toInt() ?? 20,
    firstAfterMin: (json['first'] as num?)?.toInt() ?? 30,
    hotDay: json['hot'] as bool? ?? false,
    items: [
      for (final i in (json['items'] as List? ?? const []).cast<Map>())
        FuelItem.fromJson(i),
    ].where((i) => i.name.isNotEmpty).toList().ifEmpty(defaultFuelItems),
  );
}

extension on List<FuelItem> {
  List<FuelItem> ifEmpty(List<FuelItem> fallback) => isEmpty ? fallback : this;
}

/// One logged intake. Nutrition is copied at log time so editing an item
/// later does not rewrite history.
class FuelEntry {
  const FuelEntry({
    required this.time,
    required this.itemId,
    required this.name,
    required this.carbs,
    required this.fluidMl,
    required this.sodiumMg,
  });

  factory FuelEntry.of(FuelItem item, DateTime time) => FuelEntry(
    time: time,
    itemId: item.id,
    name: item.name,
    carbs: item.carbs,
    fluidMl: item.fluidMl,
    sodiumMg: item.sodiumMg,
  );

  final DateTime time;
  final String itemId;
  final String name;
  final double carbs;
  final double fluidMl;
  final double sodiumMg;

  Map<String, Object?> toJson() => {
    't': time.millisecondsSinceEpoch,
    'i': itemId,
    'n': name,
    'c': carbs,
    'f': fluidMl,
    's': sodiumMg,
  };

  static FuelEntry fromJson(Map json) => FuelEntry(
    time: DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
    itemId: json['i'] as String,
    name: json['n'] as String,
    carbs: (json['c'] as num).toDouble(),
    fluidMl: (json['f'] as num).toDouble(),
    sodiumMg: (json['s'] as num).toDouble(),
  );
}

class FuelLog {
  FuelLog([List<FuelEntry>? entries]) : entries = entries ?? [];

  final List<FuelEntry> entries;

  double get carbs => entries.fold(0, (s, e) => s + e.carbs);
  double get fluidMl => entries.fold(0, (s, e) => s + e.fluidMl);
  double get sodiumMg => entries.fold(0, (s, e) => s + e.sodiumMg);
  DateTime? get lastCarbs {
    for (final e in entries.reversed) {
      if (e.carbs > 0) return e.time;
    }
    return null;
  }

  void add(FuelEntry e) => entries.add(e);

  FuelEntry? undo() => entries.isEmpty ? null : entries.removeLast();

  List<Object?> toJson() => [for (final e in entries) e.toJson()];

  static FuelLog fromJson(List json) =>
      FuelLog([for (final e in json.cast<Map>()) FuelEntry.fromJson(e)]);
}

/// A refuelling stop coming up (an aid station or water point).
class UpcomingStop {
  const UpcomingStop(this.name, this.eta);
  final String name;
  final DateTime eta;
}

class FuelReminder {
  const FuelReminder({
    required this.carbs,
    required this.fluidMl,
    required this.suggestion,
    this.stop,
  });

  /// Carbs to take now (g) to get back on plan.
  final double carbs;
  final double fluidMl;

  /// Items and servings that make up [carbs].
  final List<(FuelItem, int)> suggestion;

  /// Set when the reminder was timed for an aid station.
  final String? stop;

  String get title => stop == null ? 'Fuel time' : 'Fuel & refill at $stop';

  String get body {
    final parts = <String>[];
    if (carbs > 0) {
      final what = suggestion.map((s) => '${s.$2} × ${s.$1.name}').join(' + ');
      parts.add('${carbs.round()} g carbs${what.isEmpty ? '' : ' ($what)'}');
    }
    if (fluidMl > 0) parts.add('about ${fluidMl.round()} ml to drink');
    return parts.isEmpty ? 'You are on plan.' : 'Take ${parts.join(' and ')}.';
  }
}

/// Decides when to remind the runner to eat and drink and how much, based
/// on their plan and what they actually logged. Falls behind? The next
/// reminder asks for a bit more, but never more than 1.5× a normal serving
/// (the gut can only absorb so much at once).
class FuelCoach {
  FuelCoach({required this.plan, required this.log, required this.start})
    : _next = start.add(Duration(minutes: plan.firstAfterMin));

  FuelPlan plan;
  final FuelLog log;
  final DateTime start;
  DateTime _next;

  /// When the pending reminder first became due; limits how long it can be
  /// postponed for an aid station.
  DateTime? _dueSince;

  /// When the next reminder is due.
  DateTime get nextAt => _next;

  double _hours(DateTime t) =>
      math.max(0, t.difference(start).inSeconds) / 3600;

  double carbTargetAt(DateTime t) => plan.carbsPerHour * _hours(t);
  double fluidTargetAt(DateTime t) => plan.effectiveFluidPerHour * _hours(t);

  /// Positive when behind plan (g).
  double carbDeficitAt(DateTime t) => carbTargetAt(t) - log.carbs;
  double fluidDeficitAt(DateTime t) => fluidTargetAt(t) - log.fluidMl;

  double get _perInterval => plan.carbsPerHour * plan.intervalMin / 60;
  double get _fluidPerInterval =>
      plan.effectiveFluidPerHour * plan.intervalMin / 60;

  void snooze(DateTime now, Duration by) {
    _next = now.add(by);
    _dueSince = null;
  }

  /// Returns a reminder if one is due at [now]. When an aid station is a
  /// few minutes ahead, the reminder is moved to arrive there instead.
  FuelReminder? due(DateTime now, {UpcomingStop? stop}) {
    if (!plan.enabled || now.isBefore(_next)) return null;
    final interval = Duration(minutes: plan.intervalMin);
    final dueSince = _dueSince ??= now;

    final atStop =
        stop != null &&
        !stop.eta.isBefore(now.subtract(const Duration(minutes: 1))) &&
        stop.eta.difference(now) <= const Duration(minutes: 10);
    // Wait for a stop only if we would reach it within 10 min of the
    // reminder originally falling due.
    final canWait =
        stop != null &&
        stop.eta.difference(dueSince) <= const Duration(minutes: 10);
    if (atStop &&
        canWait &&
        stop.eta.difference(now) > const Duration(minutes: 1)) {
      _next = stop.eta; // fire when arriving at the stop
      return null;
    }
    _next = now.add(interval);
    _dueSince = null;

    final carbs = carbDeficitAt(now).clamp(0.0, _perInterval * 1.5);
    final fluid = fluidDeficitAt(now).clamp(0.0, _fluidPerInterval * 1.5);
    // On plan: stay quiet.
    if (carbs < 5 && fluid < 100) return null;
    return FuelReminder(
      carbs: carbs < 5 ? 0 : carbs,
      fluidMl: fluid < 100 ? 0 : fluid,
      suggestion: carbs < 5 ? const [] : suggest(carbs),
      stop: atStop ? stop.name : null,
    );
  }

  /// Picks servings adding up to about [grams] of carbs: the closest total
  /// (never more than 30% over), preferring fewer servings.
  List<(FuelItem, int)> suggest(double grams) {
    final foods = plan.items.where((i) => i.isFood).toList();
    if (foods.isEmpty || grams < 5) return const [];
    const maxServings = 4;
    List<int>? best;
    var bestScore = double.infinity;
    // Small exhaustive search over multisets of up to 4 servings.
    void search(int from, List<int> picked, double total) {
      if (picked.isNotEmpty && total <= grams * 1.3) {
        final score = (grams - total).abs() + 3.0 * picked.length;
        if (score < bestScore) {
          bestScore = score;
          best = List.of(picked);
        }
      }
      if (picked.length == maxServings) return;
      for (var i = from; i < foods.length; i++) {
        picked.add(i);
        search(i, picked, total + foods[i].carbs);
        picked.removeLast();
      }
    }

    search(0, [], 0);
    // Nothing fits under the cap: the smallest item is the best we can do.
    final chosen =
        best ??
        [foods.indexOf(foods.reduce((a, b) => a.carbs <= b.carbs ? a : b))];
    final counts = <FuelItem, int>{};
    for (final i in chosen) {
      counts[foods[i]] = (counts[foods[i]] ?? 0) + 1;
    }
    final out = [for (final e in counts.entries) (e.key, e.value)]
      ..sort((a, b) => b.$1.carbs.compareTo(a.$1.carbs));
    return out;
  }
}
