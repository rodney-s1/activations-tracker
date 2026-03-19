// Represents a customer group with their prorated devices

import 'package:intl/intl.dart';
import 'activation_record.dart';

class CustomerGroup {
  final String customerName;
  final List<ActivationRecord> devices;

  CustomerGroup({
    required this.customerName,
    required this.devices,
  });

  int get deviceCount => devices.length;

  double get totalProratedCost =>
      devices.fold(0.0, (sum, d) => sum + d.proratedCost);

  double get totalMonthlyCost =>
      devices.fold(0.0, (sum, d) => sum + d.monthlyCost);

  /// Total prorated cost using the customer's resolved billing price (what you charge them)
  double get totalCustomerProratedCost =>
      devices.fold(0.0, (sum, d) => sum + d.customerProratedCost);

  /// Total monthly cost using the customer's resolved billing price
  double get totalCustomerMonthlyCost =>
      devices.fold(0.0, (sum, d) => sum + d.resolvedCustomerPrice);

  /// Whether any device in this group has a missing-code flag
  bool get hasMissingCodeFlag => devices.any((d) => d.missingCodeFlag);

  /// The earliest billing start date among this customer's devices
  DateTime? get earliestBillingStart {
    final dates = devices
        .where((d) => d.billingStart != null)
        .map((d) => d.billingStart!)
        .toList();
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.first;
  }

  /// The latest billing start date among this customer's devices
  DateTime? get latestBillingStart {
    final dates = devices
        .where((d) => d.billingStart != null)
        .map((d) => d.billingStart!)
        .toList();
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.last;
  }

  // ── Invoice Line Generation ─────────────────────────────────────────────────

  /// Builds copyable invoice lines grouped by billing start date.
  ///
  /// Format per date group:
  ///   " - New Activations Prorated March 3 through March 31 2026 for devices:"
  ///   "G9T4M6T8M1NP"
  ///   "GA2CTAY721SU"
  ///   (blank line between groups)
  String buildInvoiceLines() {
    // Only include devices that have a billing start date
    final billable = devices.where((d) => d.billingStart != null).toList();
    if (billable.isEmpty) return '';

    // Group devices by their billing start date (date only, no time)
    final Map<DateTime, List<ActivationRecord>> byDate = {};
    for (final d in billable) {
      final key = DateTime(
          d.billingStart!.year, d.billingStart!.month, d.billingStart!.day);
      byDate.putIfAbsent(key, () => []).add(d);
    }

    // Sort date groups chronologically
    final sortedDates = byDate.keys.toList()..sort();

    final buffer = StringBuffer();
    final monthFmt = DateFormat('MMMM'); // e.g. "March"

    for (int i = 0; i < sortedDates.length; i++) {
      final startDate = sortedDates[i];
      final devicesOnDate = byDate[startDate]!;

      // Last day of the billing month
      final lastDay =
          DateTime(startDate.year, startDate.month + 1, 0).day;
      final endDate =
          DateTime(startDate.year, startDate.month, lastDay);

      final monthName = monthFmt.format(startDate);
      final endMonthName = monthFmt.format(endDate);
      final year = startDate.year;

      // Header line
      // If start and end are in the same month (always true for proration):
      // "March 3 through March 31 2026"
      buffer.write(
          ' - New Activations Prorated $monthName ${startDate.day} through $endMonthName $lastDay $year for devices:');
      buffer.write('\n');

      // Serial numbers, one per line
      for (final d in devicesOnDate) {
        buffer.write(d.serialNumber);
        buffer.write('\n');
      }

      // Blank line between groups (not after the last one)
      if (i < sortedDates.length - 1) {
        buffer.write('\n');
      }
    }

    return buffer.toString().trimRight();
  }
}
