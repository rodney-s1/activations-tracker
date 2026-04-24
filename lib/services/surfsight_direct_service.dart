// Surfsight Direct Service
// Stores a mapping of customer org name → active device count for
// Surfsight Direct cameras (billed in QB under "Surfsight Service:SS Service Fee"
// but not visible in MyAdmin).
//
// Persistence: SharedPreferences, key "surfsight_direct_v1"
// Format: JSON-encoded List<Map> [{name, count}]

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SurfsightDirectEntry {
  final String orgName;
  final int count;

  const SurfsightDirectEntry({required this.orgName, required this.count});

  Map<String, dynamic> toJson() => {'name': orgName, 'count': count};

  factory SurfsightDirectEntry.fromJson(Map<String, dynamic> j) =>
      SurfsightDirectEntry(
        orgName: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
      );

  SurfsightDirectEntry copyWith({String? orgName, int? count}) =>
      SurfsightDirectEntry(
        orgName: orgName ?? this.orgName,
        count: count ?? this.count,
      );
}

class SurfsightDirectService {
  static const _kKey = 'surfsight_direct_v1';

  List<SurfsightDirectEntry> _entries = [];

  List<SurfsightDirectEntry> get entries => List.unmodifiable(_entries);

  /// Load persisted entries from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) {
      _entries = [];
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _entries = list
          .map((e) =>
              SurfsightDirectEntry.fromJson(e as Map<String, dynamic>))
          .where((e) => e.orgName.isNotEmpty && e.count > 0)
          .toList();
    } catch (_) {
      _entries = [];
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kKey, jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  /// Add or update an entry. If an entry with the same normKey already exists
  /// it is replaced; otherwise a new row is appended.
  Future<void> upsert(SurfsightDirectEntry entry) async {
    final key = _normKey(entry.orgName);
    final idx = _entries.indexWhere((e) => _normKey(e.orgName) == key);
    if (idx >= 0) {
      _entries[idx] = entry;
    } else {
      _entries.add(entry);
    }
    _entries.sort((a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()));
    await _save();
  }

  Future<void> remove(String orgName) async {
    final key = _normKey(orgName);
    _entries.removeWhere((e) => _normKey(e.orgName) == key);
    await _save();
  }

  /// Bulk-import: merges new entries into existing list.
  /// For duplicate org names (by normKey) the imported count wins.
  Future<void> bulkImport(List<SurfsightDirectEntry> incoming) async {
    for (final e in incoming) {
      await upsert(e);
    }
  }

  /// Returns the Surfsight Direct count for a QB customer name.
  /// Uses the same normKey normalization as the main audit so fuzzy matching
  /// works even when the Surfsight portal org name differs slightly.
  int countFor(String customerName) {
    final key = _normKey(customerName);
    int total = 0;
    for (final e in _entries) {
      if (_normKey(e.orgName) == key) {
        total += e.count;
      }
    }
    return total;
  }

  /// Total active Surfsight Direct devices across all customers.
  int get grandTotal => _entries.fold(0, (s, e) => s + e.count);
}

// ── Normalisation (mirrors _normKey in qb_invoice_screen.dart) ───────────────

String _normKey(String name) {
  String s = name;
  // Strip curly-brace suffix e.g. " {Cameras}"
  s = s.replaceAll(RegExp(r'\s*\{[^}]*\}'), '').trim();
  // Strip parenthetical suffix e.g. " (City State)"
  s = s.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
  // Strip colon parent prefix "Parent:Child" → "Child"
  if (!s.contains(' | ')) {
    final colonIdx = s.indexOf(':');
    if (colonIdx > 0 && colonIdx < s.length - 1) {
      s = s.substring(colonIdx + 1).trim();
    }
  } else {
    // Pipe sub-customer: strip " ST - NNNN" state+store suffix
    s = s.replaceFirst(RegExp(r'\s+[A-Z]{2}\s+-\s+\d+$'), '');
    s = s.replaceFirst(RegExp(r'\s+-\s+\d+$'), '');
  }
  // Lowercase + collapse whitespace
  s = s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  // Normalise & ↔ and
  s = s.replaceAll(RegExp(r'\s*&\s*'), ' and ');
  // Strip punctuation
  s = s.replaceAll(RegExp(r"[,.'`]"), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  // Strip trailing legal suffixes
  s = s.replaceAll(
      RegExp(
          r'\s+\b(inc|llc|ltd|corp|co|company|group|enterprises|services|solutions|associates|consulting)\b\.?$'),
      '').trim();
  return s;
}
