// CSV Persist Service
//
// Saves raw CSV content to SharedPreferences so imported files survive
// browser refresh, tab close, and app restart.  No file size limit is
// enforced — the browser's IndexedDB can store tens of MB comfortably.
//
// Keys stored:
//   csv_myadmin_content   — raw text of the last MyAdmin Full Report
//   csv_myadmin_filename  — original filename shown in the UI
//   csv_myadmin_date      — Report Date extracted from line 2
//   csv_qb_content        — raw text of the last QB Sales by Customer CSV
//   csv_qb_filename       — original filename shown in the UI
//   csv_activations_content — raw text of the last Activations dashboard CSV
//   csv_activations_filename — original filename shown in the UI
//   csv_qb_customer_content  — raw text of the QB Customer List (persisted permanently)
//   csv_qb_customer_filename — filename of the QB Customer List

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

  // ── MyAdmin ───────────────────────────────────────────────────────────────

  static Future<void> saveMyAdmin({
    required String content,
    required String fileName,
    String? reportDate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMyAdminContent, content);
    await prefs.setString(_kMyAdminFile,    fileName);
    if (reportDate != null) {
      await prefs.setString(_kMyAdminDate, reportDate);
    } else {
      await prefs.remove(_kMyAdminDate);
    }
  }

  static Future<({String content, String fileName, String? reportDate})?> loadMyAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_kMyAdminContent);
    if (content == null || content.isEmpty) return null;
    return (
      content:    content,
      fileName:   prefs.getString(_kMyAdminFile) ?? 'MyAdmin Report.csv',
      reportDate: prefs.getString(_kMyAdminDate),
    );
  }

  static Future<void> clearMyAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMyAdminContent);
    await prefs.remove(_kMyAdminFile);
    await prefs.remove(_kMyAdminDate);
  }

  // ── QuickBooks ────────────────────────────────────────────────────────────

  static Future<void> saveQb({
    required String content,
    required String fileName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQbContent, content);
    await prefs.setString(_kQbFile,    fileName);
  }

  static Future<({String content, String fileName})?> loadQb() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_kQbContent);
    if (content == null || content.isEmpty) return null;
    return (
      content:  content,
      fileName: prefs.getString(_kQbFile) ?? 'QB Sales.csv',
    );
  }

  static Future<void> clearQb() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQbContent);
    await prefs.remove(_kQbFile);
  }

  // ── Activations Dashboard ─────────────────────────────────────────────────

  static Future<void> saveActivations({
    required String content,
    required String fileName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActivationsContent, content);
    await prefs.setString(_kActivationsFile,    fileName);
  }

  static Future<({String content, String fileName})?> loadActivations() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_kActivationsContent);
    if (content == null || content.isEmpty) return null;
    return (
      content:  content,
      fileName: prefs.getString(_kActivationsFile) ?? 'Activations.csv',
    );
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

  // ── Cloud sync helpers ─────────────────────────────────────────────────────
  // Called by CloudSyncService when pushing/pulling CSV data to Firebase RTDB.

  static Future<Map<String, String>> getAllRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'myadmin_content':      prefs.getString(_kMyAdminContent)       ?? '',
      'myadmin_filename':     prefs.getString(_kMyAdminFile)          ?? '',
      'myadmin_date':         prefs.getString(_kMyAdminDate)          ?? '',
      'qb_content':           prefs.getString(_kQbContent)            ?? '',
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
    await s(_kMyAdminContent,     map['myadmin_content']       as String? ?? '');
    await s(_kMyAdminFile,        map['myadmin_filename']       as String? ?? '');
    await s(_kMyAdminDate,        map['myadmin_date']           as String? ?? '');
    await s(_kQbContent,          map['qb_content']             as String? ?? '');
    await s(_kQbFile,             map['qb_filename']            as String? ?? '');
    await s(_kActivationsContent, map['act_content']            as String? ?? '');
    await s(_kActivationsFile,    map['act_filename']           as String? ?? '');
    await s(_kQbCustomerContent,  map['qb_customer_content']    as String? ?? '');
    await s(_kQbCustomerFile,     map['qb_customer_filename']   as String? ?? '');
  }
}
