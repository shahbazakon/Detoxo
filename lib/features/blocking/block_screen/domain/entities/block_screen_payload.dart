import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// What kind of target the wall was raised for.
enum BlockReferenceType {
  reel('REEL'),
  app('APP'),
  website('WEBSITE');

  const BlockReferenceType(this.wire);

  final String wire;

  static BlockReferenceType fromWire(String? v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => BlockReferenceType.reel,
  );
}

/// Why the wall was raised. `dailyLimit` / `schedule` come from the rules
/// engine; a `dailyLimit` wall is forced on native regardless of block mode
/// or the Appearance switch.
enum BlockReason {
  plan('PLAN'),
  appBlock('APP_BLOCK'),
  webRule('WEB_RULE'),
  adult('ADULT'),
  dailyLimit('DAILY_LIMIT'),
  schedule('SCHEDULE');

  const BlockReason(this.wire);

  final String wire;

  static BlockReason fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => BlockReason.plan);
}

/// The block screen's wire payload — what native raises at a block, and what
/// the editor's "Try it" sends over `showBlockScreen`. Mirrors the Kotlin
/// `BlockScreenPayload` field for field; -1 means "not applicable, print
/// nothing", never 0.
class BlockScreenPayload extends Equatable {
  const BlockScreenPayload({
    required this.referenceType,
    required this.referenceId,
    required this.displayName,
    required this.blockReason,
    this.appLabel = '',
    this.packageName = '',
    this.plan,
    this.allowance = 1,
    this.todayCount = -1,
    this.allowanceLeft = -1,
    this.bankMs = -1,
    this.opensToday = -1,
    this.offersOpenApp = true,
    this.offersUnblock = false,
  });

  /// A representative reel block for the style editor and the Appearance hub.
  /// A zero [todayCount] renders the sample 12 so the count line is always
  /// demonstrable (the counter cards use the same rule).
  factory BlockScreenPayload.preview({
    BlockingPlan plan = BlockingPlan.blockAll,
    int allowance = 1,
    int todayCount = 12,
  }) => BlockScreenPayload(
    referenceType: BlockReferenceType.reel,
    referenceId: 'ig_reel',
    displayName: 'Instagram Reels',
    appLabel: 'Instagram',
    packageName: 'com.instagram.android',
    blockReason: BlockReason.plan,
    plan: plan,
    allowance: allowance,
    todayCount: todayCount > 0 ? todayCount : 12,
    allowanceLeft: plan == BlockingPlan.oneReel ? 0 : -1,
    bankMs: plan == BlockingPlan.curious ? 0 : -1,
    opensToday: 7,
  );

  /// Tolerant: a wrong-typed field takes its default rather than throwing,
  /// so a drifted native payload can never break the editor.
  factory BlockScreenPayload.fromWire(Map<String, dynamic>? m) {
    if (m == null) return BlockScreenPayload.preview();
    final planWire = _str(m['plan']);
    return BlockScreenPayload(
      referenceType: BlockReferenceType.fromWire(_str(m['referenceType'])),
      referenceId: _str(m['referenceId']),
      displayName: _str(m['displayName']),
      appLabel: _str(m['appLabel']),
      packageName: _str(m['packageName']),
      blockReason: BlockReason.fromWire(_str(m['blockReason'])),
      plan: planWire.isEmpty ? null : BlockingPlan.fromWire(planWire),
      allowance: _int(m['allowance'], 1),
      todayCount: _int(m['todayCount'], -1),
      allowanceLeft: _int(m['allowanceLeft'], -1),
      bankMs: _int(m['bankMs'], -1),
      opensToday: _int(m['opensToday'], -1),
      offersOpenApp: _bool(m['offersOpenApp'], true),
      offersUnblock: _bool(m['offersUnblock'], false),
    );
  }

  final BlockReferenceType referenceType;

  /// Platform id, package name or host — the M8 unblock target.
  final String referenceId;

  /// "Instagram Reels", the app's label, or the host. Empty for adult hits.
  final String displayName;

  /// The app under the wall, for "Back to Instagram" / "Back to Chrome".
  final String appLabel;

  /// The app under the wall, for the usage layer's opens count (EVO-027).
  final String packageName;
  final BlockReason blockReason;

  /// The plan that blocked, or null when no plan chip should render (app /
  /// web / adult rules fire regardless of plan).
  final BlockingPlan? plan;

  /// The armed One Reel / Unblock count — decides "One Reel" vs "Unblock".
  final int allowance;
  final int todayCount;
  final int allowanceLeft;
  final int bankMs;

  /// Foreground transitions into [packageName] since local midnight; -1 =
  /// unknown (native fills it late from `UsageStatsManager`).
  final int opensToday;
  final bool offersOpenApp;
  final bool offersUnblock;

  bool get isAdult => blockReason == BlockReason.adult;

  /// EVO-018: an adult hit is never named and never one tap from being lifted;
  /// a plan chip belongs only to a plan block. Native applies the same rules.
  BlockScreenPayload sanitised() {
    var p = this;
    if (p.isAdult) {
      p = p.copyWith(displayName: '', referenceId: '', offersUnblock: false);
    }
    if (p.blockReason != BlockReason.plan) p = p.copyWith(clearPlan: true);
    return p;
  }

  BlockScreenPayload copyWith({
    BlockReferenceType? referenceType,
    String? referenceId,
    String? displayName,
    String? appLabel,
    String? packageName,
    BlockReason? blockReason,
    BlockingPlan? plan,
    bool clearPlan = false,
    int? allowance,
    int? todayCount,
    int? allowanceLeft,
    int? bankMs,
    int? opensToday,
    bool? offersOpenApp,
    bool? offersUnblock,
  }) => BlockScreenPayload(
    referenceType: referenceType ?? this.referenceType,
    referenceId: referenceId ?? this.referenceId,
    displayName: displayName ?? this.displayName,
    appLabel: appLabel ?? this.appLabel,
    packageName: packageName ?? this.packageName,
    blockReason: blockReason ?? this.blockReason,
    plan: clearPlan ? null : (plan ?? this.plan),
    allowance: allowance ?? this.allowance,
    todayCount: todayCount ?? this.todayCount,
    allowanceLeft: allowanceLeft ?? this.allowanceLeft,
    bankMs: bankMs ?? this.bankMs,
    opensToday: opensToday ?? this.opensToday,
    offersOpenApp: offersOpenApp ?? this.offersOpenApp,
    offersUnblock: offersUnblock ?? this.offersUnblock,
  );

  Map<String, dynamic> toWire() => {
    'referenceType': referenceType.wire,
    'referenceId': referenceId,
    'displayName': displayName,
    'appLabel': appLabel,
    'packageName': packageName,
    'blockReason': blockReason.wire,
    'plan': plan?.wire ?? '',
    'allowance': allowance,
    'todayCount': todayCount,
    'allowanceLeft': allowanceLeft,
    'bankMs': bankMs,
    'opensToday': opensToday,
    'offersOpenApp': offersOpenApp,
    'offersUnblock': offersUnblock,
  };

  @override
  List<Object?> get props => [
    referenceType,
    referenceId,
    displayName,
    appLabel,
    packageName,
    blockReason,
    plan,
    allowance,
    todayCount,
    allowanceLeft,
    bankMs,
    opensToday,
    offersOpenApp,
    offersUnblock,
  ];
}

String _str(Object? v) => v is String ? v : '';
int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;
