import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/engine_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

void main() {
  // EVO-013: "running" requires the service INSTANCE alive, not just the
  // Settings.Secure string — some OEMs kill the service on force-stop while
  // the setting keeps listing it.
  group('EngineRepositoryImpl.currentStatus', () {
    late _MockChannel channel;

    setUp(() {
      channel = _MockChannel();
      when(
        () => channel.blockStats(),
      ).thenAnswer((_) async => {'today': 1, 'total': 2});
    });

    test('enabled but dead service reports stopped', () async {
      when(
        () => channel.isAccessibilityEnabled(),
      ).thenAnswer((_) async => true);
      when(() => channel.serviceAlive()).thenAnswer((_) async => false);
      final snap = await EngineRepositoryImpl(channel).currentStatus();
      expect(snap.status, ServiceStatus.stopped);
    });

    test('enabled and alive reports running with counters', () async {
      when(
        () => channel.isAccessibilityEnabled(),
      ).thenAnswer((_) async => true);
      when(() => channel.serviceAlive()).thenAnswer((_) async => true);
      final snap = await EngineRepositoryImpl(channel).currentStatus();
      expect(snap.status, ServiceStatus.running);
      expect(snap.blocksToday, 1);
      expect(snap.blocksTotal, 2);
    });

    test('not enabled short-circuits without the alive call', () async {
      when(
        () => channel.isAccessibilityEnabled(),
      ).thenAnswer((_) async => false);
      final snap = await EngineRepositoryImpl(channel).currentStatus();
      expect(snap.status, ServiceStatus.stopped);
      verifyNever(() => channel.serviceAlive());
    });
  });
}
