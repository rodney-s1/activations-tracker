// Persists manual per-device price overrides using SharedPreferences.
// Keyed by serial number; stores yourCost and customerPrice.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class DevicePriceOverride {
  final String serialNumber;
  final double yourCost;        // what Geotab charges you (0 = not overridden)
  final double customerPrice;   // what you charge the customer (0 = not overridden)

  const DevicePriceOverride({
    required this.serialNumber,
    required this.yourCost,
    required this.customerPrice,
  });

  Map<String, dynamic> toJson() => {
    'serial': serialNumber,
    'yourCost': yourCost,
    'customerPrice': customerPrice,
  };

  factory DevicePriceOverride.fromJson(Map<String, dynamic> j) =>
      DevicePriceOverride(
        serialNumber: j['serial'] as String? ?? '',
        yourCost: (j['yourCost'] as num?)?.toDouble() ?? 0.0,
        customerPrice: (j['customerPrice'] as num?)?.toDouble() ?? 0.0,
      );
}

class DevicePriceOverrideService {
  static const _key = 'device_price_overrides_v1';

  /// Load all overrides as a map keyed by serial number.
  static Future<Map<String, DevicePriceOverride>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final list = (jsonDecode(raw) as List<dynamic>);
      return {
        for (final item in list)
          if (item is Map<String, dynamic>)
            (item['serial'] as String? ?? ''): DevicePriceOverride.fromJson(item)
      };
    } catch (_) {
      return {};
    }
  }

  /// Save a single override (upsert by serial number).
  static Future<void> save(DevicePriceOverride override) async {
    final all = await loadAll();
    all[override.serialNumber] = override;
    await _persist(all);
  }

  /// Remove override for a given serial number.
  static Future<void> clear(String serialNumber) async {
    final all = await loadAll();
    all.remove(serialNumber);
    await _persist(all);
  }

  /// Clear all overrides.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> _persist(Map<String, DevicePriceOverride> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(all.values.map((o) => o.toJson()).toList()));
  }
}
