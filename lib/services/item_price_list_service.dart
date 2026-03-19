// Service for the QuickBooks Item Price List (Hive typeId=8)
//
// Stores every row from the imported "Item Price List" CSV so that:
//   • The Pricing Overrides dialog can fuzzy-search items and auto-fill cost/price.
//   • The full list persists to cloud so all users share the same price book.
//
// CSV columns expected (same order as the exported QB list):
//   Item, Description, Cost, Price
// or any CSV whose first row contains those headers (case-insensitive).

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/qb_item.dart';

class ItemPriceListService {
  static const _boxName = 'qb_item_price_list';
  static Box<QbItem>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(8)) {
      Hive.registerAdapter(QbItemAdapter());
    }
    _box = await Hive.openBox<QbItem>(_boxName);
  }

  static Box<QbItem> get box => _box!;

  // ── Read ──────────────────────────────────────────────────────────────────

  static List<QbItem> getAll() {
    final list = _box!.values.toList();
    list.sort((a, b) => a.item.toLowerCase().compareTo(b.item.toLowerCase()));
    return list;
  }

  // ── Import from CSV bytes or string ──────────────────────────────────────

  /// Parse a QB "Item Price List" CSV and overwrite the local box.
  /// Returns the number of items imported.
  static Future<int> importFromCsv(String csvContent) async {
    // Strip BOM
    final content = csvContent.startsWith('\uFEFF')
        ? csvContent.substring(1)
        : csvContent;

    final lines = content
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) return 0;

    // ── Detect header row ────────────────────────────────────────────────
    // Accept either a header row OR assume: Item, Description, Cost, Price
    int itemIdx = 0, descIdx = 1, costIdx = 2, priceIdx = 3;
    int dataStart = 0;

    final firstCells = _splitCsvLine(lines[0]);
    final firstLower = firstCells.map((c) => c.toLowerCase()).toList();
    if (firstLower.any((c) => c.contains('item') || c.contains('description'))) {
      // First row is a header
      itemIdx  = firstLower.indexWhere((c) => c.contains('item'));
      descIdx  = firstLower.indexWhere((c) => c.contains('description') || c.contains('desc'));
      costIdx  = firstLower.indexWhere((c) => c.contains('cost'));
      priceIdx = firstLower.indexWhere((c) => c.contains('price') || c.contains('rate'));
      if (itemIdx  < 0) itemIdx  = 0;
      if (descIdx  < 0) descIdx  = 1;
      if (costIdx  < 0) costIdx  = 2;
      if (priceIdx < 0) priceIdx = 3;
      dataStart = 1;
    }

    // ── Parse rows ────────────────────────────────────────────────────────
    final items = <QbItem>[];
    for (int i = dataStart; i < lines.length; i++) {
      final cells = _splitCsvLine(lines[i]);
      if (cells.length <= itemIdx) continue;

      final itemName = _cell(cells, itemIdx);
      if (itemName.isEmpty) continue; // skip blank item rows
      // Skip subtotal/total rows
      if (itemName.toLowerCase().startsWith('total') ||
          itemName.toLowerCase().startsWith('subtotal')) continue;

      final desc  = _cell(cells, descIdx);
      final cost  = _parseMoney(_cell(cells, costIdx));
      final price = _parseMoney(_cell(cells, priceIdx));

      items.add(QbItem(item: itemName, description: desc, cost: cost, price: price));
    }

    if (items.isEmpty) return 0;

    // Overwrite the box
    await _box!.clear();
    for (final item in items) {
      await _box!.add(item);
    }

    if (kDebugMode) debugPrint('[ItemPriceList] Imported ${items.length} items');
    return items.length;
  }

  // ── Fuzzy search ──────────────────────────────────────────────────────────

  /// Search items by name and/or description.
  /// Returns up to [limit] results, sorted by relevance.
  static List<QbItem> search(String query, {int limit = 8}) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    final all = getAll();

    // Score each item: exact item match > item contains > description contains
    final scored = <MapEntry<QbItem, int>>[];
    for (final item in all) {
      final name = item.item.toLowerCase();
      final desc = item.description.toLowerCase();
      int score = 0;
      if (name == q)                    score = 100;
      else if (name.startsWith(q))      score = 80;
      else if (name.contains(q))        score = 60;
      else if (desc.contains(q))        score = 30;
      else {
        // word-by-word partial match
        final words = q.split(RegExp(r'\s+'));
        final matchCount = words.where((w) => name.contains(w) || desc.contains(w)).length;
        if (matchCount > 0) score = matchCount * 10;
      }
      if (score > 0) scored.add(MapEntry(item, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  // ── Cloud restore ─────────────────────────────────────────────────────────

  /// Restore items from a cloud payload list.
  static Future<void> restoreFromCloud(List<Map<String, dynamic>> list) async {
    await _box!.clear();
    for (final map in list) {
      await _box!.add(QbItem(
        item:        map['item']?.toString()        ?? '',
        description: map['description']?.toString() ?? '',
        cost:        (map['cost']  as num?)?.toDouble() ?? 0.0,
        price:       (map['price'] as num?)?.toDouble() ?? 0.0,
      ));
    }
  }

  // ── CSV helpers ───────────────────────────────────────────────────────────

  static String _cell(List<String> cells, int idx) =>
      idx < cells.length ? cells[idx].trim() : '';

  static double _parseMoney(String raw) {
    // Remove currency symbols, commas, spaces
    final cleaned = raw.replaceAll(RegExp(r'[\$,\s]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  /// Split a CSV line respecting quoted fields.
  static List<String> _splitCsvLine(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        fields.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    fields.add(buf.toString().trim());
    return fields;
  }
}
