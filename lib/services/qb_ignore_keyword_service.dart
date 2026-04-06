// QB Ignore Keyword Service
// Manages the list of keywords used to skip QB Sales CSV lines during import.
// A line is skipped if its Item/SKU column (Column P) contains any keyword
// (case-insensitive substring match).
//
// Default keywords pre-loaded on first install:
//   Credit Card, BlueArrow Fuel, Predictive Coach, Shipping, FedEx,
//   Fleetio, Rosco, Xtract, Integration, TopFly, LifeSaver
//
// Also stores the "New Activations ignore text" — the memo/description substring
// used to skip prorated first-month lines from Column L of the QB CSV.
// Default: "- New Activations"  (configurable via Settings → QB Filters)

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/qb_ignore_keyword.dart';

class QbIgnoreKeywordService {
  static const _boxName = 'qb_ignore_keywords';
  static Box<QbIgnoreKeyword>? _box;

  // ── New-Activations ignore text (Column L / Memo) ──────────────────────────
  static const String defaultNewActivationsText = '- New Activations';
  static const String _prefKeyNewActivations = 'qb_new_activations_ignore_text';
  static String _newActivationsText = defaultNewActivationsText;

  static const List<String> defaultKeywords = [
    'Credit Card',
    'BlueArrow Fuel',
    'Predictive Coach',
    'Shipping',
    'FedEx',
    'Fleetio',
    'Rosco',
    'Xtract',
    'Integration',
    'TopFly',
    'LifeSaver',
  ];

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(6)) {
      Hive.registerAdapter(QbIgnoreKeywordAdapter());
    }
    _box = await Hive.openBox<QbIgnoreKeyword>(_boxName);

    // Seed defaults on first install
    if (_box!.isEmpty) {
      await _seedDefaults();
    }

    // Load persisted new-activations ignore text
    final prefs = await SharedPreferences.getInstance();
    _newActivationsText =
        prefs.getString(_prefKeyNewActivations) ?? defaultNewActivationsText;
  }

  // ── New-Activations ignore text accessors ─────────────────────────────────

  /// The current memo/description substring used to skip first-month lines.
  static String get newActivationsIgnoreText => _newActivationsText;

  /// Persist a new value (empty string = disable this filter entirely).
  static Future<void> setNewActivationsIgnoreText(String text) async {
    _newActivationsText = text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyNewActivations, text);
    if (kDebugMode) {
      debugPrint('[QbIgnoreKeywordService] newActivationsIgnoreText = "$text"');
    }
  }

  /// Reset the new-activations ignore text to the factory default.
  static Future<void> resetNewActivationsIgnoreText() async {
    await setNewActivationsIgnoreText(defaultNewActivationsText);
  }

  static Future<void> _seedDefaults() async {
    for (final kw in defaultKeywords) {
      await _box!.add(QbIgnoreKeyword(keyword: kw, isDefault: true));
    }
    if (kDebugMode) {
      debugPrint(
          '[QbIgnoreKeywordService] Seeded ${defaultKeywords.length} default keywords');
    }
  }

  // ── Box accessor — auto-reopens if closed (web hot-reload / session issue) ─

  static Box<QbIgnoreKeyword> get box {
    if (_box == null) throw StateError('QbIgnoreKeywordService not initialized');
    return _box!;
  }

  /// Ensures the box is open, reopening it if Hive closed it (can happen on
  /// web after certain navigation or session events).
  static Future<Box<QbIgnoreKeyword>> _ensureOpen() async {
    if (_box == null) throw StateError('QbIgnoreKeywordService not initialized');
    if (!_box!.isOpen) {
      if (kDebugMode) debugPrint('[QbIgnoreKeywordService] box was closed — reopening');
      _box = await Hive.openBox<QbIgnoreKeyword>(_boxName);
      if (_box!.isEmpty) await _seedDefaults();
    }
    return _box!;
  }

  // ── Public reopen helper (called from UI before mutations) ──────────────────

  /// Public wrapper — ensures box is open. Call before any write operation
  /// when there is any chance the box may have been closed (e.g. web reload).
  static Future<void> ensureOpen() async {
    await _ensureOpen();
  }

  /// Async variant of [getAll] — ensures box is open first, then returns list.
  static Future<List<QbIgnoreKeyword>> getAllAsync() async {
    await _ensureOpen();
    return getAll();
  }

  // ── Read operations (sync — safe on web since box stays open after init) ────

  static List<QbIgnoreKeyword> getAll() {
    if (_box == null || !_box!.isOpen) return [];
    final list = _box!.values.toList();
    list.sort(
        (a, b) => a.keyword.toLowerCase().compareTo(b.keyword.toLowerCase()));
    return list;
  }

  static List<String> getAllKeywords() =>
      getAll().map((k) => k.keyword).toList();

  /// Returns true if [item] matches any ignore keyword (case-insensitive).
  static bool shouldIgnore(String item) {
    if (_box == null || !_box!.isOpen) return false;
    final lower = item.toLowerCase();
    return _box!.values.any((k) => lower.contains(k.keyword.toLowerCase()));
  }

  // ── Write operations (async — ensure box is open first) ───────────────────

  static Future<QbIgnoreKeyword> add(String keyword) async {
    final b = await _ensureOpen();
    final kw = QbIgnoreKeyword(keyword: keyword.trim(), isDefault: false);
    await b.add(kw);
    return kw;
  }

  static Future<void> delete(QbIgnoreKeyword keyword) async {
    await _ensureOpen(); // ensure box is open so HiveObject.delete() works
    await keyword.delete();
  }

  static Future<void> resetToDefaults() async {
    final b = await _ensureOpen();
    await b.clear();
    await _seedDefaults();
  }

  /// For cloud sync — clear and restore from list of keyword strings.
  static Future<void> restoreFromList(List<Map<String, dynamic>> items) async {
    final b = await _ensureOpen();
    await b.clear();
    for (final item in items) {
      await b.add(QbIgnoreKeyword(
        keyword: item['keyword']?.toString() ?? '',
        isDefault: item['isDefault'] as bool? ?? false,
      ));
    }
  }
}
