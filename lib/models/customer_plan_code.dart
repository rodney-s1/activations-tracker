// Customer-specific rate code entry
// One row = one customer + one rate plan code + your selling price to that customer
// e.g.  customer="City of Raleigh - Solid Waste"
//        planCode="GO Bundle Plan [1450]"   (exact or partial match)
//        customerPrice=15.00

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

  CustomerPlanCode({
    required this.customerName,
    required this.planCode,
    required this.customerPrice,
    this.notes = '',
    this.lastUpdated,
  });
}
