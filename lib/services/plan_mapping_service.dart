// Plan Mapping Service (Hive typeId=9)
// Maps raw MyAdmin "Active Billing Plan" strings to short QB SKU labels.
// Used by QB Verify to show plan breakdowns on the billing compare card.
//
// NOTE: Serial-number prefix overrides (Digital Matter, OEM, GoAnywhere,
// Phillips Connect) are handled in _shortPlanLabel() in qb_invoice_screen.dart
// BEFORE this service is consulted.  This service only resolves billing-plan
// strings for standard Geotab devices (G-prefix serials).
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
  // Each entry: (myAdminPlan substring, qbLabel)
  // Order matters — first match wins; longer/more-specific strings come first.
  static const List<(String, String)> _defaults = [
    // ── Standard Geotab plans ─────────────────────────────────────────────
    ('GO Expand',           'GO'),
    ('GO Plan',             'GO'),
    ('GO Basic',            'GO'),
    ('ProPlus',             'ProPlus'),
    ('Pro Plus',            'ProPlus'),
    ('Pro',                 'Pro'),
    ('HOS',                 'Reg/HOS'),
    ('Regulatory',          'Reg/HOS'),
    ('Base',                'Base'),
    ('Predictive',          'Predictive Coach'),
    ('Suspend',             'Suspend'),
    // ── Camera / specialty plans ──────────────────────────────────────────
    ('Surfsight',           'Surfsight'),
    ('Go Focus Plus',       'Go Focus Plus'),
    ('Go Focus',            'Go Focus'),
    ('Smarter AI',          'Smarter AI'),
    // ── Partner / OEM plans (billing-plan string matches) ─────────────────
    // Serial-prefix overrides in _shortPlanLabel take priority over these,
    // but these act as fallback if the billing plan string itself is descriptive.
    ('Hanover',             'Hanover'),
    ('Phillips Connect',    'Phillips Connect'),
    ('Digital Matter',      'Digital Matter'),
    ('GoAnywhere',          'GoAnywhere'),
    ('Go Anywhere',         'GoAnywhere'),
    // OEM makes — only needed if MyAdmin billing plan string contains the name
    ('Ford',                'Ford'),
    ('Mack',                'Mack'),
    ('Volvo',               'Volvo'),
    ('Caterpillar',         'CAT'),
    ('John Deere',          'John Deere'),
    ('CalAmp',              'CalAmp'),
    ('Komatsu',             'Komatsu'),
    ('Hitachi',             'Hitachi'),
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

  /// Migrations applied to existing Hive boxes on every startup.
  /// Safe to run repeatedly — each migration is idempotent.
  static Future<void> _migrateLabels() async {
    // ── M1: 'HOS' / 'Regulatory' standalone labels → 'Reg/HOS' ─────────────
    for (final entry in _box!.values) {
      if (entry.qbLabel == 'HOS' || entry.qbLabel == 'Regulatory') {
        entry.qbLabel = 'Reg/HOS';
        await entry.save();
      }
      // 'Predictive' → 'Predictive Coach'
      if (entry.qbLabel == 'Predictive' || entry.qbLabel == 'Coach') {
        entry.qbLabel = 'Predictive Coach';
        await entry.save();
      }
    }

    // ── M2: Seed any missing default entries ─────────────────────────────────
    // For each default, check if an entry with that myAdminPlan already exists.
    final existingPlans = _box!.values
        .map((e) => e.myAdminPlan.toLowerCase())
        .toSet();

    for (final (plan, label) in _defaults) {
      if (!existingPlans.contains(plan.toLowerCase())) {
        await _box!.add(PlanMapping(
          myAdminPlan: plan,
          qbLabel: label,
          isDefault: true,
        ));
        if (kDebugMode) debugPrint('[PlanMappingService] Migrated: $plan → $label');
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
    if (kDebugMode) {
      debugPrint('[PlanMappingService] Seeded ${_defaults.length} defaults');
    }
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
    list.sort((a, b) =>
        a.myAdminPlan.toLowerCase().compareTo(b.myAdminPlan.toLowerCase()));
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

  static Future<void> update(
      PlanMapping mapping, String myAdminPlan, String qbLabel) async {
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
        qbLabel: item['qbLabel']?.toString() ?? '',
        isDefault: item['isDefault'] as bool? ?? false,
      ));
    }
  }
}
