import 'package:intl/intl.dart';

// Locale pinned to en_US to mirror native DateKeys' Locale.US — a localized
// default (e.g. Arabic-Indic digits) must never change the persisted key.
final DateFormat _dayFormat = DateFormat('dd-MM-yyyy', 'en_US');

/// Device-local day signature, e.g. "07-06-2026" — the single Dart definition
/// of the day key. Must always agree with the native engine's `DateKeys`
/// format ("dd-MM-yyyy"), or day-scoped counters drift at midnight.
String daySignature(DateTime day) => _dayFormat.format(day);

/// Local midnight of the day before [day] — the one definition of "yesterday"
/// for every day-keyed record (the insights cubit and store each used to roll
/// their own, which agree until one of them is edited).
DateTime previousDay(DateTime day) =>
    DateTime(day.year, day.month, day.day - 1);
