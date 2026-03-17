// Manages customer rate overrides in Hive

import 'package:hive_flutter/hive_flutter.dart';
import '../models/customer_rate.dart';

class CustomerRateService {
  static const _boxName = 'customer_rates';
  static Box<CustomerRate>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(CustomerRateAdapter());
    }
    _box = await Hive.openBox<CustomerRate>(_boxName);
  }

  static Box<CustomerRate> get box {
    if (_box == null) throw StateError('CustomerRateService not initialized');
    return _box!;
  }

  static List<CustomerRate> getAllRates() {
    final list = box.values.toList();
    list.sort((a, b) =>
        a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase()));
    return list;
  }

  /// Returns null if no override exists for this customer
  static CustomerRate? getRateForCustomer(String customerName) {
    try {
      return box.values.firstWhere(
        (r) => r.customerName.trim().toLowerCase() ==
            customerName.trim().toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveRate(CustomerRate rate) async {
    // Check if already exists by name
    for (final key in box.keys) {
      final existing = box.get(key);
      if (existing != null &&
          existing.customerName.trim().toLowerCase() ==
              rate.customerName.trim().toLowerCase()) {
        existing.overrideMonthlyRate = rate.overrideMonthlyRate;
        existing.notes = rate.notes;
        existing.ratePlanLabel = rate.ratePlanLabel;
        existing.lastUpdated = DateTime.now();
        await existing.save();
        return;
      }
    }
    // New entry
    rate.lastUpdated = DateTime.now();
    await box.add(rate);
  }

  static Future<void> deleteRate(CustomerRate rate) async {
    await rate.delete();
  }

  static Future<void> clearAll() async {
    await box.clear();
  }

  /// Bulk import from a CSV: columns = "Customer Name, Monthly Rate, Notes"
  /// Returns count of records imported
  static Future<int> importFromCsv(String csvContent) async {
    final lines = csvContent.split('\n').map((l) => l.replaceAll('\r', '')).toList();
    int count = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      // Skip header row if it matches common patterns
      final lower = line.toLowerCase();
      if (i == 0 &&
          (lower.startsWith('customer') || lower.startsWith('name'))) {
        continue;
      }

      final parts = _splitCsv(line);
      if (parts.isEmpty) continue;

      final name = parts[0].trim();
      if (name.isEmpty) continue;

      double? rate;
      if (parts.length > 1) {
        final rawRate =
            parts[1].replaceAll(r'$', '').replaceAll(',', '').trim();
        rate = double.tryParse(rawRate);
      }

      final notes = parts.length > 2 ? parts[2].trim() : '';
      final planLabel = parts.length > 3 ? parts[3].trim() : '';

      await saveRate(CustomerRate(
        customerName: name,
        overrideMonthlyRate: rate,
        notes: notes,
        ratePlanLabel: planLabel,
      ));
      count++;
    }
    return count;
  }

  static List<String> _splitCsv(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (final ch in line.split('')) {
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    result.add(buffer.toString());
    return result;
  }
}
