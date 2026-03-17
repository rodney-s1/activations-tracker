// Manages serial prefix filter rules in Hive

import 'package:hive_flutter/hive_flutter.dart';
import '../models/serial_filter_rule.dart';

class FilterSettingsService {
  static const _boxName = 'serial_filters';
  static Box<SerialFilterRule>? _box;

  // Default system-defined rules seeded on first launch
  static final _defaults = [
    SerialFilterRule(
      prefix: 'EVD',
      isExcluded: true,
      label: 'Surfsight Camera Devices',
      isSystem: true,
    ),
  ];

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(SerialFilterRuleAdapter());
    }
    _box = await Hive.openBox<SerialFilterRule>(_boxName);

    // Seed defaults if empty
    if (_box!.isEmpty) {
      for (final rule in _defaults) {
        await _box!.add(rule);
      }
    }
  }

  static Box<SerialFilterRule> get box {
    if (_box == null) throw StateError('FilterSettingsService not initialized');
    return _box!;
  }

  static List<SerialFilterRule> getAllRules() => box.values.toList();

  static List<SerialFilterRule> getExcludedRules() =>
      box.values.where((r) => r.isExcluded).toList();

  static Future<void> addRule(SerialFilterRule rule) async {
    await box.add(rule);
  }

  static Future<void> updateRule(SerialFilterRule rule) async {
    await rule.save();
  }

  static Future<void> deleteRule(SerialFilterRule rule) async {
    await rule.delete();
  }

  /// Returns the set of excluded prefixes (upper-cased) for quick lookup
  static Set<String> getExcludedPrefixes() {
    return box.values
        .where((r) => r.isExcluded)
        .map((r) => r.prefix.trim().toUpperCase())
        .toSet();
  }
}
