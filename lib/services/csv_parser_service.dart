// Parses the Device Contract Request Admin CSV format

import '../models/activation_record.dart';
import '../models/customer_group.dart';
import '../services/filter_settings_service.dart';
import '../services/pricing_engine.dart';

class BlankCustomerRecord {
  final int lineNumber;
  final String serialNumber;
  final String requestType;

  BlankCustomerRecord({
    required this.lineNumber,
    required this.serialNumber,
    required this.requestType,
  });
}

class MissingCodeFlag {
  final String customerName;
  final String serialNumber;
  final String ratePlan;

  MissingCodeFlag({
    required this.customerName,
    required this.serialNumber,
    required this.ratePlan,
  });
}

class MissingRpcFlag {
  final String customerName;
  final String serialNumber;
  final String ratePlan;
  final String requiredRpc; // the RPC that should have been on the device

  MissingRpcFlag({
    required this.customerName,
    required this.serialNumber,
    required this.ratePlan,
    required this.requiredRpc,
  });
}

class CsvParseResult {
  final String reportName;
  final String reportDate;
  final String dateFrom;
  final String dateTo;
  final List<ActivationRecord> records;
  final List<String> skippedReasons;
  final List<BlankCustomerRecord> blankCustomers;
  final List<MissingCodeFlag> missingCodeFlags;
  final List<MissingRpcFlag> missingRpcFlags;

  CsvParseResult({
    required this.reportName,
    required this.reportDate,
    required this.dateFrom,
    required this.dateTo,
    required this.records,
    required this.skippedReasons,
    required this.blankCustomers,
    required this.missingCodeFlags,
    this.missingRpcFlags = const [],
  });
}

class CsvParserService {
  // ----------------------------------------------------------------
  // HARD-CODED FILTER RULES (not user-configurable)
  // ----------------------------------------------------------------

  // Only include these request types
  static const _allowedRequestTypes = ['AUTOBILLING'];

  // Include if requestType contains this phrase
  static const _autoActivationPhrase = 'GO DEVICE WITH AUTOACTIVATION DATE';

  // Always excluded regardless of anything else
  static const _alwaysExcludedPrefixes = ['EVD'];

  // Rate plan substrings that always exclude a device
  static const _excludedRatePlanSubstrings = ['Third Party Plan [0250]'];

  // ----------------------------------------------------------------

  /// Main filter logic.
  /// [userExcludedPrefixes] = set of prefixes user has toggled ON in settings.
  static bool _isIncluded(
    ActivationRecord r,
    List<String> reasons,
    Set<String> userExcludedPrefixes,
  ) {
    final serial = r.serialNumber.trim().toUpperCase();
    final reqType = r.requestType.trim();
    final ratePlan = r.ratePlan.trim();

    // ── Always-excluded prefixes (EVD, etc.) ───────────────────────
    for (final prefix in _alwaysExcludedPrefixes) {
      if (serial.startsWith(prefix)) {
        reasons.add('${r.serialNumber}: excluded (always-skip prefix $prefix)');
        return false;
      }
    }

    // ── CN serials: only exclude if rate plan contains [0250] ──────
    // CN serials WITHOUT [0250] are kept.
    if (serial.startsWith('CN')) {
      bool hasBadPlan = _excludedRatePlanSubstrings
          .any((rp) => ratePlan.contains(rp));
      if (hasBadPlan) {
        reasons.add(
            '${r.serialNumber}: CN excluded (rate plan contains [0250])');
        return false;
      }
      // CN without [0250] → falls through to other checks
    } else {
      // Non-CN: check general rate plan exclusions
      for (final rp in _excludedRatePlanSubstrings) {
        if (ratePlan.contains(rp)) {
          reasons.add(
              '${r.serialNumber}: excluded (rate plan: $ratePlan)');
          return false;
        }
      }
    }

    // ── User-configured prefix exclusions (from settings) ─────────
    for (final prefix in userExcludedPrefixes) {
      if (serial.startsWith(prefix)) {
        reasons.add(
            '${r.serialNumber}: excluded (user filter prefix $prefix)');
        return false;
      }
    }

    // ── Request type filter ────────────────────────────────────────
    final reqUpper = reqType.toUpperCase();
    final isAutobilling =
        _allowedRequestTypes.any((t) => reqUpper == t);
    final isAutoActivation = reqUpper.contains(_autoActivationPhrase);

    if (!isAutobilling && !isAutoActivation) {
      reasons.add('${r.serialNumber}: excluded (requestType: $reqType)');
      return false;
    }

    // ── Must have billing start date ───────────────────────────────
    if (r.billingStart == null) {
      reasons.add('${r.serialNumber}: excluded (no billing start date)');
      return false;
    }

    // ── Must have positive monthly cost ───────────────────────────
    if (r.monthlyCost <= 0) {
      reasons.add('${r.serialNumber}: excluded (zero/no monthly cost)');
      return false;
    }

    return true;
  }

