// Firebase Realtime Database Cloud Sync Service
//
// Uses the Firebase Realtime Database REST API — plain JSON over HTTPS.
// Zero CORS issues, no SDK required, works in every browser.
//
// REST API format:
//   PUT  https://{databaseName}.firebaseio.com/{path}.json?auth={apiKey}
//   GET  https://{databaseName}.firebaseio.com/{path}.json?auth={apiKey}
//
// Data layout (6 PUT calls per push, 6 GET calls per pull):
//   /activation_tracker/{userId}/standard_plan_rates.json
//   /activation_tracker/{userId}/customer_plan_codes.json
//   /activation_tracker/{userId}/serial_filter_rules.json
//   /activation_tracker/{userId}/imported_csvs.json        ← CSV backup
//   /activation_tracker/{userId}/qb_customers.json         ← QB Customer list + CUA flags
//   /activation_tracker/{userId}/qb_ignore_keywords.json   ← QB import filter keywords
//
// Each node stores a plain JSON object — no encoding tricks needed.
// The Realtime Database REST API accepts and returns native JSON directly.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../models/serial_filter_rule.dart';
import '../services/standard_plan_rate_service.dart';
import '../services/customer_plan_code_service.dart';
import '../services/filter_settings_service.dart';
import '../services/csv_persist_service.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../models/qb_customer.dart';

// ── Status enum ──────────────────────────────────────────────────────────────

enum SyncStatus { notConfigured, idle, syncing, success, error }

// ── CloudSyncService ─────────────────────────────────────────────────────────

class CloudSyncService {
  // SharedPreferences keys
  static const _kDbUrl         = 'rtdb_url';          // e.g. https://my-app-default-rtdb.firebaseio.com
  static const _kApiKey        = 'firebase_api_key';  // Web API key (for auth param)
  static const _kUserId        = 'cloud_sync_user_id';
  static const _kEnabled       = 'cloud_sync_enabled';
  static const _kAutoSync      = 'cloud_sync_auto';
  static const _kLastSyncEpoch = 'cloud_sync_last_epoch';

  // Keep old keys so existing saved credentials are not lost
  static const _kProjectId = 'firebase_project_id';
  static const _kAppId     = 'firebase_app_id';

  // Runtime state
  static String     _dbUrl          = '';
  static String     _apiKey         = '';
  static String     _userId         = 'default';
  static bool       _configured     = false;
  static SyncStatus _status         = SyncStatus.notConfigured;
  static String     _lastError      = '';
  static Timer?     _periodicTimer;   // fires every 3 minutes — pull then silent-push
  static DateTime?  _lastSyncAt;
  static bool       _autoSyncEnabled = false;

  // How often to auto-pull from Firebase (keeps multiple users in sync)
  static const _kPullInterval = Duration(minutes: 3);

  // Callback invoked after a periodic pull so the UI can refresh live data
  static void Function()? onPeriodicPullComplete;

  // ValueNotifier so the UI rebuilds on status changes
  static final ValueNotifier<SyncStatus> statusNotifier =
      ValueNotifier(SyncStatus.notConfigured);

  // ── Getters ───────────────────────────────────────────────────────────────
  static SyncStatus get status       => _status;
  static String     get lastError    => _lastError;
  static bool       get isConfigured => _configured;
  static DateTime?  get lastSyncAt   => _lastSyncAt;
  static bool       get autoSync     => _autoSyncEnabled;
  static String     get userId       => _userId;

