import 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_entry.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';

/// Persists the per-target temporary unblocks (M8).
abstract interface class TemporaryUnblockRepository {
  /// Throws on a corrupt store — the sync must abort rather than push an empty
  /// array, which native honours as an intentional clear (and would silently
  /// re-block a target the user is mid-way through using).
  Future<List<TemporaryUnblock>> load();

  Future<void> save(List<TemporaryUnblock> grants);
}

/// The whole `bypass_ledger` document: the knobs plus every spent escape.
class BypassLedger {
  const BypassLedger({
    this.config = BypassConfig.defaults,
    this.entries = const [],
  });

  final BypassConfig config;

  /// Newest first, capped at [maxBypassEntries].
  final List<BypassEntry> entries;
}

/// Persists the rationed-escape ledger (M8 writes `OVERRIDE`; M2.2 will add
/// `EMERGENCY` to the same store).
abstract interface class BypassLedgerRepository {
  /// Throws on a corrupt store, like every other repository here: a quota that
  /// silently reads as empty is a quota that grants free overrides.
  Future<BypassLedger> load();

  Future<void> save(BypassLedger ledger);
}
