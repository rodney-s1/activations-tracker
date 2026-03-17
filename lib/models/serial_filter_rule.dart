// Model for a serial number prefix filter rule
// Stored in Hive - user can add/toggle/remove prefix exclusions

import 'package:hive/hive.dart';

part 'serial_filter_rule.g.dart';

@HiveType(typeId: 1)
class SerialFilterRule extends HiveObject {
  @HiveField(0)
  String prefix; // e.g. "EVD", "GA", "CO"

  @HiveField(1)
  bool isExcluded; // true = exclude from reports

  @HiveField(2)
  String label; // friendly label e.g. "Surfsight Camera Devices"

  @HiveField(3)
  bool isSystem; // true = built-in rule (EVD), can't delete but can toggle

  SerialFilterRule({
    required this.prefix,
    required this.isExcluded,
    this.label = '',
    this.isSystem = false,
  });
}
