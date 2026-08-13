// access_protection feature — public domain (entities + repository contracts)
// plus the requirePin action gate, the sanctioned way for other features to
// demand a PIN before a sensitive action.
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
export 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
export 'package:detoxo/features/access_protection/presentation/pin_gate.dart';