  static Duration get nextSyncIn {
    if (_periodicTimer == null || !_periodicTimer!.isActive) return Duration.zero;
    if (_lastSyncAt == null) return _kPullInterval;
    final elapsed   = DateTime.now().difference(_lastSyncAt!);
    final remaining = _kPullInterval - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ── URL helpers ───────────────────────────────────────────────────────────

  /// Full REST URL for a node, with optional auth key appended.
  static String _nodeUrl(String node) {
    final base = _dbUrl.endsWith('/')
        ? _dbUrl.substring(0, _dbUrl.length - 1)
        : _dbUrl;
    final auth = _apiKey.isNotEmpty ? '?auth=$_apiKey' : '';
    return '$base/activation_tracker/$_userId/$node.json$auth';
  }

  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  // ── Initialisation ────────────────────────────────────────────────────────

  static Future<void> init() async {
    final prefs      = await SharedPreferences.getInstance();
    final enabled    = prefs.getBool(_kEnabled)   ?? false;
    _dbUrl           = prefs.getString(_kDbUrl)   ?? '';
    _apiKey          = prefs.getString(_kApiKey)  ?? '';
    _userId          = prefs.getString(_kUserId)  ?? 'default';
    _autoSyncEnabled = prefs.getBool(_kAutoSync)  ?? true;

    final lastEpoch = prefs.getInt(_kLastSyncEpoch);
    if (lastEpoch != null) {
      _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(lastEpoch);
    }

    if (!enabled || _dbUrl.isEmpty) {
      _setStatus(SyncStatus.notConfigured);
      return;
    }

    _configured = true;
    _setStatus(SyncStatus.idle);
    if (_autoSyncEnabled) _startTimer();
  }

  /// Save credentials and start/stop the timer as needed.
  static Future<String?> configure({
    required String dbUrl,
    required String apiKey,
    required String userId,
    required bool   enabled,
    bool            autoSync = true,
    // kept for compatibility with old call sites
    String projectId = '',
    String appId     = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled,   enabled);
    await prefs.setString(_kDbUrl,   dbUrl.trim());
    await prefs.setString(_kApiKey,  apiKey.trim());
    await prefs.setString(_kUserId,  userId.trim().isEmpty ? 'default' : userId.trim());
    await prefs.setBool(_kAutoSync,  autoSync);
    // preserve old keys so the form can still show them
    if (projectId.isNotEmpty) await prefs.setString(_kProjectId, projectId);
    if (appId.isNotEmpty)     await prefs.setString(_kAppId, appId);

    _dbUrl           = dbUrl.trim();
    _apiKey          = apiKey.trim();
    _userId          = userId.trim().isEmpty ? 'default' : userId.trim();
    _autoSyncEnabled = autoSync;

    if (!enabled || _dbUrl.isEmpty) {
      _stopTimer();
      _configured = false;
      _setStatus(SyncStatus.notConfigured);
      return null;
    }

    _configured = true;
    _setStatus(SyncStatus.idle);
    if (autoSync) { _startTimer(); } else { _stopTimer(); }
    return null; // RTDB needs no async initialisation
  }

  static Future<void> setAutoSync(bool value) async {
    _autoSyncEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSync, value);
    if (value && _configured) { _startTimer(); } else { _stopTimer(); }
  }

