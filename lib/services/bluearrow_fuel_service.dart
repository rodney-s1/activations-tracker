// BlueArrow Fuel Service
//
// Parses the monthly "Fuel Card Count Changes" CSV exported from BlueArrow and
// builds a per-QB-customer fuel card count map for use in the QB Verify audit.

import 'fuel_alias_service.dart';
//
// CSV structure (3 sections, each with its own header row):
//
//   Resellers
//   Account, Previous Count, Current Count, Net Change, Reseller, Order Now
//   <sub-customer>, ..., <reseller name>, 0
//   ...
//
//   "Direct Customers"
//   Account, Previous Count, Current Count, Net Change, Reseller, Order Now
//   <QB customer name>, ..., N/A, 0
//   ...
//
//   "Order Now"
//   Account, Previous Count, Current Count, Net Change, Reseller, Order Now
//   <sub-customer>, ..., <reseller>, 1
//   ...  ← IGNORED entirely
//
// Mapping rules:
//   • Resellers section  — the "Account" sub-customer is billed through the
//     "Reseller" column value; we credit the count to the RESELLER name
//     (which is the QB customer name on the invoice).
//   • Direct Customers   — "Account" IS the QB customer name.
//   • Order Now          — skipped; column F (Order Now) = 1.
//   • Rows where Current Count = 0 are still included (may still appear on
//     the QB invoice as a $0 line); filter in the UI if desired.
//
// The service holds the parsed data in memory only (session-scoped, like the
// MyAdmin and QB CSVs).  The calling screen is responsible for persisting the
// raw file content if desired.

/// A single sub-account row under a reseller (column A = account name,
/// column C = current count).
class FuelSubAccount {
  final String accountName;
  final int currentCount;
  const FuelSubAccount({required this.accountName, required this.currentCount});
}

class BlueArrowFuelEntry {
  /// QB customer name (reseller name for reseller sub-customers; direct
  /// customer name for direct customers).
  final String qbCustomerName;

  /// Current fuel card count from the CSV.
  final int currentCount;

  const BlueArrowFuelEntry({
    required this.qbCustomerName,
    required this.currentCount,
  });
}

// ── Parse result ──────────────────────────────────────────────────────────────

class BlueArrowParseResult {
  /// All entries (resellers + direct), Order Now excluded.
  final List<BlueArrowFuelEntry> entries;

  /// Human-readable summary for the snackbar after import.
  final int totalCustomers;
  final int totalCards;

  /// Per-reseller sub-account breakdown: normKey(resellerName) → list of sub-accounts.
  /// Empty for direct customers (they have no sub-accounts).
  final Map<String, List<FuelSubAccount>> subAccounts;

