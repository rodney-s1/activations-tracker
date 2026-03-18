// QB Ignore Keyword model
// Stores a keyword string that, when found in a QB Sales CSV item/SKU column,
// causes that entire line to be skipped during import (not counted toward billing).
//
// Default keywords pre-loaded on first install:
//   Credit Card, BlueArrow Fuel, Predictive Coach, Shipping, FedEx,
//   Fleetio, Rosco, Xtract, Integration, TopFly, LifeSaver

import 'package:hive/hive.dart';
part 'qb_ignore_keyword.g.dart';

@HiveType(typeId: 6)
class QbIgnoreKeyword extends HiveObject {
  @HiveField(0)
  String keyword; // case-insensitive substring to match against Column P (Item/SKU)

  @HiveField(1)
  bool isDefault; // true = pre-loaded default (can delete but shown with indicator)

  QbIgnoreKeyword({
    required this.keyword,
    this.isDefault = false,
  });
}
