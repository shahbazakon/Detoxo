import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/domain/repositories/bubble_repository.dart';

/// Bubble control surface. Reuses the existing overlay-permission channel
/// methods (`canDrawOverlays` / `requestOverlayPermission`) and toggles the
/// native bubble flag; no new permission plumbing.
class BubbleRepositoryImpl implements BubbleRepository {
  BubbleRepositoryImpl(this._channel);

  final EngineChannel _channel;

  @override
  Future<bool?> canShow() =>
      _channel.invokeBoolOrNull(ChannelMethods.canDrawOverlays);

  @override
  Future<void> requestPermission() => _channel.requestOverlay();

  @override
  Future<void> setEnabled({required bool enabled}) =>
      _channel.setContentBubbleEnabled(enabled: enabled);
}
