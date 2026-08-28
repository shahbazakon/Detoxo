import 'package:detoxo/core/design_system/design_system.dart';
import 'package:flutter/material.dart';

/// A compact 1–5 star rating row. Tapping the current rating again clears it
/// back to 0 (unrated), so a rating is always optional.
class FeedbackRatingSelector extends StatelessWidget {
  const FeedbackRatingSelector({
    required this.rating,
    required this.onChanged,
    super.key,
  });

  /// Current rating, 0 (unrated) to 5.
  final int rating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var star = 1; star <= 5; star++)
          IconButton(
            padding: EdgeInsets.zero,
            // 48dp targets + a label per star: icon-only controls are
            // otherwise invisible to TalkBack and hard to hit.
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: star == rating ? 'Clear rating' : 'Rate $star of 5 stars',
            isSelected: star <= rating,
            onPressed: () => onChanged(star == rating ? 0 : star),
            icon: Icon(
              star <= rating ? Icons.star_rounded : Icons.star_border_rounded,
              color: star <= rating
                  ? AppColors.warning
                  : context.glass.onGlassMuted,
              size: 24,
            ),
          ),
      ],
    );
  }
}
