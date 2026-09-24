import 'package:flutter/material.dart';

import '../brand.dart';
import '../core/course.dart';
import '../core/geo.dart';
import 'group_sheet.dart' show clock;

/// "Choose your distance" for events with several courses. Returns the
/// chosen course id.
Future<String?> pickCourse(
  BuildContext context,
  List<Course> courses, {
  String? current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text(
              'Choose your distance',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              'You get that route, its checkpoints and cut-offs. You can '
              'change it later from the menu.',
            ),
            const SizedBox(height: 12),
            for (final c in courses)
              _CourseCard(
                course: c,
                selected: c.id == current,
                onTap: () => Navigator.pop(context, c.id),
              ),
          ],
        ),
      ),
    ),
  );
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({
    required this.course,
    required this.selected,
    required this.onTap,
  });

  final Course course;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cutoffs = course.checkpoints.where((c) => c.cutoff != null).length;
    final facts = [
      formatDistance(course.route.length),
      'D+ ${course.route.totalAscent.round()} m',
      if (course.checkpoints.isNotEmpty)
        '${course.checkpoints.length} checkpoints',
      if (cutoffs > 0) '$cutoffs cut-offs',
      if (course.start != null) 'start ${clock(course.start!)}',
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Brand.canyon, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Brand.canyon,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  (course.route.length / 1000).round().toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      course.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(facts.join(' · ')),
                  ],
                ),
              ),
              if (selected) const Icon(Icons.check_circle, color: Brand.canyon),
            ],
          ),
        ),
      ),
    );
  }
}
