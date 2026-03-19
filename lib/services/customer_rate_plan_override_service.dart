// Service for Customer Rate Plan Overrides (Hive typeId=7)
//
// An override sets a custom yourCost and/or customerPrice for a specific
// customer + rate-plan combination, bypassing the Standard Plan Rates table.

import 'package:hive_flutter/hive_flutter.dart';
import '../models/customer_rate_plan_override.dart';

class CustomerRatePlanOverrideService {
  static const _boxName = 'customer_rate_plan_overrides';
  static Box<CustomerRatePlanOverride>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(CustomerRatePlanOverrideAdapter());
    }
    _box = await Hive.openBox<CustomerRatePlanOverride>(_boxName);
  }

  static Box<CustomerRatePlanOverride> get box => _box!;

  static List<CustomerRatePlanOverride> getAll() {
    final list = _box!.values.toList();
    list.sort((a, b) => a.customerName
        .toLowerCase()
        .compareTo(b.customerName.toLowerCase()));
    return list;
  }

  /// All unique customer names that have at least one override
  static List<String> customersWithOverrides() {
    final names =
        _box!.values.map((o) => o.customerName).toSet().toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Save or update an override (matched by customerName + ratePlan).
  static Future<void> save(CustomerRatePlanOverride override) async {
    override.lastUpdated = DateTime.now();
    for (final key in _box!.keys) {
      final existing = _box!.get(key);
      if (existing != null &&
          existing.customerName.trim().toLowerCase() ==
              override.customerName.trim().toLowerCase() &&
          existing.ratePlan.trim().toLowerCase() ==
              override.ratePlan.trim().toLowerCase()) {
        existing.customerPrice = override.customerPrice;
        existing.yourCost      = override.yourCost;
        existing.notes         = override.notes;
        existing.lastUpdated   = DateTime.now();
        await existing.save();
        return;
      }
    }
    await _box!.add(override);
  }

  /// Update an override at a known box index.
  static Future<void> updateAt(
      CustomerRatePlanOverride override, dynamic boxKey) async {
    override.lastUpdated = DateTime.now();
    await _box!.put(boxKey, override);
  }

  static Future<void> delete(CustomerRatePlanOverride override) =>
      override.delete();

  static Future<void> clearAll() => _box!.clear();

  /// Restore from cloud payload — replaces the entire box.
  static Future<void> restoreFromCloud(
      List<Map<String, dynamic>> list) async {
    await _box!.clear();
    for (final item in list) {
      await _box!.add(CustomerRatePlanOverride(
        customerName:  item['customerName']?.toString()            ?? '',
        ratePlan:      item['ratePlan']?.toString()                ?? '',
        customerPrice: (item['customerPrice'] as num?)?.toDouble() ?? 0,
        yourCost:      (item['yourCost']      as num?)?.toDouble() ?? 0,
        notes:         item['notes']?.toString()                   ?? '',
        lastUpdated: item['lastUpdated'] != null &&
                (item['lastUpdated'] as String).isNotEmpty
            ? DateTime.tryParse(item['lastUpdated'] as String)
            : null,
      ));
    }
  }
}
