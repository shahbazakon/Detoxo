import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/sessions.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('enum wire mapping', () {
    test('BlockingPlan round-trips and falls back', () {
      expect(BlockingPlan.fromWire('CURIOUS'), BlockingPlan.curious);
      expect(BlockingPlan.fromWire('nonsense'), BlockingPlan.blockAll);
    });

    test('BlockingMode falls back to pressBack', () {
      expect(BlockingMode.fromWire('KILL_APP'), BlockingMode.killApp);
      expect(BlockingMode.fromWire('BLOCK_SCREEN'), BlockingMode.blockScreen);
      expect(BlockingMode.fromWire(null), BlockingMode.pressBack);
    });
  });

  group('PauseSession phase math', () {
    final start = DateTime(2026, 1, 1, 10);
    const session = Duration(minutes: 5);
    const cooldown = Duration(minutes: 5);
    final pause = PauseSession(
      startedAt: start,
      pauseDuration: session,
      cooldownDuration: cooldown,
      planToResume: BlockingPlan.blockAll,
    );

    test('active during pause window', () {
      expect(
        pause.phaseAt(start.add(const Duration(minutes: 2))),
        SessionPhase.active,
      );
    });
    test('cooldown after pause window', () {
      expect(
        pause.phaseAt(start.add(const Duration(minutes: 7))),
        SessionPhase.cooldown,
      );
    });
    test('idle after cooldown', () {
      expect(
        pause.phaseAt(start.add(const Duration(minutes: 11))),
        SessionPhase.idle,
      );
    });
  });

  group('PIN lockout ladder', () {
    test('no lockout for first attempts', () {
      expect(PinLockoutPolicy.lockoutFor(3), isNull);
    });
    test('escalates with retries', () {
      expect(PinLockoutPolicy.lockoutFor(7), const Duration(seconds: 30));
      expect(PinLockoutPolicy.lockoutFor(21), const Duration(hours: 24));
    });
  });

  group('AppSettings.themeMode', () {
    test('defaults to dark and round-trips through JSON', () {
      const settings = AppSettings();
      expect(settings.themeMode, AppThemeMode.dark);

      final json = settings.copyWith(themeMode: AppThemeMode.system).toJson();
      expect(json['themeMode'], 'SYSTEM');
      expect(AppSettings.fromJson(json).themeMode, AppThemeMode.system);
    });

    test('fromJson falls back to dark for unknown/missing values', () {
      expect(AppSettings.fromJson(const {}).themeMode, AppThemeMode.dark);
      expect(
        AppSettings.fromJson(const {'themeMode': 'nonsense'}).themeMode,
        AppThemeMode.dark,
      );
    });
  });

  group('DailyLimit reset', () {
    test('resets consumed on a new day', () {
      const limit = DailyLimit(
        limit: Duration(minutes: 30),
        consumed: Duration(minutes: 12),
        dateSignature: '01-01-2026',
      );
      final next = limit.refreshed('02-01-2026');
      expect(next.consumed, Duration.zero);
      expect(next.limit, const Duration(minutes: 30));
    });
  });
}
