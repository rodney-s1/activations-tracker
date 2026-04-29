// Fuel Alias Service
//
// Manages the user-editable mapping of BlueArrow Fuel CSV customer names
// → canonical QuickBooks customer names.
//
// The Fuel CSV often uses shortened, misspelled, or state-unqualified names
// that don't match the QB name.  This service lets the user maintain the
// mapping themselves without code changes.
//
// Storage: shared_preferences key 'fuel_aliases_v1' as a JSON object
//   { "fuel csv normkey": "qb normkey", ... }
//
// Defaults: the hardcoded list below is seeded on first launch but can be
// edited/deleted by the user.  They are stored as regular user entries so
// they can be overridden.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_sync_service.dart';

/// A single fuel alias entry (displayed in the UI).
class FuelAlias {
  /// The raw Fuel CSV name exactly as the user types it (display only).
  final String fuelName;

  /// The raw QB customer name exactly as the user types it (display only).
  final String qbName;

  /// Whether this entry came from the built-in default list.
  final bool isDefault;

  const FuelAlias({
    required this.fuelName,
    required this.qbName,
    this.isDefault = false,
  });

  FuelAlias copyWith({String? fuelName, String? qbName, bool? isDefault}) =>
      FuelAlias(
        fuelName: fuelName ?? this.fuelName,
        qbName: qbName ?? this.qbName,
        isDefault: isDefault ?? this.isDefault,
      );

  Map<String, dynamic> toJson() => {
        'fuelName': fuelName,
        'qbName': qbName,
        'isDefault': isDefault,
      };

  factory FuelAlias.fromJson(Map<String, dynamic> j) => FuelAlias(
        fuelName: j['fuelName']?.toString() ?? '',
        qbName: j['qbName']?.toString() ?? '',
        isDefault: j['isDefault'] as bool? ?? false,
      );
}

class FuelAliasService {
  FuelAliasService._();
  static final FuelAliasService instance = FuelAliasService._();

  static const String _prefKey = 'fuel_aliases_v1';

  // In-memory list, sorted by fuelName
  List<FuelAlias> _aliases = [];

  // ── Default seed list ────────────────────────────────────────────────────
  // These are the hard-coded defaults that used to live in _fuelAliases.
  // They are seeded on first launch and can be edited/deleted by the user.
  static const List<FuelAlias> defaultAliases = [
    FuelAlias(fuelName: 'Charleston County',          qbName: 'Charleston County SC',               isDefault: true),
    FuelAlias(fuelName: 'City of Lenoir',             qbName: 'City of Lenoir NC',                  isDefault: true),
    FuelAlias(fuelName: 'Dare County',                qbName: 'Dare County EMS NC',                 isDefault: true),
    FuelAlias(fuelName: 'Dare County EMS',            qbName: 'Dare County EMS NC',                 isDefault: true),
    FuelAlias(fuelName: 'Randolph County EMS',        qbName: 'Randolph County EMS NC',             isDefault: true),
    FuelAlias(fuelName: 'Wake Med EMS',               qbName: 'Wake Med EMS NC',                    isDefault: true),
    FuelAlias(fuelName: 'Town of Apex',               qbName: 'Town of Apex PW NC',                 isDefault: true),
    FuelAlias(fuelName: 'Town of Apex PW',            qbName: 'Town of Apex PW NC',                 isDefault: true),
    FuelAlias(fuelName: 'Town of Fuquay-Varina',      qbName: 'Town of Fuquay Varina - PW',         isDefault: true),
    FuelAlias(fuelName: 'Town of Fuquay Varina',      qbName: 'Town of Fuquay Varina - PW',         isDefault: true),
    FuelAlias(fuelName: 'Fuquay Varina',              qbName: 'Town of Fuquay Varina - PW',         isDefault: true),
    FuelAlias(fuelName: 'Washington County',          qbName: 'Washington County NC',               isDefault: true),
    FuelAlias(fuelName: 'Gemma',                      qbName: 'Gemma PA',                           isDefault: true),
    FuelAlias(fuelName: 'Gemma Services',             qbName: 'Gemma PA',                           isDefault: true),
    FuelAlias(fuelName: 'Stockbridge Area Emergency', qbName: 'Stockbridge Area Emergency MI',      isDefault: true),
    FuelAlias(fuelName: 'CMJ',                        qbName: 'CMJ VA',                             isDefault: true),
    FuelAlias(fuelName: 'CMJ Technologies',           qbName: 'CMJ VA',                             isDefault: true),
    FuelAlias(fuelName: 'Advance Industrial Group',   qbName: 'Advanced Industrial Group',          isDefault: true),
    FuelAlias(fuelName: 'Allina',                     qbName: 'Allina Health Systems',              isDefault: true),
  ];

