// Per-customer, per-rate-plan price override
//
// An override lets you set a custom "your cost" and/or "customer price"
// for a specific customer + rate-plan combination, bypassing the Standard
// Plan Rates table entirely.
//
// Example:
//   customerName = "City of Raleigh - Solid Waste"
//   ratePlan     = "ProPlus Install Bundle Plan [1250]"
//   yourCost     = 19.00    (what Geotab charges you for this customer)
//   customerPrice= 27.95   (what you bill this customer)

import 'package:hive/hive.dart';
part 'customer_rate_plan_override.g.dart';

@HiveType(typeId: 7)
class CustomerRatePlanOverride extends HiveObject {
  @HiveField(0)
  String customerName; // exact match (case-insensitive) against CSV customer column

  @HiveField(1)
  String ratePlan; // substring match against Rate Plan column in CSV

  @HiveField(2)
  double customerPrice; // what YOU charge this customer per device/month

  @HiveField(3)
  String notes;

  @HiveField(4)
  DateTime? lastUpdated;

  @HiveField(5)
  double yourCost; // what Geotab charges YOU for this customer/plan (0 = use standard)

  CustomerRatePlanOverride({
    required this.customerName,
    required this.ratePlan,
    required this.customerPrice,
    this.notes = '',
    this.lastUpdated,
    this.yourCost = 0.0,
  });
}