  const BlueArrowParseResult({
    required this.entries,
    required this.totalCustomers,
    required this.totalCards,
    this.subAccounts = const {},
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class BlueArrowFuelService {
  // Singleton
  static final BlueArrowFuelService _instance = BlueArrowFuelService._();
  factory BlueArrowFuelService() => _instance;
  BlueArrowFuelService._();

  // In-memory map: normKey → totalCurrentCount
  // Built when a CSV is imported; cleared when a new CSV replaces it.
  final Map<String, int> _counts = {};

  // normKey → original proper-cased QB customer name (first seen wins).
  // Used so fuel-only customers display a readable name in the audit
  // even when they have no MyAdmin devices and no QB invoice lines.
  final Map<String, String> _displayNames = {};

  // normKey(resellerName) → list of FuelSubAccount rows from the Fuel CSV.
  // Only populated for reseller entries; direct customers have no sub-accounts.
  final Map<String, List<FuelSubAccount>> _subAccounts = {};

  bool get hasData => _counts.isNotEmpty;

  // ── Alias lookup (delegates to FuelAliasService) ──────────────────────────
  // Aliases are now user-managed via Settings → Fuel Aliases.
  // FuelAliasService.instance.buildLookup() returns the current normKey map.
  Map<String, String>? _aliasCache;

  /// Apply the user-managed fuel alias table.
  /// Cache is rebuilt each import so changes take effect on next re-import.
  String _applyFuelAlias(String normKey) =>
      (_aliasCache ?? const {})[normKey] ?? normKey;

  // ── Import ────────────────────────────────────────────────────────────────

  /// Parse [csvContent] and replace the current in-memory data.
  /// Returns a summary of what was loaded.
  BlueArrowParseResult import(String csvContent) {
    _counts.clear();
    _subAccounts.clear();
    // Snapshot alias lookup at import time
    _aliasCache = FuelAliasService.instance.buildLookup();

    final result = parseBlueArrowFuelCsv(csvContent);

    // Accumulate into the internal map (multiple rows may share the same
    // QB customer name, e.g. a reseller appears several times).
    for (final e in result.entries) {
      // Apply alias AFTER normKey so short fuel-CSV names map to the same
      // key as the full state-qualified MyAdmin/QB name.
      final key = _applyFuelAlias(_normKey(e.qbCustomerName));
      _counts[key] = (_counts[key] ?? 0) + e.currentCount;
      // Keep the first (best-cased) name seen for each key
      _displayNames.putIfAbsent(key, () => e.qbCustomerName);
    }

    // Store sub-account breakdowns (also apply alias to the normKey)
    result.subAccounts.forEach((normKey, accounts) {
      final aliasedKey = _applyFuelAlias(normKey);
      _subAccounts[aliasedKey] = accounts;
    });

    return result;
  }

  /// Clear all loaded data (e.g. when the user removes the file).
  void clear() {
    _counts.clear();
    _displayNames.clear();
    _subAccounts.clear();
  }

  // ── Lookup ────────────────────────────────────────────────────────────────

  /// Returns the total fuel card count for a given QB customer name.
  /// Uses the same multi-pass suffix-stripping normalization as the rest of
  /// the audit so "Combs Produce Wholesale Co." matches "Combs Produce".
  int countFor(String qbCustomerName) {
    final key = _applyFuelAlias(_normKey(qbCustomerName));
    return _counts[key] ?? 0;
  }

  /// Returns the sub-account breakdown list for a given QB customer (reseller) name.
  /// Returns an empty list for direct customers or unknown customers.
  List<FuelSubAccount> subAccountsFor(String qbCustomerName) {
    final key = _applyFuelAlias(_normKey(qbCustomerName));
    return _subAccounts[key] ?? const [];
  }

  /// Grand total across all customers (for the import snackbar).
  int get grandTotal => _counts.values.fold(0, (s, v) => s + v);

  /// All normalised keys that have a non-zero count.
  /// Used to seed allKeys in _buildSummaries.
  List<String> get customerKeys => _counts.keys.toList()..sort();

  /// Returns the original proper-cased QB customer name for a given normKey,
  /// or null if not found.  Used to populate displayName for fuel-only rows.
  String? displayNameFor(String normKey) => _displayNames[normKey];
}

// ── CSV Parser (pure function, no state) ─────────────────────────────────────

BlueArrowParseResult parseBlueArrowFuelCsv(String csvContent) {
  final lines = csvContent.split(RegExp(r'\r?\n'));

  // We accumulate reseller totals because the same reseller can appear on
  // many rows (one per sub-customer).
  final Map<String, int> resellerTotals  = {};
  final Map<String, int> directTotals    = {};

  // Per-reseller sub-account list: normKey(reseller) → list of rows
  final Map<String, List<FuelSubAccount>> subAccountMap = {};

  // Section tracking
  // 0 = before any known section header
  // 1 = Resellers
  // 2 = Direct Customers
  // 3 = Order Now  (ignored)
  int section = 0;

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final lower = line.toLowerCase().replaceAll('"', '');

    // ── Section header detection ───────────────────────────────────────────
    if (lower.startsWith('resellers')) {
      section = 1;
      continue;
    }
    if (lower.contains('direct customers')) {
      section = 2;
      continue;
    }
    if (lower.contains('order now') && !lower.contains(',')) {
      // Section header line (not a data row — data rows always have commas)
      section = 3;
      continue;
    }

    // Skip the column header row that appears inside each section
    if (lower.startsWith('account,') || lower.startsWith('"account",')) {
      continue;
    }

    // Order Now section is entirely ignored
    if (section == 3) continue;
    if (section == 0) continue;

    // ── Parse CSV row ─────────────────────────────────────────────────────
    final cells = _splitCsvRow(line);
    if (cells.length < 6) continue;

    final account     = cells[0].trim();
    // cells[1] = Previous Count (ignored)
    final currentStr  = cells[2].trim();
    // cells[3] = Net Change (ignored)
    final reseller    = cells[4].trim();
    final orderNowStr = cells[5].trim();

    if (account.isEmpty) continue;

    // Double-check Order Now flag even outside section 3
    final orderNow = int.tryParse(orderNowStr) ?? 0;
    if (orderNow == 1) continue;

    final currentCount = int.tryParse(currentStr) ?? 0;

    if (section == 1) {
      // Resellers section: credit the count to the RESELLER name
      if (reseller.isEmpty || reseller == 'N/A') continue;
      resellerTotals[reseller] =
          (resellerTotals[reseller] ?? 0) + currentCount;

      // Also store sub-account detail under the reseller's norm key
      final rKey = _normKey(reseller);
      subAccountMap.putIfAbsent(rKey, () => []);
      subAccountMap[rKey]!.add(FuelSubAccount(
        accountName: account,
        currentCount: currentCount,
      ));
    } else if (section == 2) {
      // Direct Customers section: credit the count to the ACCOUNT name
      directTotals[account] =
          (directTotals[account] ?? 0) + currentCount;
    }
  }

  // Build the flat entry list
  final List<BlueArrowFuelEntry> entries = [];

  resellerTotals.forEach((name, count) {
    entries.add(BlueArrowFuelEntry(qbCustomerName: name, currentCount: count));
  });
  directTotals.forEach((name, count) {
    entries.add(BlueArrowFuelEntry(qbCustomerName: name, currentCount: count));
  });

  // Sort for deterministic output
  entries.sort((a, b) => a.qbCustomerName.compareTo(b.qbCustomerName));

  // Sort sub-account lists by account name
  subAccountMap.forEach((key, list) {
    list.sort((a, b) => a.accountName.compareTo(b.accountName));
  });

  final totalCards = entries.fold(0, (s, e) => s + e.currentCount);

  return BlueArrowParseResult(
    entries: entries,
    totalCustomers: entries.length,
    totalCards: totalCards,
    subAccounts: subAccountMap,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Split a single CSV row respecting double-quoted fields.
List<String> _splitCsvRow(String line) {
  final cells = <String>[];
  final buf = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  return cells;
}

/// Multi-pass suffix-stripping normaliser — identical logic to the one used
/// in the QB audit screen so name matching is consistent.
String _normKey(String name) {
  var s = name.trim();

  // Strip curly-brace device-type suffixes  e.g. "Foo {Cameras}"
  s = s.replaceAll(RegExp(r'\{[^}]*\}'), '').trim();

  // Strip parenthetical suffixes  e.g. "Foo (Bar, NC)"
  s = s.replaceAll(RegExp(r'\([^)]*\)'), '').trim();

  // Handle QB pipe-parent format  "Parent | Location ST - 0001"
  if (s.contains('|')) {
    s = s.split('|').last.trim();
    s = s.replaceAll(RegExp(r'[A-Z]{2}\s*-\s*\d+$'), '').trim();
  } else if (s.contains(':')) {
    // Handle "Parent:Child" — use the child segment
    s = s.split(':').last.trim();
  }

  s = s.toLowerCase();
  s = s.replaceAll('&', 'and');
  // Replace hyphens/en-dashes with a space so "C-Phase" → "c phase"
  // (mirrors qb_invoice_screen.dart which keeps hyphens as word separators)
  s = s.replaceAll(RegExp(r'[-–—]'), ' ');
  // Remove remaining punctuation except spaces
  s = s.replaceAll(RegExp(r"[^a-z0-9\s]"), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // Multi-pass suffix stripping
  const suffixes = {
    'inc', 'llc', 'ltd', 'corp', 'co', 'company', 'companies', 'group', 'enterprises',
    'enterprise', 'holdings', 'international', 'national', 'systems',
    'technologies', 'technology', 'tech', 'industries', 'industry',
    'partners', 'partnership', 'solutions', 'associates', 'consulting',
    'services', 'service', 'plc', 'lp', 'llp', 'pllc', 'lllp',
    'wholesale', 'distribution', 'logistics', 'transport', 'transportation',
  };

  bool changed = true;
  while (changed) {
    changed = false;
    for (final suffix in suffixes) {
      if (s.endsWith(' $suffix') && s.length > suffix.length + 1) {
        s = s.substring(0, s.length - suffix.length - 1).trim();
        changed = true;
      }
    }
  }

  return s;
}
