// Represents a customer group with their prorated devices

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
}
