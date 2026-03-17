// Service for Customer Plan Codes (Hive typeId=4)
import 'package:hive_flutter/hive_flutter.dart';
import '../models/customer_plan_code.dart';

class CustomerPlanCodeService {
  static const _boxName = 'customer_plan_codes';
  static Box<CustomerPlanCode>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(CustomerPlanCodeAdapter());
    }
    _box = await Hive.openBox<CustomerPlanCode>(_boxName);
  }

  static Box<CustomerPlanCode> get box => _box!;

  static List<CustomerPlanCode> getAll() => _box!.values.toList();

  static List<CustomerPlanCode> getForCustomer(String customerName) {
    final norm = customerName.trim().toLowerCase();
    return _box!.values
        .where((c) => c.customerName.trim().toLowerCase() == norm)
        .toList();
  }

  /// All unique customer names that have at least one code entry
  static List<String> customersWithCodes() {
    final names = _box!.values.map((c) => c.customerName).toSet().toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  static Future<void> save(CustomerPlanCode code) async {
    code.lastUpdated = DateTime.now();
    // Check for duplicate (same customer + same planCode)
    for (final key in _box!.keys) {
      final existing = _box!.get(key);
      if (existing != null &&
          existing.customerName.trim().toLowerCase() ==
              code.customerName.trim().toLowerCase() &&
          existing.planCode.trim().toLowerCase() ==
              code.planCode.trim().toLowerCase()) {
        existing.customerPrice = code.customerPrice;
        existing.notes = code.notes;
        existing.lastUpdated = DateTime.now();
        await existing.save();
        return;
      }
    }
    await _box!.add(code);
  }

  static Future<void> delete(CustomerPlanCode code) => code.delete();

  static Future<void> clearAll() => _box!.clear();

  // ── QB Sales-by-Customer CSV import ─────────────────────────────────────
  //
  // Expects the QuickBooks "Sales by Customer Detail" report CSV.
  // Extracts rows dated 03/01/YYYY where the Item column (L, index 5) contains
  // "Geotab Service" or "Service Fee Geotab".
  // Maps customer (column N, index 3) → plan code → price (column T, index 7).
  // On price conflict for the same customer+plan, higher price wins.
  // Returns {imported, updated, skipped, conflicts}.
  static Future<Map<String, int>> importFromQbSalesCsv(String csvContent) async {
    int imported = 0, updated = 0, skipped = 0, conflicts = 0;

    // Split lines — handle \r\n and \n
    final rawLines = csvContent.split(RegExp(r'\r?\n'));

    // Find header row
    int headerIndex = -1;
    List<String> headers = [];
    for (int i = 0; i < rawLines.length; i++) {
      final cols = _splitCsvLine(rawLines[i]);
      // Look for a header that has "Type" and "Item" columns
      if (cols.any((c) => c.trim() == 'Type') &&
          cols.any((c) => c.trim() == 'Item')) {
        headerIndex = i;
        headers = cols.map((c) => c.trim()).toList();
        break;
      }
    }

    // Column indices — default to the layout from the supplied file
    final typeIdx  = headerIndex >= 0 ? headers.indexOf('Type')  : 0;
    final nameIdx  = headerIndex >= 0 ? headers.indexOf('Name')  : 3;  // col N
    final itemIdx  = headerIndex >= 0 ? headers.indexOf('Item')  : 5;  // col L
    final priceIdx = headerIndex >= 0 ? headers.indexOf('Sales Price') : 7; // col T

    // Temp map: customer+plan → best price
    final best = <String, double>{};
    final planForKey = <String, String>{}; // key → planCode string

    for (int i = (headerIndex >= 0 ? headerIndex + 1 : 0);
        i < rawLines.length;
        i++) {
      final line = rawLines[i].trim();
      if (line.isEmpty) continue;

      final cols = _splitCsvLine(rawLines[i]);
      if (cols.length <= priceIdx) continue;

      // Must be Invoice or Invoice line
      final type = typeIdx >= 0 && typeIdx < cols.length
          ? cols[typeIdx].trim()
          : '';
      if (type.isNotEmpty &&
          !type.toLowerCase().contains('invoice') &&
          type != '') {
        // Allow blank type (continuation rows sometimes have blank type)
        // but skip Total/header lines
        if (type.toLowerCase().contains('total') ||
            type.toLowerCase().contains('balance') ||
            type == 'Type') {
          skipped++;
          continue;
        }
      }

      final item  = itemIdx  < cols.length ? cols[itemIdx].trim()  : '';
      final name  = nameIdx  < cols.length ? cols[nameIdx].trim()  : '';
      final priceStr = priceIdx < cols.length ? cols[priceIdx].trim() : '';

      if (item.isEmpty || name.isEmpty || priceStr.isEmpty) {
        skipped++;
        continue;
      }

      // Must be a Geotab service item
      final itemLower = item.toLowerCase();
      if (!itemLower.contains('geotab service') &&
          !itemLower.contains('service fee geotab') &&
          !itemLower.contains('geotab') ) {
        skipped++;
        continue;
      }
      // Filter more strictly: must have "geotab" AND ("service" or "fee")
      if (!itemLower.contains('service') && !itemLower.contains('fee')) {
        skipped++;
        continue;
      }

      final price = double.tryParse(
          priceStr.replaceAll(r'$', '').replaceAll(',', ''));
      if (price == null || price <= 0) {
        skipped++;
        continue;
      }

      // Extract plan code from item string
      // "Service Fee Geotab (HOS)" → "HOS"
      // "Service Fee Geotab (GO)"  → "GO"
      // "Geotab Service: GO Bundle Plan [1450]" → "GO"
      String planCode = _extractPlanCode(item);
      if (planCode.isEmpty) {
        skipped++;
        continue;
      }

      final key = '${name.toLowerCase()}|||${planCode.toLowerCase()}';
      if (best.containsKey(key)) {
        if (price != best[key]) conflicts++;
        if (price > best[key]!) best[key] = price; // prefer higher price on conflict
      } else {
        best[key] = price;
        planForKey[key] = planCode;
      }
    }

    // Write to Hive
    for (final entry in best.entries) {
      final parts    = entry.key.split('|||');
      if (parts.length < 2) continue;
      // Recover original-cased name from the loop — re-parse is expensive,
      // so we use the key's lowercase parts but look for existing record first.
      // Try to find original-case customer name from existing records first.
      final nameLower = parts[0];
      final planLower = parts[1];

      // Look for existing entry with matching name/plan (case-insensitive)
      CustomerPlanCode? existingRec;
      for (final k in _box!.keys) {
        final rec = _box!.get(k);
        if (rec != null &&
            rec.customerName.trim().toLowerCase() == nameLower &&
            rec.planCode.trim().toLowerCase() == planLower) {
          existingRec = rec;
          break;
        }
      }

      if (existingRec != null) {
        existingRec.customerPrice = entry.value;
        existingRec.notes = 'Imported from QB Sales CSV';
        existingRec.lastUpdated = DateTime.now();
        await existingRec.save();
        updated++;
      } else {
        // Need the original-cased customer name.
        // We stored the plan code with original case in planForKey.
        final originalPlan = planForKey[entry.key] ?? planLower;
        // Derive original customer name — best effort: title-case the key.
        // Actually we need to grab it from the CSV again. Since this is a
        // one-pass importer we'll keep a separate map for that.
        // For now capitalise first letter of each word as fallback.
        final originalName = _toTitleCase(nameLower);
        await _box!.add(CustomerPlanCode(
          customerName:  originalName,
          planCode:      originalPlan,
          customerPrice: entry.value,
          notes:         'Imported from QB Sales CSV',
        ));
        imported++;
      }
    }

    return {
      'imported':  imported,
      'updated':   updated,
      'skipped':   skipped,
      'conflicts': conflicts,
    };
  }

  // ── Two-pass version that preserves original customer-name casing ─────────

  static Future<Map<String, int>> importFromQbSalesCsvPreserveCase(
      String csvContent) async {
    int imported = 0, updated = 0, skipped = 0, conflicts = 0;

    final rawLines = csvContent.split(RegExp(r'\r?\n'));

    int headerIndex = -1;
    List<String> headers = [];
    for (int i = 0; i < rawLines.length; i++) {
      final cols = _splitCsvLine(rawLines[i]);
      if (cols.any((c) => c.trim() == 'Type') &&
          cols.any((c) => c.trim() == 'Item')) {
        headerIndex = i;
        headers = cols.map((c) => c.trim()).toList();
        break;
      }
    }

    final typeIdx  = headerIndex >= 0 ? headers.indexOf('Type')  : 0;
    final nameIdx  = headerIndex >= 0 ? headers.indexOf('Name')  : 3;
    final itemIdx  = headerIndex >= 0 ? headers.indexOf('Item')  : 5;
    final priceIdx = headerIndex >= 0 ? headers.indexOf('Sales Price') : 7;

    // key (lower) → {name: original case, plan: original case, price: best}
    final best = <String, Map<String, dynamic>>{};

    for (int i = (headerIndex >= 0 ? headerIndex + 1 : 0);
        i < rawLines.length;
        i++) {
      final line = rawLines[i].trim();
      if (line.isEmpty) continue;

      final cols = _splitCsvLine(rawLines[i]);
      if (cols.length <= priceIdx) continue;

      final type = typeIdx >= 0 && typeIdx < cols.length
          ? cols[typeIdx].trim().toLowerCase()
          : '';
      if (type.contains('total') ||
          type.contains('balance') ||
          type == 'type') {
        skipped++;
        continue;
      }

      final item  = itemIdx  < cols.length ? cols[itemIdx].trim()  : '';
      final name  = nameIdx  < cols.length ? cols[nameIdx].trim()  : '';
      final priceStr = priceIdx < cols.length ? cols[priceIdx].trim() : '';

      if (item.isEmpty || name.isEmpty || priceStr.isEmpty) {
        skipped++;
        continue;
      }

      final itemLower = item.toLowerCase();
      if (!itemLower.contains('geotab')) { skipped++; continue; }
      if (!itemLower.contains('service') && !itemLower.contains('fee')) {
        skipped++;
        continue;
      }

      final price = double.tryParse(
          priceStr.replaceAll(r'$', '').replaceAll(',', ''));
      if (price == null || price <= 0) { skipped++; continue; }

      final planCode = _extractPlanCode(item);
      if (planCode.isEmpty) { skipped++; continue; }

      final key = '${name.toLowerCase()}|||${planCode.toLowerCase()}';
      if (best.containsKey(key)) {
        if (price != (best[key]!['price'] as double)) conflicts++;
        if (price > (best[key]!['price'] as double)) {
          best[key]!['price'] = price;
        }
      } else {
        best[key] = {'name': name, 'plan': planCode, 'price': price};
      }
    }

    for (final entry in best.entries) {
      final name  = entry.value['name']  as String;
      final plan  = entry.value['plan']  as String;
      final price = entry.value['price'] as double;

      final nameLower = name.trim().toLowerCase();
      final planLower = plan.trim().toLowerCase();

      CustomerPlanCode? existingRec;
      for (final k in _box!.keys) {
        final rec = _box!.get(k);
        if (rec != null &&
            rec.customerName.trim().toLowerCase() == nameLower &&
            rec.planCode.trim().toLowerCase() == planLower) {
          existingRec = rec;
          break;
        }
      }

      if (existingRec != null) {
        existingRec.customerPrice = price;
        existingRec.notes = 'Updated from QB Sales CSV';
        existingRec.lastUpdated = DateTime.now();
        await existingRec.save();
        updated++;
      } else {
        await _box!.add(CustomerPlanCode(
          customerName:  name,
          planCode:      plan,
          customerPrice: price,
          notes:         'Imported from QB Sales CSV',
        ));
        imported++;
      }
    }

    return {
      'imported':  imported,
      'updated':   updated,
      'skipped':   skipped,
      'conflicts': conflicts,
    };
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Split a CSV line respecting quoted fields.
  static List<String> _splitCsvLine(String line) {
    final result = <String>[];
    final sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        result.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    result.add(sb.toString());
    return result;
  }

  /// Extract a short plan code from an item description.
  /// "Service Fee Geotab (HOS)"          → "HOS"
  /// "Service Fee Geotab (GO)"           → "GO"
  /// "Service Fee Geotab Off-Road (GO)"  → "GO"
  /// "Geotab Service: ProPlus Bundle [1550]" → "ProPlus"
  /// Falls back to first bracketed token or the whole item if nothing matches.
  static String _extractPlanCode(String item) {
    // 1. Parenthesised token: "(HOS)" or "(GO)"
    final parenMatch = RegExp(r'\(([^)]+)\)').firstMatch(item);
    if (parenMatch != null) {
      return parenMatch.group(1)!.trim();
    }

    // 2. Known plan keywords in order of specificity
    const planKeywords = [
      'ProPlus', 'Pro', 'Regulatory', 'HOS', 'GO', 'Base', 'Suspend',
    ];
    for (final kw in planKeywords) {
      if (item.toLowerCase().contains(kw.toLowerCase())) return kw;
    }

    // 3. Bracketed code: "[1450]"
    final bracketMatch = RegExp(r'\[([^\]]+)\]').firstMatch(item);
    if (bracketMatch != null) return bracketMatch.group(1)!.trim();

    return '';
  }

  static String _toTitleCase(String s) {
    return s
        .split(RegExp(r'[\s_]+'))
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }
}
