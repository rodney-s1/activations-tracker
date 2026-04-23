// Plan Mapping model
// Maps a raw MyAdmin billing plan string to a QB SKU label.
// Stored in Hive so the user can manage mappings in Settings → Plan Mapping.

import 'package:hive/hive.dart';
part 'plan_mapping.g.dart';

@HiveType(typeId: 9)
class PlanMapping extends HiveObject {
  @HiveField(0)
  String myAdminPlan; // raw MyAdmin "Active Billing Plan" value (case-insensitive match)

  @HiveField(1)
  String qbLabel; // short QB SKU label shown on card, e.g. "GO", "ProPlus", "Pro"

  @HiveField(2)
  bool isDefault; // true = seeded default (still deletable)

  PlanMapping({
    required this.myAdminPlan,
    required this.qbLabel,
    this.isDefault = false,
  });
}
