// Plan Mapping Service (Hive typeId=9)
// Maps raw MyAdmin "Active Billing Plan" strings to short QB SKU labels.
// Used by QB Verify to show plan breakdowns on the billing compare card.
//
// Default mappings pre-seeded on first install cover the most common plans.
// Users can add, edit, or delete mappings in Settings → Plan Mapping.

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/plan_mapping.dart';

class PlanMappingService {
  static const _boxName = 'plan_mappings';
  static Box<PlanMapping>? _box;

  // ── Default mappings ──────────────────────────────────────────────────────
  // Each entry: [myAdminPlan (substring, case-insensitive), qbLabel]
  // Order matters — first match wins, so longer/more-specific strings come first.
  static const List<(String, String)> _defaults = [
    ('GO Expand',       'GO'),
    ('GO Plan',         'GO'),
    ('GO Basic',        'GO'),
    ('ProPlus',         'ProPlus'),
    ('Pro Plus',        'ProPlus'),
    ('Pro',             'Pro'),
    ('HOS',             'Reg/HOS'),
    ('Base',            'Base'),
    ('Regulatory',      'Reg/HOS'),
    ('Predictive',      'Coach'),
    ('Suspend',         'Suspend'),
    ('Surfsight',       'Surfsight'),
    ('Go Focus Plus',   'Go Focus Plus'),
    ('Go Focus',        'Go Focus'),
    ('Smarter AI',      'Smarter AI'),
    ('Hanover',         'Hanover'),
  ];

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(9)) {
      Hive.registerAdapter(PlanMappingAdapter());
    }
    _box = await Hive.openBox<PlanMapping>(_boxName);
    if (_box!.isEmpty) {
      await _seedDefaults();
    } else {
      await _migrateLabels();
    }
  }

  /// One-time migration: rename old 'HOS' / 'Regulatory' labels to 'Reg/HOS'.
  static Future<void> _migrateLabels() async {
    for (final entry in _box!.values) {
      if (entry.qbLabel == 'HOS' || entry.qbLabel == 'Regulatory') {
        entry.qbLabel = 'Reg/HOS';
        await entry.save();
      }
    }
  }

  static Future<void> _seedDefaults() async {
    for (final (plan, label) in _defaults) {
      await _box!.add(PlanMapping(
        myAdminPlan: plan,
        qbLabel: label,
        isDefault: true,
      ));
    }
    if (kDebugMode) debugPrint('[PlanMappingService] Seeded ${_defaults.length} defaults');
  }

  static Box<PlanMapping> get box {
    if (_box == null) throw StateError('PlanMappingService not initialized');
    return _box!;
  }

  static Future<Box<PlanMapping>> _ensureOpen() async {
    if (_box == null) throw StateError('PlanMappingService not initialized');
    if (!_box!.isOpen) {
      if (kDebugMode) debugPrint('[PlanMappingService] box was closed — reopening');
      _box = await Hive.openBox<PlanMapping>(_boxName);
      if (_box!.isEmpty) await _seedDefaults();
    }
    return _box!;
  }

  static Future<void> ensureOpen() async => _ensureOpen();

  // ── Read ──────────────────────────────────────────────────────────────────

  static List<PlanMapping> getAll() {
    if (_box == null || !_box!.isOpen) return [];
    final list = _box!.values.toList();
    list.sort((a, b) => a.myAdminPlan.toLowerCase().compareTo(b.myAdminPlan.toLowerCase()));
    return list;
  }

  /// Resolve a raw MyAdmin billing plan string to a short QB label.
  /// Iterates mappings in insertion order (defaults first) and returns
  /// the label of the first entry whose myAdminPlan is a case-insensitive
  /// substring of [billingPlan].  Returns [billingPlan] unchanged if no match.
  static String resolve(String billingPlan) {
    if (_box == null || !_box!.isOpen || billingPlan.trim().isEmpty) {
      return billingPlan.trim().isEmpty ? 'Unknown' : billingPlan;
    }
    final lower = billingPlan.toLowerCase();
    // Walk in insertion order so user-added entries (appended last) are checked
    // after defaults; iterate defaults list first for priority.
    for (final v in _box!.values) {
      if (lower.contains(v.myAdminPlan.toLowerCase())) return v.qbLabel;
    }
    // No match — return first word capped at 10 chars
    final first = billingPlan.trim().split(RegExp(r'\s+')).first;
    return first.length > 10 ? first.substring(0, 10) : first;
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  static Future<PlanMapping> add(String myAdminPlan, String qbLabel) async {
    final b = await _ensureOpen();
    final m = PlanMapping(
      myAdminPlan: myAdminPlan.trim(),
      qbLabel: qbLabel.trim(),
      isDefault: false,
    );
    await b.add(m);
    return m;
  }

  static Future<void> update(PlanMapping mapping, String myAdminPlan, String qbLabel) async {
    await _ensureOpen();
    mapping.myAdminPlan = myAdminPlan.trim();
    mapping.qbLabel = qbLabel.trim();
    await mapping.save();
  }

  static Future<void> delete(PlanMapping mapping) async {
    await _ensureOpen();
    await mapping.delete();
  }

  static Future<void> resetToDefaults() async {
    final b = await _ensureOpen();
    await b.clear();
    await _seedDefaults();
  }

  /// For cloud sync / backup restore.
  static Future<void> restoreFromList(List<Map<String, dynamic>> items) async {
    final b = await _ensureOpen();
    await b.clear();
    for (final item in items) {
      await b.add(PlanMapping(
        myAdminPlan: item['myAdminPlan']?.toString() ?? '',
        qbLabel:     item['qbLabel']?.toString() ?? '',
        isDefault:   item['isDefault'] as bool? ?? false,
      ));
    }
  }
}