  /// Splits a raw CSV line respecting quoted fields.
  static List<String> _splitCsvLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    result.add(buffer.toString());
    return result;
  }

  static CsvParseResult parse(String csvContent, [PricingEngine? engine]) {
    // Load user-configured excluded prefixes from settings
    final userExcludedPrefixes = FilterSettingsService.getExcludedPrefixes();
    // Remove always-excluded ones so they aren't double-processed
    for (final p in _alwaysExcludedPrefixes) {
      userExcludedPrefixes.remove(p.toUpperCase());
    }
    // Also remove CN since we handle it specially
    userExcludedPrefixes.remove('CN');

    final lines = csvContent
        .split('\n')
        .map((l) => l.replaceAll('\r', ''))
        .toList();

    String reportName = '';
    String reportDate = '';
    String dateFrom = '';
    String dateTo = '';
    final records = <ActivationRecord>[];
    final skipped = <String>[];
    final blankCustomers = <BlankCustomerRecord>[];
    final missingCodeFlags = <MissingCodeFlag>[];
    final missingRpcFlags  = <MissingRpcFlag>[];

    bool headerFound = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (!headerFound) {
        if (line.startsWith('Report Name:')) {
          reportName = line.replaceFirst('Report Name:', '').trim();
          continue;
        }
        if (line.startsWith('Report Date:')) {
          reportDate = line.replaceFirst('Report Date:', '').trim();
          continue;
        }
        if (line.startsWith('Date From')) {
          final parts = _splitCsvLine(line);
          if (parts.length >= 2) dateFrom = parts[1].trim();
          continue;
        }
        if (line.startsWith('Date To')) {
          final parts = _splitCsvLine(line);
          if (parts.length >= 2) dateTo = parts[1].trim();
          continue;
        }
        if (line.startsWith('Device,')) {
          headerFound = true;
          continue;
        }
        continue;
      }

      final cols = _splitCsvLine(line);
      if (cols.length < 5) continue;

      try {
        var record = ActivationRecord.fromCsvRow(cols);

        // ── Skip rows where 'Processed On' (col 9) is blank ───────────
        // These are not yet processed activations and should be ignored.
        if (record.processedOn == null) {
          skipped.add(
              '${record.serialNumber}: skipped (blank Processed On)');
          continue;
        }

        // ── Blank customer name detection ──────────────────────────
        if (record.customer.trim().isEmpty) {
          blankCustomers.add(BlankCustomerRecord(
            lineNumber: i + 1,
            serialNumber: record.serialNumber,
            requestType: record.requestType,
          ));
          skipped.add(
              '${record.serialNumber}: BLANK CUSTOMER NAME (line ${i + 1}) — needs manual fix');
          continue;
        }

        if (_isIncluded(record, skipped, userExcludedPrefixes)) {
          // ── Apply pricing engine ─────────────────────────────────
          if (engine != null) {
            final priceResult = engine.resolve(record);
            record = record.withResolvedPricing(
              customerPrice: priceResult.customerPrice,
              matchedRule: priceResult.matchedRule,
              missingCode: priceResult.missingCode,
              missingRpc: priceResult.missingRpc,
            );
            if (priceResult.missingCode) {
              missingCodeFlags.add(MissingCodeFlag(
                customerName: record.customer,
                serialNumber: record.serialNumber,
                ratePlan: record.ratePlan,
              ));
            }
            if (priceResult.missingRpc) {
              missingRpcFlags.add(MissingRpcFlag(
                customerName: record.customer,
                serialNumber: record.serialNumber,
                ratePlan: record.ratePlan,
                requiredRpc: priceResult.matchedRule
                    .contains('"') // extract RPC from matchedRule string
                    ? RegExp(r'MISSING RPC "([^"]+)"')
                            .firstMatch(priceResult.matchedRule)
                            ?.group(1) ??
                        ''
                    : '',
              ));
            }
          }
          records.add(record);
        }
      } catch (e) {
        skipped.add('Line ${i + 1} parse error: $e');
      }
    }

    return CsvParseResult(
      reportName: reportName,
      reportDate: reportDate,
      dateFrom: dateFrom,
      dateTo: dateTo,
      records: records,
      skippedReasons: skipped,
      blankCustomers: blankCustomers,
      missingCodeFlags: missingCodeFlags,
      missingRpcFlags:  missingRpcFlags,
    );
  }

  /// Groups parsed records by customer name, sorted alphabetically.
  static List<CustomerGroup> groupByCustomer(List<ActivationRecord> records) {
    final map = <String, List<ActivationRecord>>{};
    for (final r in records) {
      map.putIfAbsent(r.customer, () => []).add(r);
    }
    final groups = map.entries
        .map((e) => CustomerGroup(customerName: e.key, devices: e.value))
        .toList();
    groups.sort((a, b) =>
        a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase()));
    return groups;
  }
}
