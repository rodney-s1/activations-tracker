// QuickBooks Item Price List entry
// Imported from the "Item Price List" CSV export:
//   Item, Description, Cost, Price
//
// typeId: 8  (Hive)

import 'package:hive_flutter/hive_flutter.dart';

part 'qb_item.g.dart';

@HiveType(typeId: 8)
class QbItem extends HiveObject {
  @HiveField(0)
  String item;           // QB item name / SKU  (e.g. "Service Fee Geotab (ProPlus SWELL-CC)")

  @HiveField(1)
  String description;    // longer description from the CSV

  @HiveField(2)
  double cost;           // your cost

  @HiveField(3)
  double price;          // customer price

  QbItem({
    required this.item,
    required this.description,
    required this.cost,
    required this.price,
  });
}
