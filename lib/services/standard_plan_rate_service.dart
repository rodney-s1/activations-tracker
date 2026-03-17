// Service for Standard Plan Rates (Hive typeId=3)
import 'package:hive_flutter/hive_flutter.dart';
import '../models/standard_plan_rate.dart';

class StandardPlanRateService {
  static const _boxName = 'standard_plan_rates';
  static Box<StandardPlanRate>? _box;

  static final _defaults = [
    StandardPlanRate(planKey: 'GO',         keyword: 'go',         yourCost: 18.40, sortOrder: 0),
    StandardPlanRate(planKey: 'ProPlus',    keyword: 'proplus',    yourCost: 19.00, sortOrder: 1),
    StandardPlanRate(planKey: 'Pro',        keyword: 'pro',        yourCost: 16.00, sortOrder: 2),
    StandardPlanRate(planKey: 'Regulatory', keyword: 'regulatory', yourCost: 11.50, sortOrder: 3),
    StandardPlanRate(planKey: 'Base',       keyword: 'base',       yourCost:  7.00, sortOrder: 4),
    StandardPlanRate(planKey: 'Suspend',    keyword: 'suspend',    yourCost:  5.00, sortOrder: 5),
  ];

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(StandardPlanRateAdapter());
    }
    _box = await Hive.openBox<StandardPlanRate>(_boxName);
    if (_box!.isEmpty) {
      for (final r in _defaults) await _box!.add(r);
    }
  }

  static Box<StandardPlanRate> get box => _box!;

  static List<StandardPlanRate> getAll() {
    final list = _box!.values.toList();
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  static Future<void> update(StandardPlanRate rate) => rate.save();

  static Future<void> resetToDefaults() async {
    await _box!.clear();
    for (final r in _defaults) await _box!.add(r);
  }
}
