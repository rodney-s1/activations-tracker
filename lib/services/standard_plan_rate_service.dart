// Service for Standard Plan Rates (Hive typeId=3)
import 'package:hive_flutter/hive_flutter.dart';
import '../models/standard_plan_rate.dart';

class StandardPlanRateService {
  static const _boxName = 'standard_plan_rates';
  static Box<StandardPlanRate>? _box;

  static final _defaults = [
    // ── Core Geotab plans ────────────────────────────────────────────────────
    StandardPlanRate(planKey: 'GO',              keyword: 'go',              yourCost: 12.60, customerPrice: 18.80, sortOrder:  0),
    StandardPlanRate(planKey: 'ProPlus',         keyword: 'proplus',         yourCost: 19.00, customerPrice: 27.95, sortOrder:  1),
    StandardPlanRate(planKey: 'Pro',             keyword: 'pro',             yourCost: 16.00, customerPrice: 24.95, sortOrder:  2),
    StandardPlanRate(planKey: 'Regulatory',      keyword: 'regulatory',      yourCost: 11.50, customerPrice:  0.00, sortOrder:  3),
    StandardPlanRate(planKey: 'Base',            keyword: 'base',            yourCost:  7.00, customerPrice:  0.00, sortOrder:  4),
    StandardPlanRate(planKey: 'Suspend',         keyword: 'suspend',         yourCost:  5.75, customerPrice: 10.00, sortOrder:  5),
    // ── OEM integrations ─────────────────────────────────────────────────────
    StandardPlanRate(planKey: 'Ford OEM',        keyword: 'ford',            yourCost:  0.00, customerPrice:  0.00, sortOrder: 10),
    StandardPlanRate(planKey: 'GM OEM',          keyword: 'geotab gm',       yourCost:  0.00, customerPrice:  0.00, sortOrder: 11),
    StandardPlanRate(planKey: 'Mack OEM',        keyword: 'geotab mack',     yourCost:  0.00, customerPrice:  0.00, sortOrder: 12),
    StandardPlanRate(planKey: 'Mercedes OEM',    keyword: 'mercedes',        yourCost:  0.00, customerPrice:  0.00, sortOrder: 13),
    StandardPlanRate(planKey: 'Navistar OEM',    keyword: 'navistar',        yourCost:  0.00, customerPrice:  0.00, sortOrder: 14),
    StandardPlanRate(planKey: 'Volvo OEM',       keyword: 'geotab volvo',    yourCost:  0.00, customerPrice:  0.00, sortOrder: 15),
    StandardPlanRate(planKey: 'Freightliner OEM',keyword: 'freightliner',    yourCost:  0.00, customerPrice:  0.00, sortOrder: 16),
    StandardPlanRate(planKey: 'Stellantis OEM',  keyword: 'stellantis',      yourCost:  0.00, customerPrice:  0.00, sortOrder: 17),
    StandardPlanRate(planKey: 'SW3',             keyword: 'sw3',             yourCost:  0.00, customerPrice:  0.00, sortOrder: 18),
    // ── AEMP / telematics add-ons ────────────────────────────────────────────
    StandardPlanRate(planKey: 'AEMP',            keyword: 'aemp',            yourCost:  0.00, customerPrice:  0.00, sortOrder: 20),
    StandardPlanRate(planKey: 'CAT AEMP',        keyword: 'cat aemp',        yourCost:  0.00, customerPrice:  0.00, sortOrder: 21),
    StandardPlanRate(planKey: 'JD AEMP',         keyword: 'john deere',      yourCost:  0.00, customerPrice:  0.00, sortOrder: 22),
    StandardPlanRate(planKey: 'Komatsu AEMP',    keyword: 'komatsu',         yourCost:  0.00, customerPrice:  0.00, sortOrder: 23),
  ];

  /// Add new default plans that don't exist yet (called on upgrade — never overwrites).
  static Future<void> _seedNewDefaults() async {
    final existing = _box!.values
        .map((r) => r.planKey.trim().toLowerCase())
        .toSet();
    int nextOrder = _box!.values.isEmpty
        ? 0
        : (_box!.values.map((r) => r.sortOrder).reduce((a, b) => a > b ? a : b) + 1);
    for (final d in _defaults) {
      if (!existing.contains(d.planKey.trim().toLowerCase())) {
        await _box!.add(StandardPlanRate(
          planKey:       d.planKey,
          keyword:       d.keyword,
          yourCost:      d.yourCost,
          customerPrice: d.customerPrice,
          sortOrder:     d.sortOrder > nextOrder ? d.sortOrder : nextOrder++,
        ));
      }
    }
  }

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(StandardPlanRateAdapter());
    }
    _box = await Hive.openBox<StandardPlanRate>(_boxName);
    if (_box!.isEmpty) {
      // Fresh install — seed all defaults
      for (final r in _defaults) await _box!.add(r);
    } else {
      // Existing install — add any new defaults that aren't present yet
      await _seedNewDefaults();
    }
  }

  static Box<StandardPlanRate> get box => _box!;

  static List<StandardPlanRate> getAll() {
    final list = _box!.values.toList();
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  static Future<void> update(StandardPlanRate rate) => rate.save();

  /// Add a brand-new plan rate.
  static Future<void> add(StandardPlanRate rate) async {
    // Assign sortOrder = max existing + 1
    final maxOrder = _box!.values.isEmpty
        ? 0
        : _box!.values.map((r) => r.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
    rate.sortOrder = maxOrder;
    await _box!.add(rate);
  }

  /// Delete a plan rate.
  static Future<void> delete(StandardPlanRate rate) => rate.delete();

  static Future<void> resetToDefaults() async {
    await _box!.clear();
    for (final r in _defaults) await _box!.add(r);
  }
}
