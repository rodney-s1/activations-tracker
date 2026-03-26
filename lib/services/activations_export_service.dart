// Activations Snapshot Export
//
// Builds a CSV from the current in-memory customer groups so you can archive
// a completed billing period before importing the next CSV file.
//
// CSV columns:
//   Customer, Completed, Serial Number, Rate Plan, Billing Start,
//   Date Group (range label), Days Remaining/In Month,
//   Monthly Cost (your cost), Customer Price (monthly),
//   Prorated Cost (your cost), Customer Prorated Charge,
//   Pricing Rule, Missing Code Flag, Missing RPC Flag, Product Code,
//   Status, Request Type, Processed (date group marked done)

import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/customer_group.dart';
import '../models/activation_record.dart';

class ActivationsExportService {
  // ── Public API ──────────────────────────────────────────────────────────────

  /// Build the snapshot CSV string from [groups].
  ///
  /// - [completedCustomers]  — set of customerName strings whose checkbox is checked
  /// - [processedDatesMap]   — map of customerName to Set(DateTime) for date groups
  ///                           marked as processed (Done button).
  /// - [filterFrom]/[filterTo] — optional date range filter currently applied.
  static String buildCsv({
    required List<CustomerGroup> groups,
    required Set<String> completedCustomers,
    required Map<String, Set<DateTime>> processedDatesMap,
    DateTime? filterFrom,
    DateTime? filterTo,
  }) {
    final buf = StringBuffer();

    // ── Header row ─────────────────────────────────────────────────────────
    buf.writeln(_row([
      'Customer',
      'Completed',
      'Serial Number',
      'Rate Plan',
      'Billing Start',
      'Date Group (Range)',
      'Days Remaining',
      'Days in Month',
      'Monthly Cost (Your Cost)',
      'Customer Price (Monthly)',
      'Prorated Cost (Your Cost)',
      'Customer Prorated Charge',
      'Pricing Rule',
      'Missing Code',
      'Missing RPC',
      'Date Group Processed',
      'Product Code',
      'Status',
      'Request Type',
    ]));

    final dateFmt = DateFormat('MM/dd/yyyy');
    final monthFullFmt = DateFormat('MMMM');

    for (final g in groups) {
      final isCompleted = completedCustomers.contains(g.customerName);
      final processedDates = processedDatesMap[g.customerName] ?? {};

      // Apply same date-range filter as the UI
      final allDates = g.sortedBillingDates;
      final visibleDates = (filterFrom == null && filterTo == null)
          ? allDates
          : allDates.where((d) {
              final day = DateTime(d.year, d.month, d.day);
              if (filterFrom != null && day.isBefore(filterFrom)) return false;
              if (filterTo != null && day.isAfter(filterTo)) return false;
              return true;
            }).toList();

      if (visibleDates.isEmpty) {
        // Customer has no visible date groups — still emit one row per device
        for (final rec in g.devices) {
          buf.writeln(_deviceRow(
            group: g,
            rec: rec,
            isCompleted: isCompleted,
            dateGroupLabel: '',
            isProcessed: false,
            dateFmt: dateFmt,
          ));
        }
        continue;
      }

      for (final date in visibleDates) {
        final devicesOnDate = g.devicesByBillingDate[date] ?? [];
        final lastDay =
            DateTime(date.year, date.month + 1, 0).day;
        final endMonthName =
            monthFullFmt.format(DateTime(date.year, date.month, lastDay));
        final startLabel =
            '${monthFullFmt.format(date)} ${date.day} – $endMonthName $lastDay ${date.year}';
        final isProcessed = processedDates.any((pd) =>
            pd.year == date.year &&
            pd.month == date.month &&
            pd.day == date.day);

        for (final rec in devicesOnDate) {
          buf.writeln(_deviceRow(
            group: g,
            rec: rec,
            isCompleted: isCompleted,
            dateGroupLabel: startLabel,
            isProcessed: isProcessed,
            dateFmt: dateFmt,
          ));
        }
      }
    }

    return buf.toString();
  }

  /// Load which customers are marked completed from SharedPreferences.
  static Future<Set<String>> loadCompletedCustomers(
      List<CustomerGroup> groups) async {
    final prefs = await SharedPreferences.getInstance();
    final completed = <String>{};
    for (final g in groups) {
      final key =
          'completed_v1_${g.customerName.replaceAll(RegExp(r'[^\w]'), '_')}';
      if (prefs.getBool(key) ?? false) {
        completed.add(g.customerName);
      }
    }
    return completed;
  }

  /// Load which date groups are marked processed from SharedPreferences.
  /// The customer_card stores processed dates as a JSON list under a per-customer key.
  static Future<Map<String, Set<DateTime>>> loadProcessedDates(
      List<CustomerGroup> groups) async {
    final prefs = await SharedPreferences.getInstance();
    final result = <String, Set<DateTime>>{};
    for (final g in groups) {
      final key =
          'processed_dates_${g.customerName.replaceAll(RegExp(r'[^\w]'), '_')}';
      final raw = prefs.getString(key);
      if (raw != null) {
        try {
          final list = (jsonDecode(raw) as List).cast<String>();
          result[g.customerName] =
              list.map((s) => DateTime.parse(s)).toSet();
        } catch (_) {}
      }
    }
    return result;
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  static String _deviceRow({
    required CustomerGroup group,
    required ActivationRecord rec,
    required bool isCompleted,
    required String dateGroupLabel,
    required bool isProcessed,
    required DateFormat dateFmt,
  }) {
    final daysInMonth = rec.billingStart == null
        ? 0
        : DateTime(rec.billingStart!.year, rec.billingStart!.month + 1, 0).day;
    final daysRemaining = rec.billingStart == null
        ? 0
        : daysInMonth - rec.billingStart!.day + 1;

    return _row([
      group.customerName,
      isCompleted ? 'Yes' : 'No',
      rec.serialNumber,
      rec.ratePlan,
      rec.billingStart != null ? dateFmt.format(rec.billingStart!) : '',
      dateGroupLabel,
      daysRemaining.toString(),
      daysInMonth.toString(),
      rec.monthlyCost.toStringAsFixed(2),
      rec.resolvedCustomerPrice.toStringAsFixed(2),
      rec.proratedCost.toStringAsFixed(2),
      rec.customerProratedCost.toStringAsFixed(2),
      rec.priceMatchedRule,
      rec.missingCodeFlag ? 'Yes' : 'No',
      rec.missingRpcFlag ? 'Yes' : 'No',
      isProcessed ? 'Yes' : 'No',
      rec.productCode,
      rec.status,
      rec.requestType,
    ]);
  }

  /// CSV-escape a single cell value.
  static String _cell(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  /// Build a CSV row from a list of values.
  static String _row(List<String> cells) =>
      cells.map(_cell).join(',');
}