  static Future<Map<String, String>> readConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'dbUrl':     prefs.getString(_kDbUrl)      ?? '',
      'apiKey':    prefs.getString(_kApiKey)     ?? '',
      'projectId': prefs.getString(_kProjectId)  ?? '',
      'appId':     prefs.getString(_kAppId)      ?? '',
      'userId':    prefs.getString(_kUserId)     ?? '',
      'enabled':   (prefs.getBool(_kEnabled)    ?? false) ? 'true' : 'false',
      'autoSync':  (prefs.getBool(_kAutoSync)   ?? true)  ? 'true' : 'false',
    };
  }

  // ── Test connection ───────────────────────────────────────────────────────

  /// Reads a tiny probe node — HTTP 200 or 404 both mean the DB is reachable.
  static Future<bool> testConnection() async {
    if (!_configured) return false;
    try {
      final res = await http
          .get(Uri.parse(_nodeUrl('_probe')), headers: _headers)
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200 || res.statusCode == 404 ||
             res.body == 'null';   // RTDB returns "null" for missing nodes
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// Diagnostic write test — returns raw HTTP status + body.
  static Future<String> diagnosePatch() async {
    if (!_configured) return 'Not configured — save credentials first.';
    try {
      final url  = _nodeUrl('_diag_test');
      final body = jsonEncode({'ping': 'ok', 'ts': DateTime.now().toIso8601String()});
      final res  = await http
          .put(Uri.parse(url), headers: _headers, body: body)
          .timeout(const Duration(seconds: 10));
      return 'HTTP ${res.statusCode}\n${res.body.substring(0, res.body.length.clamp(0, 600))}';
    } catch (e) {
      return 'Exception: $e';
    }
  }

  // ── Push — 3 PUT calls ────────────────────────────────────────────────────
  //
  // PUT replaces the entire node with the supplied JSON — simple, atomic per
  // node, and fully CORS-safe.  3 writes per sync cycle.

  static Future<String?> pushAll() async {
    if (!_configured) return 'Firebase not configured';
    _setStatus(SyncStatus.syncing);

    try {
      final rates = StandardPlanRateService.getAll();
      final codes = CustomerPlanCodeService.getAll();
      final rules = FilterSettingsService.getAllRules();

      // ── 1. Standard plan rates ────────────────────────────────────
      final r1 = await _putNode('standard_plan_rates', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': rates.length,
        'data': rates.map((r) => {
          'planKey':   r.planKey,
          'keyword':   r.keyword,
          'yourCost':  r.yourCost,
          'sortOrder': r.sortOrder,
        }).toList(),
      });
      if (r1 != null) { _setStatus(SyncStatus.error); _lastError = r1; return r1; }

      // ── 2. Customer plan codes ────────────────────────────────────
      final r2 = await _putNode('customer_plan_codes', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': codes.length,
        'data': codes.map((c) => {
          'customerName':  c.customerName,
          'planCode':      c.planCode,
          'customerPrice': c.customerPrice,
          'notes':         c.notes,
          'requiredRpc':   c.requiredRpc,
        }).toList(),
      });
      if (r2 != null) { _setStatus(SyncStatus.error); _lastError = r2; return r2; }

      // ── 3. Serial filter rules ────────────────────────────────────
      final r3 = await _putNode('serial_filter_rules', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': rules.length,
        'data': rules.map((r) => {
          'prefix':    r.prefix,
          'isExcluded': r.isExcluded,
          'label':     r.label,
          'isSystem':  r.isSystem,
        }).toList(),
      });
      if (r3 != null) { _setStatus(SyncStatus.error); _lastError = r3; return r3; }

      // ── 4. Imported CSV files (backup) ────────────────────────────
      // Non-fatal: a CSV backup failure does not abort the sync.
      final csvMap = await CsvPersistService.getAllRaw();
      final hasCsv = csvMap.values.any((v) => v.isNotEmpty);
      if (hasCsv) {
        final r4 = await _putNode('imported_csvs', {
          'updatedAt': DateTime.now().toIso8601String(),
          ...csvMap,
        });
        if (r4 != null && kDebugMode) {
          debugPrint('[CloudSync] CSV backup warning (non-fatal): $r4');
        }
      }


      // ── 5. QB Customer list + CUA flags ────────────────────────
      // Non-fatal: failure does not abort the sync.
      try {
        final customers = QbCustomerService.getAll();
        if (customers.isNotEmpty) {
          final r5 = await _putNode('qb_customers', {
            'updatedAt': DateTime.now().toIso8601String(),
            'count': customers.length,
            'data': customers.map((c) => {
              'name':      c.name,
              'accountNo': c.accountNo,
              'email':     c.email,
              'phone':     c.phone,
              'address':   c.address,
              'isCua':     c.isCua,
              'jobType':   c.jobType,
            }).toList(),
          });
          if (r5 != null && kDebugMode) {
            debugPrint('[CloudSync] QB customer backup warning (non-fatal): $r5');
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[CloudSync] QB customer backup warning (non-fatal): $e');
      }

      // ── 6. QB Ignore Keywords ─────────────────────────────────
      // Non-fatal: failure does not abort the sync.
      try {
        final keywords = QbIgnoreKeywordService.getAll();
        final r6 = await _putNode('qb_ignore_keywords', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': keywords.length,
          'data': keywords.map((k) => {
            'keyword':   k.keyword,
            'isDefault': k.isDefault,
          }).toList(),
        });
        if (r6 != null && kDebugMode) {
          debugPrint('[CloudSync] QB ignore keywords warning (non-fatal): $r6');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[CloudSync] QB ignore keywords warning (non-fatal): $e');
      }

      await _recordLastSync();
      _setStatus(SyncStatus.success);
      return null;
    } catch (e) {
      _setStatus(SyncStatus.error);
      _lastError = e.toString();
      return e.toString();
    }
  }

  /// PUT a JSON object to a RTDB node. Returns null on success, error string on failure.
  static Future<String?> _putNode(String node, Map<String, dynamic> data) async {
    try {
      final res = await http
          .put(Uri.parse(_nodeUrl(node)),
               headers: _headers,
               body: jsonEncode(data))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) return null;

      // Extract Firebase error message
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['error'] != null) {
          return 'HTTP ${res.statusCode}: ${decoded['error']}';
        }
      } catch (_) {}
      final preview = res.body.length > 300
          ? '${res.body.substring(0, 300)}…'
          : res.body;
      return 'HTTP ${res.statusCode}: $preview';
    } catch (e) {
      return e.toString();
    }
  }

  // ── Pull — 4 parallel GET calls ───────────────────────────────────────────

  static Future<Map<String, dynamic>> pullAll() async {
    if (!_configured) return {'error': 'Firebase not configured'};
    _setStatus(SyncStatus.syncing);

    try {
      final responses = await Future.wait([
        http.get(Uri.parse(_nodeUrl('standard_plan_rates')), headers: _headers),
        http.get(Uri.parse(_nodeUrl('customer_plan_codes')), headers: _headers),
        http.get(Uri.parse(_nodeUrl('serial_filter_rules')), headers: _headers),
        http.get(Uri.parse(_nodeUrl('imported_csvs')),      headers: _headers),
        http.get(Uri.parse(_nodeUrl('qb_customers')),       headers: _headers),
        http.get(Uri.parse(_nodeUrl('qb_ignore_keywords')), headers: _headers),
      ]).timeout(const Duration(seconds: 20));

      final counts = <String, int>{};

      // ── Standard plan rates ───────────────────────────────────────
      if (responses[0].statusCode == 200 && responses[0].body != 'null') {
        final node = jsonDecode(responses[0].body) as Map<String, dynamic>;
        final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
        await StandardPlanRateService.box.clear();
        for (final item in list) {
          await StandardPlanRateService.box.add(StandardPlanRate(
            planKey:   item['planKey']?.toString()            ?? '',
            keyword:   item['keyword']?.toString()            ?? '',
            yourCost:  (item['yourCost']  as num?)?.toDouble() ?? 0,
            sortOrder: (item['sortOrder'] as num?)?.toInt()    ?? 99,
          ));
        }
        counts['standardPlanRates'] = list.length;
      }

      // ── Customer plan codes ───────────────────────────────────────
      if (responses[1].statusCode == 200 && responses[1].body != 'null') {
        final node = jsonDecode(responses[1].body) as Map<String, dynamic>;
        final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
        await CustomerPlanCodeService.clearAll();
        for (final item in list) {
          await CustomerPlanCodeService.save(CustomerPlanCode(
            customerName:  item['customerName']?.toString()            ?? '',
            planCode:      item['planCode']?.toString()                ?? '',
            customerPrice: (item['customerPrice'] as num?)?.toDouble() ?? 0,
            notes:         item['notes']?.toString()                   ?? '',
            requiredRpc:   item['requiredRpc']?.toString()             ?? '',
          ));
        }
        counts['customerPlanCodes'] = list.length;
      }

      // ── Serial filter rules ───────────────────────────────────────
      if (responses[2].statusCode == 200 && responses[2].body != 'null') {
        final node = jsonDecode(responses[2].body) as Map<String, dynamic>;
        final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
        await FilterSettingsService.box.clear();
        for (final item in list) {
          await FilterSettingsService.addRule(SerialFilterRule(
            prefix:     item['prefix']?.toString()  ?? '',
            isExcluded: item['isExcluded'] as bool? ?? true,
            label:      item['label']?.toString()   ?? '',
            isSystem:   item['isSystem']  as bool?  ?? false,
          ));
        }
        counts['serialFilterRules'] = list.length;
      }

      // ── Imported CSV files ──────────────────────────────────
      if (responses[3].statusCode == 200 && responses[3].body != 'null') {
        try {
          final node = jsonDecode(responses[3].body) as Map<String, dynamic>;
          // Restore to local SharedPreferences so the UI shows data immediately
          await CsvPersistService.restoreFromMap(node);
          counts['importedCsvs'] = 1;
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] CSV restore warning: $e');
          // Non-fatal — settings still restored even if CSV restore fails
        }
      }


      // ── QB Customer list restore ─────────────────────────────
      if (responses[4].statusCode == 200 && responses[4].body != 'null') {
        try {
          final node = jsonDecode(responses[4].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await QbCustomerService.clear();
            for (final item in list) {
              await QbCustomerService.box.add(QbCustomer(
                name:      item['name']?.toString()      ?? '',
                accountNo: item['accountNo']?.toString() ?? '',
                email:     item['email']?.toString()     ?? '',
                phone:     item['phone']?.toString()     ?? '',
                address:   item['address']?.toString()   ?? '',
                isCua:     item['isCua']    as bool?     ?? false,
                jobType:   item['jobType']?.toString()   ?? '',
              ));
            }
            counts['qbCustomers'] = list.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] QB customer restore warning: $e');
          // Non-fatal
        }
      }

      // ── QB Ignore Keywords restore ─────────────────────────────
      if (responses[5].statusCode == 200 && responses[5].body != 'null') {
        try {
          final node = jsonDecode(responses[5].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await QbIgnoreKeywordService.restoreFromList(list);
            counts['qbIgnoreKeywords'] = list.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] QB ignore keywords restore warning: $e');
          // Non-fatal
        }
      }
      await _recordLastSync();
      _setStatus(SyncStatus.success);
      return {'counts': counts};
    } catch (e) {
      _setStatus(SyncStatus.error);
      _lastError = e.toString();
      return {'error': e.toString()};
    }
  }

  // ── Periodic timer (every 3 min: pull → silent push) ─────────────────────

  static void _startTimer() {
    _stopTimer();
    if (!_configured) return;
    _periodicTimer = Timer.periodic(_kPullInterval, (_) async {
      if (kDebugMode) debugPrint('[CloudSync] Periodic auto-pull triggered (every 3 min)');
      await pullAll();
      // Notify the app to refresh UI with pulled data
      onPeriodicPullComplete?.call();
      // Push any local changes that may have been made since last sync
      await pushSilent();
    });
    if (kDebugMode) debugPrint('[CloudSync] Periodic sync timer started (${_kPullInterval.inMinutes} min)');
  }

  static void _stopTimer() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  static void dispose() => _stopTimer();

  // ── Silent push (called after every settings save) ────────────────────────
  //
  // Pushes all three nodes without changing the visible SyncStatus so the UI
  // dot doesn't flicker on every keystroke. Fire-and-forget — errors are
  // logged to debug output but not surfaced to the user.

  static Future<void> pushSilent() async {
    if (!_configured) return;
    try {
      final rates     = StandardPlanRateService.getAll();
      final codes     = CustomerPlanCodeService.getAll();
      final rules     = FilterSettingsService.getAllRules();
      final customers = QbCustomerService.getAll();
      final keywords  = QbIgnoreKeywordService.getAll();

      await Future.wait([
        _putNode('standard_plan_rates', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': rates.length,
          'data': rates.map((r) => {
            'planKey':   r.planKey,
            'keyword':   r.keyword,
            'yourCost':  r.yourCost,
            'sortOrder': r.sortOrder,
          }).toList(),
        }),
        _putNode('customer_plan_codes', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': codes.length,
          'data': codes.map((c) => {
            'customerName':  c.customerName,
            'planCode':      c.planCode,
            'customerPrice': c.customerPrice,
            'notes':         c.notes,
            'requiredRpc':   c.requiredRpc,
          }).toList(),
        }),
        _putNode('serial_filter_rules', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': rules.length,
          'data': rules.map((r) => {
            'prefix':     r.prefix,
            'isExcluded': r.isExcluded,
            'label':      r.label,
            'isSystem':   r.isSystem,
          }).toList(),
        }),
        if (customers.isNotEmpty)
          _putNode('qb_customers', {
            'updatedAt': DateTime.now().toIso8601String(),
            'count': customers.length,
            'data': customers.map((c) => {
              'name':      c.name,
              'accountNo': c.accountNo,
              'email':     c.email,
              'phone':     c.phone,
              'address':   c.address,
              'isCua':     c.isCua,
              'jobType':   c.jobType,
            }).toList(),
          }),
        _putNode('qb_ignore_keywords', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': keywords.length,
          'data': keywords.map((k) => {
            'keyword':   k.keyword,
            'isDefault': k.isDefault,
          }).toList(),
        }),
      ]);

      await _recordLastSync();
      _setStatus(SyncStatus.success);
      if (kDebugMode) debugPrint('[CloudSync] Silent push succeeded');
    } catch (e) {
      if (kDebugMode) debugPrint('[CloudSync] Silent push error: $e');
      // Don't change visible status — it's a background operation
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static void _setStatus(SyncStatus s) {
    _status = s;
    statusNotifier.value = s;
  }

  static Future<void> _recordLastSync() async {
    _lastSyncAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSyncEpoch, _lastSyncAt!.millisecondsSinceEpoch);
  }
}
