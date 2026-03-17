// Standard plan rate — maps a keyword to your cost for that plan type
// e.g. keyword="GO", yourCost=18.40

import 'package:hive/hive.dart';
part 'standard_plan_rate.g.dart';

@HiveType(typeId: 3)
class StandardPlanRate extends HiveObject {
  @HiveField(0)
  String planKey; // short identifier, e.g. "GO", "ProPlus", "Pro", "Regulatory", "Base", "Suspend"

  @HiveField(1)
  String keyword; // substring to match against rate plan field in CSV (case-insensitive)

  @HiveField(2)
  double yourCost; // what Geotab charges YOU per device per month

  @HiveField(3)
  int sortOrder; // display order in the UI

  StandardPlanRate({
    required this.planKey,
    required this.keyword,
    required this.yourCost,
    this.sortOrder = 99,
  });
}
