// Customer-specific rate code entry
// One row = one customer + one rate plan code + your selling price to that customer
// e.g.  customer="City of Raleigh - Solid Waste"
//        planCode="GO Bundle Plan [1450]"   (matches Rate Plan column in Activations CSV)
//        requiredRpc="BUNDLE"               (MyAdmin Rate Plan Code that enables this discount)
//        customerPrice=15.00
//
// requiredRpc: if set, the discounted price only applies when the device's
// Rate Plan Code in MyAdmin matches this value (case-insensitive substring).
// If the device is missing this RPC, Geotab hasn't applied the discount to you,
// so you can't pass it on — the device is flagged as 'missing RPC'.

import 'package:hive/hive.dart';
part 'customer_plan_code.g.dart';

@HiveType(typeId: 4)
class CustomerPlanCode extends HiveObject {
  @HiveField(0)
  String customerName; // matches Active Database/Customer in CSV

  @HiveField(1)
  String planCode; // substring to match against Rate Plan column in CSV

  @HiveField(2)
  double customerPrice; // what YOU charge this customer per device/month

  @HiveField(3)
  String notes;

  @HiveField(4)
  DateTime? lastUpdated;

  /// MyAdmin Rate Plan Code that must be present on a device for this
  /// discounted price to apply. Empty string = no RPC requirement.
  @HiveField(5)
  String requiredRpc;

  CustomerPlanCode({
    required this.customerName,
    required this.planCode,
    required this.customerPrice,
    this.notes = '',
    this.lastUpdated,
    this.requiredRpc = '',
  });
}
