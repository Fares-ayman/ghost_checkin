import 'package:flutter/material.dart';

import 'format.dart';

/// Shown when the check-in was detected late and motion suggests the real
/// arrival time: one tap opens the request to the manager, already filled in.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.recorded,
    required this.estimated,
    required this.onSend,
  });

  final DateTime recorded;
  final DateTime estimated;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      color: scheme.tertiaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.directions_car_outlined,
                    color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You probably arrived at ${formatTime(estimated)}',
                    style: text.titleMedium
                        ?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Your check-in was recorded at ${formatTime(recorded)} because '
              'Location was off. Motion shows you got out of a vehicle at '
              '${formatTime(estimated)}.',
              style: text.bodyMedium
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onSend,
              icon: const Icon(Icons.send_outlined),
              label: Text('Send ${formatTime(estimated)} to my manager'),
            ),
          ],
        ),
      ),
    );
  }
}
