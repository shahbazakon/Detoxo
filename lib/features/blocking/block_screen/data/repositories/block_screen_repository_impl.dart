import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
import 'package:detoxo/features/blocking/block_screen/domain/repositories/block_screen_repository.dart';

/// Over the command channel: `blockScreenStyle` hydrates (native hands back
/// the parsed map, `{}` when unset), `setBlockScreenStyle` persists and
/// live-rebuilds a showing wall, `showBlockScreen` / `hideBlockScreen` drive
/// the editor's preview.
class BlockScreenRepositoryImpl implements BlockScreenRepository {
  BlockScreenRepositoryImpl(this._channel);

  final EngineChannel _channel;

  @override
  Future<BlockScreenStyle> style() async =>
      BlockScreenStyle.fromWire(await _channel.blockScreenStyle());

  @override
  Future<void> setStyle(BlockScreenStyle style) =>
      _channel.setBlockScreenStyle(style.toWire());

  @override
  Future<bool> preview(BlockScreenPayload payload) =>
      _channel.showBlockScreen(payload.sanitised().toWire());

  @override
  Future<void> hide() => _channel.hideBlockScreen();
}
