import 'dart:convert';

import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/domain/pin_hasher.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';

/// PIN persistence in secure storage.
///
/// There is no recovery channel by design. With no backend, the only "recovery"
/// that could exist would be a client-side code — which is a bypass of the lock,
/// not a recovery of it. The escape hatch is reinstalling the app, which clears
/// secure storage along with everything else.
class PinRepositoryImpl implements PinRepository {
  PinRepositoryImpl(this._store, this._channel);

  final LocalStore _store;
  final EngineChannel _channel;

  @override
  Future<PinConfig> load() async {
    // A throw here (secure storage failing to decrypt after a Keystore
    // invalidation / backup restore, or a corrupted blob hitting jsonDecode)
    // would otherwise reject the splash's Future.wait and strand the app on
    // the spinner forever. Fail open to the default config: an unreadable
    // lock is equivalent to the documented reinstall escape hatch.
    try {
      final raw = await _store.readSecret(StoreKeys.pinConfig);
      if (raw == null) return const PinConfig();
      final json = jsonDecode(raw) as Map<String, dynamic>;

      // Migrate legacy installs that stored a plaintext custom PIN under
      // `secret` (pre-hashing): hash it, persist, and drop the plaintext so it
      // never sits unhashed again.
      final legacySecret = json['secret'] as String?;
      final hasHash = (json['secretHash'] as String?)?.isNotEmpty ?? false;
      final isCustom =
          PinType.fromWire(json['type'] as String?) == PinType.custom;
      if (isCustom &&
          !hasHash &&
          legacySecret != null &&
          legacySecret.isNotEmpty) {
        final salt = PinHasher.newSalt();
        final migrated = PinConfig.fromJson(json).copyWith(
          secretHash: PinHasher.hash(salt, legacySecret),
          salt: salt,
          secretLength: legacySecret.length,
        );
        await save(migrated);
        return migrated;
      }

      return PinConfig.fromJson(json);
    } catch (e) {
      // Broad on purpose: bad casts throw TypeError (an Error, not Exception).
      AppLogger.e('pin config unreadable — resetting to defaults', e);
      return const PinConfig();
    }
  }

  @override
  Future<void> save(PinConfig config) async {
    await _store.writeSecret(StoreKeys.pinConfig, jsonEncode(config.toJson()));
  }

  @override
  Future<void> setSecureScreen({required bool enabled}) =>
      _channel.setSecureScreen(enabled: enabled);

  @override
  Future<int> lastScreenOffMillis() => _channel.lastScreenOff();

  @override
  Future<({int elapsedMs, int bootCount})?> monotonicNow() =>
      _channel.monotonicNow();
}
