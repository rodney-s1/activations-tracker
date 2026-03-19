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

  /// Returns devices grouped by billing start date, sorted chronologically.
  Map<DateTime, List<ActivationRecord>> get devicesByBillingDate {
    final billable = devices.where((d) => d.billingStart != null).toList();
    final Map<DateTime, List<ActivationRecord>> byDate = {};
    for (final d in billable) {
      final key = DateTime(
          d.billingStart!.year, d.billingStart!.month, d.billingStart!.day);
      byDate.putIfAbsent(key, () => []).add(d);
    }
    return byDate;
  }

  /// Sorted unique billing dates for this customer.
  List<DateTime> get sortedBillingDates {
    final dates = devicesByBillingDate.keys.toList()..sort();
    return dates;
  }

  /// Build the invoice line text for a SINGLE billing date.
  ///
  /// If [qbItemDescription] is provided it's used as the line header
  /// instead of the default "New Activations Prorated … for devices:".
  String buildInvoiceLineForDate(DateTime startDate,
      {String? qbItemDescription}) {
    final devicesOnDate = devicesByBillingDate[startDate] ?? [];
    if (devicesOnDate.isEmpty) return '';

    final lastDay = DateTime(startDate.year, startDate.month + 1, 0).day;
    final monthFmt = DateFormat('MMMM');
    final monthName = monthFmt.format(startDate);
    final endMonthName = monthFmt.format(DateTime(startDate.year, startDate.month, lastDay));
    final year = startDate.year;

    final buffer = StringBuffer();

    if (qbItemDescription != null && qbItemDescription.isNotEmpty) {
      // Use QB SKU description format:
      //  " - <QB Item> Prorated March 3 through March 31 2026 for devices:"
      buffer.write(
          ' - $qbItemDescription Prorated $monthName ${startDate.day} through $endMonthName $lastDay $year for devices:');
    } else {
      buffer.write(
          ' - New Activations Prorated $monthName ${startDate.day} through $endMonthName $lastDay $year for devices:');
    }
    buffer.write('\n');

    for (final d in devicesOnDate) {
      buffer.write(d.serialNumber);
      buffer.write('\n');
    }

    return buffer.toString().trimRight();
  }

  /// Builds copyable invoice lines grouped by billing start date.
  ///
  /// Format per date group:
  ///   " - New Activations Prorated March 3 through March 31 2026 for devices:"
  ///   "G9T4M6T8M1NP"
  ///   "GA2CTAY721SU"
  ///   (blank line between groups)
  String buildInvoiceLines() {
    final sortedDates = sortedBillingDates;
    if (sortedDates.isEmpty) return '';

    final buffer = StringBuffer();
    for (int i = 0; i < sortedDates.length; i++) {
      buffer.write(buildInvoiceLineForDate(sortedDates[i]));
      if (i < sortedDates.length - 1) buffer.write('\n\n');
    }

    return buffer.toString().trimRight();
  }
}
