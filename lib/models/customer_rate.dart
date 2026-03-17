// Customer Rate record — stores a manual price override per customer
// Optionally associated with a specific rate plan

import 'package:hive/hive.dart';

part 'customer_rate.g.dart';

@HiveType(typeId: 2)
class CustomerRate extends HiveObject {
  @HiveField(0)
  String customerName; // must match Active Database/Customer field in CSV

  @HiveField(1)
  double? overrideMonthlyRate; // if set, overrides the CSV monthly cost

  @HiveField(2)
  String notes; // free-form notes (e.g. QB invoice ref, PO number)

  @HiveField(3)
  DateTime? lastUpdated;

  @HiveField(4)
  String ratePlanLabel; // friendly label for the plan (optional)

  CustomerRate({
    required this.customerName,
    this.overrideMonthlyRate,
    this.notes = '',
    this.lastUpdated,
    this.ratePlanLabel = '',
  });
}
