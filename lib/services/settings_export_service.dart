// Portable settings export/import — bundles all user config into one JSON blob
// so you can move between computers without losing anything.

import 'dart:convert';
import '../services/standard_plan_rate_service.dart';
import '../services/customer_plan_code_service.dart';
import '../services/customer_rate_service.dart';
import '../services/filter_settings_service.dart';
import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../models/customer_rate.dart';
import '../models/serial_filter_rule.dart';

class SettingsExportService {
  /// Export everything to a JSON string
  static String exportAll() {
    final standardRates = StandardPlanRateService.getAll().map((r) => {
      'planKey': r.planKey,
      'keyword': r.keyword,
      'yourCost': r.yourCost,
      'sortOrder': r.sortOrder,
    }).toList();

    final customerCodes = CustomerPlanCodeService.getAll().map((c) => {
      'customerName': c.customerName,
      'planCode': c.planCode,
      'customerPrice': c.customerPrice,
      'notes': c.notes,
    }).toList();

    final customerRates = CustomerRateService.getAllRates().map((r) => {
      'customerName': r.customerName,
      'overrideMonthlyRate': r.overrideMonthlyRate,
      'notes': r.notes,
      'ratePlanLabel': r.ratePlanLabel,
    }).toList();

    final filterRules = FilterSettingsService.getAllRules().map((r) => {
      'prefix': r.prefix,
      'isExcluded': r.isExcluded,
      'label': r.label,
      'isSystem': r.isSystem,
    }).toList();

    final payload = {
      'version': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'standardPlanRates': standardRates,
      'customerPlanCodes': customerCodes,
      'customerRates': customerRates,
      'serialFilterRules': filterRules,
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Import from JSON string — returns a summary of what was restored
  static Future<Map<String, int>> importAll(String jsonStr) async {
    final Map<String, dynamic> data = jsonDecode(jsonStr);
    final counts = <String, int>{};

    // Standard plan rates
    if (data['standardPlanRates'] != null) {
      await StandardPlanRateService.resetToDefaults();
      final list = data['standardPlanRates'] as List;
      // Clear defaults and replace with saved
      await StandardPlanRateService.box.clear();
      for (final item in list) {
        await StandardPlanRateService.box.add(StandardPlanRate(
          planKey: item['planKey'] ?? '',
          keyword: item['keyword'] ?? '',
          yourCost: (item['yourCost'] as num).toDouble(),
          sortOrder: item['sortOrder'] ?? 99,
        ));
      }
      counts['standardPlanRates'] = list.length;
    }

    // Customer plan codes
    if (data['customerPlanCodes'] != null) {
      await CustomerPlanCodeService.clearAll();
      final list = data['customerPlanCodes'] as List;
      for (final item in list) {
        await CustomerPlanCodeService.save(CustomerPlanCode(
          customerName: item['customerName'] ?? '',
          planCode: item['planCode'] ?? '',
          customerPrice: (item['customerPrice'] as num).toDouble(),
          notes: item['notes'] ?? '',
        ));
      }
      counts['customerPlanCodes'] = list.length;
    }

    // Customer rates (legacy rate book)
    if (data['customerRates'] != null) {
      await CustomerRateService.clearAll();
      final list = data['customerRates'] as List;
      for (final item in list) {
        await CustomerRateService.saveRate(CustomerRate(
          customerName: item['customerName'] ?? '',
          overrideMonthlyRate: item['overrideMonthlyRate'] != null
              ? (item['overrideMonthlyRate'] as num).toDouble()
              : null,
          notes: item['notes'] ?? '',
          ratePlanLabel: item['ratePlanLabel'] ?? '',
        ));
      }
      counts['customerRates'] = list.length;
    }

    // Serial filter rules
    if (data['serialFilterRules'] != null) {
      await FilterSettingsService.box.clear();
      final list = data['serialFilterRules'] as List;
      for (final item in list) {
        await FilterSettingsService.addRule(SerialFilterRule(
          prefix: item['prefix'] ?? '',
          isExcluded: item['isExcluded'] ?? true,
          label: item['label'] ?? '',
          isSystem: item['isSystem'] ?? false,
        ));
      }
      counts['serialFilterRules'] = list.length;
    }

    return counts;
  }
}
