import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/fuel.dart';

/// Carb / fluid targets, reminder timing and the runner's own food items.
class FuelPlanScreen extends StatelessWidget {
  const FuelPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Fuel plan')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final plan = settings.fuelPlan;
          void update(FuelPlan p) => settings.fuelPlan = p;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                title: const Text('Fuel & drink reminders'),
                subtitle: const Text(
                  'Buzzes when it is time to eat or drink, with how much.',
                ),
                value: plan.enabled,
                onChanged: (v) => update(plan.copyWith(enabled: v)),
              ),
              _Header('Carbohydrate: ${plan.carbsPerHour.round()} g per hour'),
              Slider(
                value: plan.carbsPerHour,
                min: 0,
                max: 120,
                divisions: 24,
                label: '${plan.carbsPerHour.round()} g/h',
                onChanged: (v) => update(plan.copyWith(carbsPerHour: v)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '${FuelPlan.guidance(const Duration(minutes: 60))}\n'
                  '${FuelPlan.guidance(const Duration(hours: 2))}\n'
                  '${FuelPlan.guidance(const Duration(hours: 4))}\n'
                  'More than 60 g/h works best with mixed sugars '
                  '(glucose + fructose) and a trained gut.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              _Header('Fluids: ${plan.fluidMlPerHour.round()} ml per hour'),
              Slider(
                value: plan.fluidMlPerHour,
                min: 0,
                max: 1000,
                divisions: 20,
                label: '${plan.fluidMlPerHour.round()} ml/h',
                onChanged: (v) => update(plan.copyWith(fluidMlPerHour: v)),
              ),
              SwitchListTile(
                title: const Text('Hot day'),
                subtitle: const Text(
                  'Raises the fluid target by 50%. In desert heat also think '
                  'about salt: roughly 300–600 mg sodium per hour.',
                ),
                value: plan.hotDay,
                onChanged: (v) => update(plan.copyWith(hotDay: v)),
              ),
              ListTile(
                title: const Text('Remind me every'),
                trailing: DropdownButton<int>(
                  value: plan.intervalMin,
                  items: [
                    for (final m in const [15, 20, 25, 30, 45])
                      DropdownMenuItem(value: m, child: Text('$m min')),
                  ],
                  onChanged: (v) {
                    if (v != null) update(plan.copyWith(intervalMin: v));
                  },
                ),
              ),
              ListTile(
                title: const Text('First reminder after'),
                trailing: DropdownButton<int>(
                  value: plan.firstAfterMin,
                  items: [
                    for (final m in const [15, 20, 30, 45, 60])
                      DropdownMenuItem(value: m, child: Text('$m min')),
                  ],
                  onChanged: (v) {
                    if (v != null) update(plan.copyWith(firstAfterMin: v));
                  },
                ),
              ),
              _Header('What you carry'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Check the numbers against the labels: the carb count is only '
                  'as accurate as these values.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final item in plan.items)
                ListTile(
                  leading: Icon(
                    item.isFood ? Icons.bolt : Icons.water_drop,
                    color: item.isFood ? Brand.canyon : Brand.oasis,
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    [
                      '${item.carbs.round()} g carbs',
                      if (item.fluidMl > 0) '${item.fluidMl.round()} ml',
                      if (item.sodiumMg > 0)
                        '${item.sodiumMg.round()} mg sodium',
                    ].join(' · '),
                  ),
                  onTap: () async {
                    final edited = await _editItem(context, item);
                    if (edited == null) return;
                    update(
                      plan.copyWith(
                        items: [
                          for (final i in plan.items)
                            if (i.id == item.id) edited else i,
                        ],
                      ),
                    );
                  },
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: plan.items.length <= 1
                        ? null
                        : () => update(
                            plan.copyWith(
                              items: [
                                for (final i in plan.items)
                                  if (i.id != item.id) i,
                              ],
                            ),
                          ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final created = await _editItem(
                      context,
                      FuelItem(
                        id: 'item${DateTime.now().millisecondsSinceEpoch}',
                        name: '',
                      ),
                    );
                    if (created != null) {
                      update(plan.copyWith(items: [...plan.items, created]));
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add food or drink'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                child: Text(
                  'General guidance for endurance exercise, not medical '
                  'advice. Practise your fuelling in training before race '
                  'day, and adjust for your own needs.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Future<FuelItem?> _editItem(BuildContext context, FuelItem item) {
    return showModalBottomSheet<FuelItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ItemForm(item: item),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _ItemForm extends StatefulWidget {
  const _ItemForm({required this.item});
  final FuelItem item;

  @override
  State<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<_ItemForm> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _carbs = TextEditingController(text: _num(widget.item.carbs));
  late final _fluid = TextEditingController(text: _num(widget.item.fluidMl));
  late final _sodium = TextEditingController(text: _num(widget.item.sodiumMg));

  static String _num(double v) => v == 0 ? '' : v.round().toString();
  static double _parse(TextEditingController c) =>
      double.tryParse(c.text.replaceAll(',', '.')) ?? 0;

  @override
  void dispose() {
    for (final c in [_name, _carbs, _fluid, _sodium]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget number(TextEditingController c, String label) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.item.name.isEmpty,
            decoration: const InputDecoration(
              labelText: 'Name (one serving)',
              hintText: 'e.g. Energy gel, 3 dates, Flask 500 ml',
            ),
          ),
          number(_carbs, 'Carbohydrate per serving (g)'),
          number(_fluid, 'Fluid per serving (ml)'),
          number(_sodium, 'Sodium per serving (mg)'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (_name.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                widget.item.copyWith(
                  name: _name.text.trim(),
                  carbs: _parse(_carbs),
                  fluidMl: _parse(_fluid),
                  sodiumMg: _parse(_sodium),
                ),
              );
            },
            child: const Text('Save'),
          ),
          const SizedBox(height: 4),
          Text(
            'Tip: check the label; "per 100 g" is not "per serving".',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
