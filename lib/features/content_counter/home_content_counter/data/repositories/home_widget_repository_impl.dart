import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart';

/// Home-widget control over the single command channel. `pinContentWidget`
/// answers truthfully (false when the launcher can't pin), `refreshContentWidget`
/// re-renders every pinned instance from the native store. Off-Android the
/// channel short-circuits to false / no-op.
class HomeWidgetRepositoryImpl implements HomeWidgetRepository {
  HomeWidgetRepositoryImpl(this._channel);

  final EngineChannel _channel;

  @override
  Future<bool> pin() => _channel.pinContentWidget();

  @override
  Future<void> refresh() => _channel.refreshContentWidget();
}
