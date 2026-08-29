import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';

/// The Dart side of the block screen: its style (native is the single source
/// of truth) and the editor's "Try it" preview. The wall itself is raised
/// natively at the moment of a block — nothing here is on that path.
abstract interface class BlockScreenRepository {
  /// The persisted style; defaults when nothing was ever saved.
  Future<BlockScreenStyle> style();

  Future<void> setStyle(BlockScreenStyle style);

  /// Raises the real wall with [payload] as a preview. False when the wall is
  /// switched off, the overlay grant is missing, or there is no native side.
  Future<bool> preview(BlockScreenPayload payload);

  Future<void> hide();
}