  // ── Init ─────────────────────────────────────────────────────────────────

  /// Load persisted aliases from shared_preferences.
  /// Seeds defaults on first launch.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null) {
      // First launch — seed defaults
      _aliases = List<FuelAlias>.from(defaultAliases);
      await _persist(prefs);
      if (kDebugMode) debugPrint('[FuelAliasService] Seeded ${_aliases.length} default aliases');
    } else {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _aliases = list
            .map((e) => FuelAlias.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        if (kDebugMode) debugPrint('[FuelAliasService] Parse error, reseeding: $e');
        _aliases = List<FuelAlias>.from(defaultAliases);
        await _persist(prefs);
      }
    }
    _sort();
    if (kDebugMode) debugPrint('[FuelAliasService] Loaded ${_aliases.length} aliases');
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  List<FuelAlias> getAll() => List.unmodifiable(_aliases);

  /// Build the normKey → normKey lookup map used by BlueArrowFuelService.
  /// Keys and values are both passed through [_norm] so the matching is
  /// tolerant of capitalisation and punctuation differences.
  Map<String, String> buildLookup() {
    final map = <String, String>{};
    for (final a in _aliases) {
      if (a.fuelName.trim().isEmpty || a.qbName.trim().isEmpty) continue;
      map[_norm(a.fuelName)] = _norm(a.qbName);
    }
    return map;
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  Future<void> add(String fuelName, String qbName) async {
    _aliases.add(FuelAlias(fuelName: fuelName.trim(), qbName: qbName.trim()));
    _sort();
    await _save();
  }

  Future<void> update(int index, String fuelName, String qbName) async {
    if (index < 0 || index >= _aliases.length) return;
    _aliases[index] = _aliases[index].copyWith(
      fuelName: fuelName.trim(),
      qbName: qbName.trim(),
      isDefault: false, // user-edited entries are no longer "default"
    );
    _sort();
    await _save();
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= _aliases.length) return;
    _aliases.removeAt(index);
    await _save();
  }

  Future<void> resetToDefaults() async {
    _aliases = List<FuelAlias>.from(defaultAliases);
    _sort();
    await _save();
  }

  // ── Cloud sync ────────────────────────────────────────────────────────────

  /// Serialize for cloud push — returns a list of plain JSON maps.
  List<Map<String, dynamic>> toCloudList() =>
      _aliases.map((a) => a.toJson()).toList();

  /// Restore from cloud pull — replaces in-memory list AND persists locally.
  /// Only applied when the cloud list is non-empty (same safety rule as other nodes).
  Future<void> restoreFromCloud(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    _aliases = items
        .map((e) => FuelAlias.fromJson(e))
        .where((a) => a.fuelName.isNotEmpty && a.qbName.isNotEmpty)
        .toList();
    _sort();
    await _save();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
    // Mirror every write to the cloud immediately so all users stay in sync.
    CloudSyncService.pushSilent();
  }

  Future<void> _persist(SharedPreferences prefs) async {
    final encoded = jsonEncode(_aliases.map((a) => a.toJson()).toList());
    await prefs.setString(_prefKey, encoded);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _sort() {
    _aliases.sort((a, b) =>
        a.fuelName.toLowerCase().compareTo(b.fuelName.toLowerCase()));
  }

  /// Lightweight normalisation used for building the lookup map.
  /// Matches the fuel service _normKey: lowercase, strip non-alphanum, collapse spaces,
  /// strip common suffixes.
  static String _norm(String s) {
    s = s.toLowerCase().replaceAll('&', 'and');
    s = s.replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    const suffixes = [
      'llc', 'inc', 'ltd', 'corp', 'co', 'company', 'companies', 'group',
      'enterprises', 'enterprise', 'holdings', 'services', 'service',
      'solutions', 'partners', 'partnership', 'plc', 'lp', 'llp', 'pllc',
      'wholesale', 'distribution', 'logistics', 'transport', 'transportation',
      'technologies', 'technology', 'tech', 'industries', 'industry',
      'international', 'national', 'systems', 'associates', 'consulting',
    ];
    bool changed = true;
    while (changed) {
      changed = false;
      for (final suf in suffixes) {
        if (s.endsWith(' $suf') && s.length > suf.length + 1) {
          s = s.substring(0, s.length - suf.length - 1).trim();
          changed = true;
        }
      }
    }
    return s;
  }
}
