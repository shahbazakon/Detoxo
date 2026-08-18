import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';

/// Curated catalog of commonly sensitive apps, keyed by Play Store package id
/// (never by display name — names change, package ids don't). India-weighted:
/// major banks, UPI apps and government identity apps, plus the global password
/// managers and authenticators.
///
/// Every catalog app is protected automatically and permanently: the full
/// catalog is always pushed to the engine (installed or not), so one installed
/// later is covered instantly. Users can't disable or remove catalog entries —
/// they can only add (and delete) apps of their own.
abstract final class ProtectedAppCatalog {
  static const List<ProtectedApp> apps = [
    // ── Banking ─────────────────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.sbi.lotusintouch',
      appName: 'YONO SBI',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.snapwork.hdfc',
      appName: 'HDFC Bank',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.csam.icici.bank.imobile',
      appName: 'iMobile Pay',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.axis.mobile',
      appName: 'Axis Mobile',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.msf.kbank.mobile',
      appName: 'Kotak811',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.bankofbaroda.mconnect',
      appName: 'BOB World',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),
    // PNB One's real applicationId — looks like a placeholder but isn't.
    ProtectedApp(
      packageName: 'com.Version1',
      appName: 'PNB One',
      category: ProtectedAppCategory.banking,
      source: ProtectedAppSource.catalog,
    ),

    // ── Payments / UPI ──────────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.google.android.apps.nbu.paisa.user',
      appName: 'Google Pay',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.phonepe.app',
      appName: 'PhonePe',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'net.one97.paytm',
      appName: 'Paytm',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'in.org.npci.upiapp',
      appName: 'BHIM',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.dreamplug.androidapp',
      appName: 'CRED',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.mobikwik_new',
      appName: 'MobiKwik',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.freecharge.android',
      appName: 'Freecharge',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.paypal.android.p2pmobile',
      appName: 'PayPal',
      category: ProtectedAppCategory.payments,
      source: ProtectedAppSource.catalog,
    ),

    // ── Government / Identity ───────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.digilocker.android',
      appName: 'DigiLocker',
      category: ProtectedAppCategory.government,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'in.gov.umang.negd.g2c',
      appName: 'UMANG',
      category: ProtectedAppCategory.government,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'in.gov.uidai.mAadhaarPlus',
      appName: 'mAadhaar',
      category: ProtectedAppCategory.identity,
      source: ProtectedAppSource.catalog,
    ),

    // ── Password managers ───────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.x8bit.bitwarden',
      appName: 'Bitwarden',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.onepassword.android',
      appName: '1Password',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.lastpass.lpandroid',
      appName: 'LastPass',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.callpod.android_apps.keeper',
      appName: 'Keeper',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'proton.android.pass',
      appName: 'Proton Pass',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.dashlane',
      appName: 'Dashlane',
      category: ProtectedAppCategory.passwordManager,
      source: ProtectedAppSource.catalog,
    ),

    // ── Authenticators ──────────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.google.android.apps.authenticator2',
      appName: 'Google Authenticator',
      category: ProtectedAppCategory.authentication,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.azure.authenticator',
      appName: 'Microsoft Authenticator',
      category: ProtectedAppCategory.authentication,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.authy.authy',
      appName: 'Authy',
      category: ProtectedAppCategory.authentication,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.duosecurity.duomobile',
      appName: 'Duo Mobile',
      category: ProtectedAppCategory.authentication,
      source: ProtectedAppSource.catalog,
    ),

    // ── Healthcare ──────────────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'in.ndhm.phr',
      appName: 'ABHA',
      category: ProtectedAppCategory.healthcare,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.aranoah.healthkart.plus',
      appName: 'Tata 1mg',
      category: ProtectedAppCategory.healthcare,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.practo.fabric',
      appName: 'Practo',
      category: ProtectedAppCategory.healthcare,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.phonegap.rxpal',
      appName: 'PharmEasy',
      category: ProtectedAppCategory.healthcare,
      source: ProtectedAppSource.catalog,
    ),

    // ── Investment / trading ────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.zerodha.kite3',
      appName: 'Kite by Zerodha',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.nextbillion.groww',
      appName: 'Groww',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'in.upstox.pro',
      appName: 'Upstox',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.msf.angelmobile',
      appName: 'Angel One',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'in.indwealth',
      appName: 'INDmoney',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),
    ProtectedApp(
      packageName: 'com.paytmmoney',
      appName: 'Paytm Money',
      category: ProtectedAppCategory.investment,
      source: ProtectedAppSource.catalog,
    ),

    // ── Insurance ───────────────────────────────────────────────────────────
    ProtectedApp(
      packageName: 'com.policybazaar',
      appName: 'PolicyBazaar',
      category: ProtectedAppCategory.insurance,
      source: ProtectedAppSource.catalog,
    ),
  ];

  /// The catalog entry for [packageName], or null when unknown.
  static ProtectedApp? byPackage(String packageName) {
    for (final app in apps) {
      if (app.packageName == packageName) return app;
    }
    return null;
  }
}
