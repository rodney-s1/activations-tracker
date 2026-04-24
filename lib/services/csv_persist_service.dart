// CSV Persist Service
//
// Persists lightweight metadata (filenames, dates) to SharedPreferences.
//
// ⚠ IMPORTANT — Large CSV content (MyAdmin report, QB Sales CSV) is NOT
// stored here.  SharedPreferences on Flutter Web uses localStorage which
// has a hard 5 MB browser limit.  Attempting to store a large CSV throws
// a QuotaExceededError.  Those files must be re-imported each session.
//
// The QB Customer List IS persisted because it is a small, permanent list
// that survives app restarts intentionally.
//
// Keys stored:
//   csv_myadmin_filename  — last imported MyAdmin filename (display only)
//   csv_myadmin_date      — Report Date extracted from line 2
//   csv_qb_filename       — last imported QB Sales filename (display only)
//   csv_activations_content — raw text of the last Activations dashboard CSV
//   csv_activations_filename — original filename shown in the UI
//   csv_qb_customer_content  — raw text of the QB Customer List (persisted permanently)
//   csv_qb_customer_filename — filename of the QB Customer List
//   csv_fuel_filename        — last imported BlueArrow Fuel CSV filename (display only)

import 'package:shared_preferences/shared_preferences.dart';

class CsvPersistService {
  // ── Keys ─────────────────────────────────────────────────────────────────
  static const _kMyAdminContent  = 'csv_myadmin_content';
  static const _kMyAdminFile     = 'csv_myadmin_filename';
  static const _kMyAdminDate     = 'csv_myadmin_date';

  static const _kQbContent       = 'csv_qb_content';
  static const _kQbFile          = 'csv_qb_filename';

  static const _kActivationsContent = 'csv_activations_content';
  static const _kActivationsFile    = 'csv_activations_filename';

  // QB Customer List — persisted permanently, restored on every startup
  static const _kQbCustomerContent  = 'csv_qb_customer_content';
  static const _kQbCustomerFile     = 'csv_qb_customer_filename';

  // BlueArrow Fuel CSV — session-only (like MyAdmin/QB Sales); only filename persisted
  static const _kFuelFile = 'csv_fuel_filename';

  // ── MyAdmin ───────────────────────────────────────────────────────────────
  // Content is NOT persisted (too large for localStorage).
  // Only the filename and report date are saved for display purposes.

  static Future<void> saveMyAdmin({
    required String content,   // ignored — not stored
    required String fileName,
    String? reportDate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Clear any previously stored content that may have been saved by an
    // older version of the app, freeing up localStorage space.
    await prefs.remove(_kMyAdminContent);
    await prefs.setString(_kMyAdminFile, fileName);
    if (reportDate != null) {
      await prefs.setString(_kMyAdminDate, reportDate);
    } else {
      await prefs.remove(_kMyAdminDate);
    }
  }

  /// Always returns null — MyAdmin CSV is session-only and must be re-imported.
  static Future<({String content, String fileName, String? reportDate})?> loadMyAdmin() async {
    return null;
  }

  static Future<void> clearMyAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMyAdminContent);
    await prefs.remove(_kMyAdminFile);
    await prefs.remove(_kMyAdminDate);
  }

  // ── QuickBooks ────────────────────────────────────────────────────────────

  // ── QuickBooks Sales CSV ─────────────────────────────────────────────────
  // Content is NOT persisted (too large for localStorage).
  // Only the filename is saved for display purposes.

  static Future<void> saveQb({
    required String content,   // ignored — not stored
    required String fileName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Clear any previously stored content from older app versions.
    await prefs.remove(_kQbContent);
    await prefs.setString(_kQbFile, fileName);
  }

  /// Always returns null — QB Sales CSV is session-only and must be re-imported.
  static Future<({String content, String fileName})?> loadQb() async {
    return null;
  }

  static Future<void> clearQb() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQbContent);
    await prefs.remove(_kQbFile);
  }

  // ── Activations Dashboard ─────────────────────────────────────────────────

  static Future<void> saveActivations({
    required String content,   // ignored — not stored; user imports fresh each session
    required String fileName,
  }) async {
    // Activations CSV is intentionally NOT persisted — the user uploads a
    // new file each session.  Clear any content saved by an older version.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActivationsContent);
    await prefs.remove(_kActivationsFile);
  }

  /// Always returns null — Activations CSV is session-only and must be re-imported.
  static Future<({String content, String fileName})?> loadActivations() async {
    return null;
  }

  static Future<void> clearActivations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActivationsContent);
    await prefs.remove(_kActivationsFile);
  }

  // ── QB Customer List (permanent) ──────────────────────────────────────────
  // Stored separately so it is ALWAYS restored on startup and never cleared
  // by normal app operations. Only replaced when a new CSV is imported.

  static Future<void> saveQbCustomerList({
    required String content,
    required String fileName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQbCustomerContent, content);
    await prefs.setString(_kQbCustomerFile,    fileName);
  }

  static Future<({String content, String fileName})?> loadQbCustomerList() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_kQbCustomerContent);
    if (content == null || content.isEmpty) return null;
    return (
      content:  content,
      fileName: prefs.getString(_kQbCustomerFile) ?? 'QB Customer List.csv',
    );
  }

  static Future<void> clearQbCustomerList() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQbCustomerContent);
    await prefs.remove(_kQbCustomerFile);
  }

  // ── BlueArrow Fuel CSV ──────────────────────────────────────────────────────
  // Content is NOT persisted (session-only, re-imported each month).
  // Only the filename is saved so the import slot can show it after a reload.

  static Future<void> saveFuelCsv({required String fileName}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFuelFile, fileName);
  }

  static Future<String?> loadFuelCsvFileName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kFuelFile);
  }

  static Future<void> clearFuelCsv() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFuelFile);
  }

  // ── Cloud sync helpers ─────────────────────────────────────────────────────
  // Called by CloudSyncService when pushing/pulling CSV data to Firebase RTDB.

  static Future<Map<String, String>> getAllRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'myadmin_filename':     prefs.getString(_kMyAdminFile)          ?? '',
      'myadmin_date':         prefs.getString(_kMyAdminDate)          ?? '',
      'qb_filename':          prefs.getString(_kQbFile)               ?? '',
      'act_content':          prefs.getString(_kActivationsContent)   ?? '',
      'act_filename':         prefs.getString(_kActivationsFile)      ?? '',
      'qb_customer_content':  prefs.getString(_kQbCustomerContent)    ?? '',
      'qb_customer_filename': prefs.getString(_kQbCustomerFile)       ?? '',
    };
  }

  static Future<void> restoreFromMap(Map<String, dynamic> map) async {
    final prefs = await SharedPreferences.getInstance();
    Future<void> s(String k, String v) async {
      if (v.isNotEmpty) await prefs.setString(k, v);
    }
    await s(_kMyAdminFile,        map['myadmin_filename']       as String? ?? '');
    await s(_kMyAdminDate,        map['myadmin_date']           as String? ?? '');
    await s(_kQbFile,             map['qb_filename']            as String? ?? '');
    await s(_kActivationsContent, map['act_content']            as String? ?? '');
    await s(_kActivationsFile,    map['act_filename']           as String? ?? '');
    await s(_kQbCustomerContent,  map['qb_customer_content']    as String? ?? '');
    await s(_kQbCustomerFile,     map['qb_customer_filename']   as String? ?? '');
  }
}
