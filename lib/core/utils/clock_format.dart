import 'package:flutter/material.dart';

/// Minutes after midnight rendered in the DEVICE's 12/24-hour preference.
///
/// `showTimePicker` already honours that preference, so anything that displays
/// a picked time has to as well — otherwise a user picks "5:00 PM" and the app
/// reads it back as "17:00". Storage and the wire keep the 24-hour form
/// (`RuleSchedule.formatHHmm`); this is display only.
String formatLocalTime(BuildContext context, int minutesAfterMidnight) =>
    TimeOfDay(
      hour: minutesAfterMidnight ~/ 60,
      minute: minutesAfterMidnight % 60,
    ).format(context);

/// Curried form, for the `TimeFormat` callbacks the rule summaries take.
String Function(int) localTimeFormat(BuildContext context) =>
    (m) => formatLocalTime(context, m);
