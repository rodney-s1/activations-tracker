// Model for a single activation row from the CSV

class ActivationRecord {
  final String device;
  final String serialNumber;
  final String imei;
  final String sim;
  final String account;
  final String customer;
  final String planMode;
  final String requestType;
  final DateTime? requestedOn;
  final DateTime? processedOn;
  final String activeFeatures;
  final String status;
  final String comments;
  final String ratePlan;
  final double monthlyCost;       // Geotab's cost to YOU (from CSV)
  final DateTime? billingStart;
  final String expiring;
  final String terminationReason;
  final String terminationComment;
  final String productCode;
  final String assignedPO;

  // ── Pricing engine output ──────────────────────────────────────────
  /// Resolved price YOU charge the customer (may differ from monthlyCost)
  final double resolvedCustomerPrice;
  /// Human-readable rule that matched (e.g. "Customer code: [1450]")
  final String priceMatchedRule;
  /// True if customer has plan codes but none matched this record
  final bool missingCodeFlag;

  ActivationRecord({
    required this.device,
    required this.serialNumber,
    required this.imei,
    required this.sim,
    required this.account,
    required this.customer,
    required this.planMode,
    required this.requestType,
    this.requestedOn,
    this.processedOn,
    required this.activeFeatures,
    required this.status,
    required this.comments,
    required this.ratePlan,
    required this.monthlyCost,
    this.billingStart,
    required this.expiring,
    required this.terminationReason,
    required this.terminationComment,
    required this.productCode,
    required this.assignedPO,
    double? resolvedCustomerPrice,
    this.priceMatchedRule = '',
    this.missingCodeFlag = false,
  }) : resolvedCustomerPrice = resolvedCustomerPrice ?? monthlyCost;

  /// Proration using YOUR cost to Geotab (internal cost basis)
  double get proratedCost {
    if (billingStart == null || monthlyCost <= 0) return 0.0;
    final start = billingStart!;
    final daysInMonth = DateTime(start.year, start.month + 1, 0).day;
    final daysRemaining = daysInMonth - start.day + 1;
    return monthlyCost / daysInMonth * daysRemaining;
  }

  /// Proration using the CUSTOMER price (what you bill them) — use for invoicing
  double get customerProratedCost {
    if (billingStart == null || resolvedCustomerPrice <= 0) return 0.0;
    final start = billingStart!;
    final daysInMonth = DateTime(start.year, start.month + 1, 0).day;
    final daysRemaining = daysInMonth - start.day + 1;
    return resolvedCustomerPrice / daysInMonth * daysRemaining;
  }

  /// The date from which proration begins (billing start)
  DateTime? get prorateFrom => billingStart;

  static double _parseCost(String raw) {
    final cleaned = raw.replaceAll(r'$', '').replaceAll(',', '').trim();
    return double.tryParse(cleaned) ?? 0.0;
  }

  static DateTime? _parseDate(String raw) {
    if (raw.isEmpty || raw == 'N/A') return null;
    try {
      final trimmed = raw.trim();
      if (trimmed.contains(' ')) {
        final parts = trimmed.split(' ');
        final dateParts = parts[0].split('-');
        final timeParts = parts[1].split(':');
        return DateTime(
          int.parse(dateParts[0]),
          int.parse(dateParts[1]),
          int.parse(dateParts[2]),
          int.parse(timeParts[0]),
          int.parse(timeParts[1]),
          int.parse(timeParts[2]),
        );
      } else {
        final dateParts = trimmed.split('-');
        return DateTime(
          int.parse(dateParts[0]),
          int.parse(dateParts[1]),
          int.parse(dateParts[2]),
        );
      }
    } catch (_) {
      return null;
    }
  }

  factory ActivationRecord.fromCsvRow(List<String> cols) {
    String g(int i) => i < cols.length ? cols[i].trim() : '';
    return ActivationRecord(
      device: g(0),
      serialNumber: g(1),
      imei: g(2),
      sim: g(3),
      account: g(4),
      customer: g(5),
      planMode: g(6),
      requestType: g(7),
      requestedOn: _parseDate(g(8)),
      processedOn: _parseDate(g(9)),
      activeFeatures: g(10),
      status: g(11),
      comments: g(12),
      ratePlan: g(13),
      monthlyCost: _parseCost(g(14)),
      billingStart: _parseDate(g(15)),
      expiring: g(16),
      terminationReason: g(17),
      terminationComment: g(18),
      productCode: g(19),
      assignedPO: g(20),
    );
  }

  /// Create a copy with resolved pricing applied
  ActivationRecord withResolvedPricing({
    required double customerPrice,
    required String matchedRule,
    required bool missingCode,
  }) {
    return ActivationRecord(
      device: device,
      serialNumber: serialNumber,
      imei: imei,
      sim: sim,
      account: account,
      customer: customer,
      planMode: planMode,
      requestType: requestType,
      requestedOn: requestedOn,
      processedOn: processedOn,
      activeFeatures: activeFeatures,
      status: status,
      comments: comments,
      ratePlan: ratePlan,
      monthlyCost: monthlyCost,
      billingStart: billingStart,
      expiring: expiring,
      terminationReason: terminationReason,
      terminationComment: terminationComment,
      productCode: productCode,
      assignedPO: assignedPO,
      resolvedCustomerPrice: customerPrice,
      priceMatchedRule: matchedRule,
      missingCodeFlag: missingCode,
    );
  }
}
