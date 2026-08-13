import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// How quickly the app re-locks after being minimized (app scope only).
///
/// [never] preserves the pre-auto-lock behavior: locked only on a cold start.
/// [screenOff] keeps the app unlocked while the screen stays on and re-locks
/// once the screen has turned off during the absence.
enum AutoLockTimeout {
  never('NEVER', null),
  immediately('IMMEDIATELY', Duration.zero),
  s15('S15', Duration(seconds: 15)),
  s30('S30', Duration(seconds: 30)),
  m1('M1', Duration(minutes: 1)),
  m5('M5', Duration(minutes: 5)),
  screenOff('SCREEN_OFF', null);

  const AutoLockTimeout(this.wire, this.delay);

  final String wire;

  /// Background time before a re-lock; null for the non-timed members.
  final Duration? delay;

  static AutoLockTimeout fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => AutoLockTimeout.m1);
}

/// PIN-lock configuration. Custom PINs are stored as a salted SHA-256 hash
/// (never plaintext); Date/Time PINs are derived from the clock and store no
/// secret at all. The retry ladder escalates lockouts on repeated failures.
///
/// No email or other identifier is stored: there is no recovery channel, so
/// collecting one would be PII gathered for nothing. `fromJson` silently drops
/// the legacy `verifiedEmail` key, so older installs need no migration.
class PinConfig extends Equatable {
  const PinConfig({
    this.type = PinType.none,
    this.secretHash = '',
    this.salt = '',
    this.secretLength = 0,
    this.scopes = const {},
    this.retryCount = 0,
    this.lockedUntil,
    this.biometricEnabled = false,
    this.autoLock = AutoLockTimeout.m1,
    this.secureScreen = false,
  });

  factory PinConfig.fromJson(Map<String, dynamic> json) => PinConfig(
    type: PinType.fromWire(json['type'] as String?),
    secretHash: json['secretHash'] as String? ?? '',
    salt: json['salt'] as String? ?? '',
    secretLength: json['secretLength'] as int? ?? 0,
    scopes: ((json['scopes'] as List?)?.cast<String>() ?? const [])
        .map(PinScope.fromWire)
        .toSet(),
    retryCount: json['retryCount'] as int? ?? 0,
    lockedUntil: json['lockedUntil'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['lockedUntil'] as int),
    biometricEnabled: json['biometricEnabled'] as bool? ?? false,
    autoLock: AutoLockTimeout.fromWire(json['autoLock'] as String?),
    secureScreen: json['secureScreen'] as bool? ?? false,
  );

  final PinType type;

  /// Salted SHA-256 hash of a custom PIN; empty for Date/Time/None.
  final String secretHash;

  /// Random salt used to derive [secretHash]; empty for Date/Time/None.
  final String salt;

  /// Digit count of a custom PIN, kept so the lock screen can render the entry
  /// dots and auto-submit without ever holding the secret.
  final int secretLength;

  final Set<PinScope> scopes;
  final int retryCount;
  final DateTime? lockedUntil;
  final bool biometricEnabled;

  /// How quickly the app re-locks after being minimized (app scope only).
  final AutoLockTimeout autoLock;

  /// FLAG_SECURE: hide the screen in Recents and block screenshots.
  final bool secureScreen;

  bool get isConfigured => type != PinType.none;
  bool get isLockedOut =>
      lockedUntil != null && lockedUntil!.isAfter(DateTime.now());

  bool guards(PinScope scope) => scopes.contains(scope);

  PinConfig copyWith({
    PinType? type,
    String? secretHash,
    String? salt,
    int? secretLength,
    Set<PinScope>? scopes,
    int? retryCount,
    DateTime? lockedUntil,
    bool clearLockout = false,
    bool? biometricEnabled,
    AutoLockTimeout? autoLock,
    bool? secureScreen,
  }) => PinConfig(
    type: type ?? this.type,
    secretHash: secretHash ?? this.secretHash,
    salt: salt ?? this.salt,
    secretLength: secretLength ?? this.secretLength,
    scopes: scopes ?? this.scopes,
    retryCount: retryCount ?? this.retryCount,
    lockedUntil: clearLockout ? null : (lockedUntil ?? this.lockedUntil),
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    autoLock: autoLock ?? this.autoLock,
    secureScreen: secureScreen ?? this.secureScreen,
  );

  Map<String, dynamic> toJson() => {
    'type': type.wire,
    'secretHash': secretHash,
    'salt': salt,
    'secretLength': secretLength,
    'scopes': scopes.map((e) => e.wire).toList(),
    'retryCount': retryCount,
    'lockedUntil': lockedUntil?.millisecondsSinceEpoch,
    'biometricEnabled': biometricEnabled,
    'autoLock': autoLock.wire,
    'secureScreen': secureScreen,
  };

  @override
  List<Object?> get props => [
    type,
    secretHash,
    salt,
    secretLength,
    scopes,
    retryCount,
    lockedUntil,
    biometricEnabled,
    autoLock,
    secureScreen,
  ];
}

/// Decides whether the app must re-lock on resume, given when it was paused
/// and (for [AutoLockTimeout.screenOff]) when the screen last turned off.
abstract final class AutoLockPolicy {
  /// [lastScreenOffMillis] is the native `ACTION_SCREEN_OFF` wall-clock stamp
  /// (0 = never seen); only consulted for [AutoLockTimeout.screenOff].
  static bool shouldRelock({
    required PinConfig config,
    required DateTime? pausedAt,
    required DateTime now,
    int lastScreenOffMillis = 0,
  }) {
    if (!config.isConfigured || !config.guards(PinScope.app)) return false;
    if (pausedAt == null) return false;
    return switch (config.autoLock) {
      AutoLockTimeout.never => false,
      AutoLockTimeout.screenOff =>
        lastScreenOffMillis >= pausedAt.millisecondsSinceEpoch,
      _ => now.difference(pausedAt) >= config.autoLock.delay!,
    };
  }
}

/// The escalating lockout ladder (verified thresholds from the reference app).
abstract final class PinLockoutPolicy {
  /// Returns the lockout duration for a given (post-increment) retry count, or
  /// null for "no lockout".
  static Duration? lockoutFor(int retryCount) {
    if (retryCount <= 5) return null;
    if (retryCount <= 8) return const Duration(seconds: 30);
    if (retryCount <= 10) return const Duration(minutes: 5);
    if (retryCount <= 15) return const Duration(hours: 1);
    if (retryCount <= 20) return const Duration(hours: 4);
    return const Duration(hours: 24);
  }
}
