// Billing Schedule Service
// Persists per-customer billing frequency + anchor month so the audit can
// suppress "dormant" non-monthly customers on off-billing months.
//
// Logic:
//   • Monthly  — always active (no anchor needed)
//   • Quarterly  — active on anchor month, anchor+3, anchor+6, anchor+9
//   • Semi-Annual — active on anchor month, anchor+6
//   • Annual     — active on anchor month only (every 12 months)
//
// "Active" means today falls within the 7-day window AFTER the 1st of a
// billing month (i.e. date is between the 1st and the 7th inclusive).

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum BillingFrequency { monthly, quarterly, semiAnnual, annual }

extension BillingFrequencyLabel on BillingFrequency {
  String get label {
    switch (this) {
      case BillingFrequency.monthly:    return 'Monthly';
      case BillingFrequency.quarterly:  return 'Quarterly';
      case BillingFrequency.semiAnnual: return 'Semi-Annual';
      case BillingFrequency.annual:     return 'Annual';
    }
  }

  String get shortLabel {
    switch (this) {
      case BillingFrequency.monthly:    return 'Monthly';
      case BillingFrequency.quarterly:  return 'Quarterly';
      case BillingFrequency.semiAnnual: return 'Semi-Annual';
      case BillingFrequency.annual:     return 'Annual';
    }
  }

  int get intervalMonths {
    switch (this) {
      case BillingFrequency.monthly:    return 1;
      case BillingFrequency.quarterly:  return 3;
      case BillingFrequency.semiAnnual: return 6;
      case BillingFrequency.annual:     return 12;
    }
  }

  String toJson() => name;

  static BillingFrequency fromJson(String s) {
    return BillingFrequency.values.firstWhere(
      (e) => e.name == s,
      orElse: () => BillingFrequency.monthly,
    );
  }
}

class BillingSchedule {
  /// Billing cadence.
  final BillingFrequency frequency;

  /// Anchor month (1–12): the first month this customer was billed on the
  /// non-monthly schedule.  Ignored for monthly customers.
  final int anchorMonth; // 1 = Jan … 12 = Dec

  const BillingSchedule({
    this.frequency = BillingFrequency.monthly,
    this.anchorMonth = 1,
  });

  bool get isMonthly => frequency == BillingFrequency.monthly;

  /// Returns true when today falls within the 7-day audit window for this
  /// customer (i.e. today is between the 1st and the 7th of a billing month).
  bool get isActiveWindow {
    if (isMonthly) return true;
    final now = DateTime.now();
    // Only the first 7 days of a month can ever be in the window.
    if (now.day > 7) return false;
    // Check whether this month is a billing month for this customer.
    return isBillingMonth(now.month);
  }

  /// Returns true when the customer is dormant (non-monthly AND outside their
  /// billing window) — i.e. they should be suppressed in the audit list.
  bool get isDormant => !isMonthly && !isActiveWindow;

  /// Computes the next billing date from today (for display purposes).
  DateTime get nextBillingDate {
    if (isMonthly) return DateTime(DateTime.now().year, DateTime.now().month, 1);
    final now = DateTime.now();
    // Walk forward month by month until we find a billing month.
    for (int offset = 0; offset <= 12; offset++) {
      final candidate = DateTime(now.year, now.month + offset, 1);
      if (isBillingMonth(candidate.month)) {
        // If we're in the billing month but already past the 7-day window,
        // skip to the next cycle.
        if (offset == 0 && now.day > 7) continue;
        return candidate;
      }
    }
    // Fallback (shouldn't be reached)
    return DateTime(now.year, now.month + frequency.intervalMonths, 1);
  }

  bool isBillingMonth(int month) {
    final interval = frequency.intervalMonths;
    // Calculate offset from anchor month, normalised to 0–(interval-1)
    final diff = ((month - anchorMonth) % 12 + 12) % 12;
    return diff % interval == 0;
  }

  Map<String, dynamic> toJson() => {
    'frequency': frequency.toJson(),
    'anchorMonth': anchorMonth,
  };

  factory BillingSchedule.fromJson(Map<String, dynamic> json) {
    return BillingSchedule(
      frequency: BillingFrequencyLabel.fromJson(json['frequency'] as String? ?? 'monthly'),
      anchorMonth: (json['anchorMonth'] as int?) ?? 1,
    );
  }
}

/// Persists billing schedules keyed by lowercased customer name.
class BillingScheduleService {
  static const _kKey = 'billing_schedules_v1';

  /// Load all saved schedules from SharedPreferences.
  static Future<Map<String, BillingSchedule>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, BillingSchedule.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  /// Save the full schedules map to SharedPreferences.
  static Future<void> save(Map<String, BillingSchedule> schedules) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      schedules.map((k, v) => MapEntry(k, v.toJson())),
    );
    await prefs.setString(_kKey, encoded);
  }

  /// Set (or clear) a single customer's schedule.
  static Future<void> set(
      Map<String, BillingSchedule> schedules,
      String customerName,
      BillingSchedule schedule) async {
    schedules[customerName.toLowerCase()] = schedule;
    await save(schedules);
  }
}
