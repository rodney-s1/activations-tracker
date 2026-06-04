// AWS Sync Service
//
// Replaces Firebase Realtime Database with an AWS-hosted backend:
//   API Gateway (HTTP API) → Lambda → DynamoDB
//
// The API endpoint is baked in at compile time — no user configuration needed.
// Sync starts automatically for every user immediately after sign-in.
//
// REST API format:
//   GET  https://{apiId}.execute-api.us-east-1.amazonaws.com/sync/{node}
//   PUT  https://{apiId}.execute-api.us-east-1.amazonaws.com/sync/{node}
//
// Data nodes synced (9 total — one DynamoDB item each):
//   standard_plan_rates, customer_plan_codes, rate_plan_overrides,
//   serial_filter_rules, imported_csvs, qb_customers,
//   qb_ignore_keywords, item_price_list, fuel_aliases
//
// All @bluearrowmail.com users read and write the SAME shared DynamoDB table.
// No auth token needed — API Gateway is locked to the VPC/CloudFront origin
// and the DynamoDB table is private (only accessible via Lambda).

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
import '../services/customer_rate_plan_override_service.dart';
import '../services/filter_settings_service.dart';
import '../services/csv_persist_service.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../services/item_price_list_service.dart';
import '../services/fuel_alias_service.dart';
import '../models/qb_customer.dart';

// ── Status enum ──────────────────────────────────────────────────────────────

enum SyncStatus { notConfigured, idle, syncing, success, error }

// ── CloudSyncService ─────────────────────────────────────────────────────────

class CloudSyncService {
  // ── Baked-in AWS API endpoint — no user config required ───────────────────
  // Set to the API Gateway URL output by CloudFormation after first deploy.
  // Format: https://{apiId}.execute-api.us-east-1.amazonaws.com
  // PLACEHOLDER — replace with real URL after running:
  //   aws cloudformation deploy ... (see aws/cloudformation.yml)
  static const _kApiEndpoint = 'PENDING_CLOUDFORMATION_DEPLOY';

  // SharedPreferences keys
  static const _kAutoSync      = 'cloud_sync_auto';
  static const _kLastSyncEpoch = 'cloud_sync_last_epoch';

  // Runtime state
  static bool       _configured     = false;
  static SyncStatus _status         = SyncStatus.notConfigured;
  static String     _lastError      = '';
  static Timer?     _periodicTimer;
  static DateTime?  _lastSyncAt;
  static bool       _autoSyncEnabled = false;

  // How often to auto-pull (keeps all users in sync)
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

  static Duration get nextSyncIn {
    if (_periodicTimer == null || !_periodicTimer!.isActive) return Duration.zero;
    if (_lastSyncAt == null) return _kPullInterval;
    final elapsed   = DateTime.now().difference(_lastSyncAt!);
    final remaining = _kPullInterval - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ── URL helper ────────────────────────────────────────────────────────────

  /// Full REST URL for a sync node.
  /// GET/PUT https://{apiId}.execute-api.us-east-1.amazonaws.com/sync/{node}
  static String _nodeUrl(String node) {
    final base = _kApiEndpoint.endsWith('/')
        ? _kApiEndpoint.substring(0, _kApiEndpoint.length - 1)
        : _kApiEndpoint;
    return '$base/sync/$node';
  }

  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  // ── Initialisation ────────────────────────────────────────────────────────

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _autoSyncEnabled = prefs.getBool(_kAutoSync) ?? true;

    final lastEpoch = prefs.getInt(_kLastSyncEpoch);
    if (lastEpoch != null) {
      _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(lastEpoch);
    }

    // Always configured — endpoint is baked in.
    _configured = true;
    _setStatus(SyncStatus.idle);
    if (_autoSyncEnabled) _startTimer();
  }

  /// Update auto-sync preference and restart/stop timer accordingly.
  /// Endpoint is baked in and cannot be changed at runtime.
  static Future<String?> configure({
    // All params ignored — kept so old call sites compile.
    String dbUrl     = '',
    String apiKey    = '',
    bool   enabled   = true,
    bool   autoSync  = true,
    String projectId = '',
    String appId     = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSync, autoSync);
    _autoSyncEnabled = autoSync;
    _configured      = true;
    _setStatus(SyncStatus.idle);
    if (autoSync) { _startTimer(); } else { _stopTimer(); }
    return null;
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
      'endpoint': _kApiEndpoint,
      'enabled':  'true',
      'autoSync': (prefs.getBool(_kAutoSync) ?? true) ? 'true' : 'false',
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

  // ── Push all — full sync (used by manual "Sync Now" button) ──────────────

  static Future<String?> pushAll() async {
    if (!_configured) return 'Sync not configured';
    _setStatus(SyncStatus.syncing);

    try {
      final rates     = StandardPlanRateService.getAll();
      final codes     = CustomerPlanCodeService.getAll();
      final overrides = CustomerRatePlanOverrideService.getAll();
      final rules     = FilterSettingsService.getAllRules();
      final customers = QbCustomerService.getAll();
      final keywords  = QbIgnoreKeywordService.getAll();

      // ── 1. Standard plan rates (with customerPrice) ───────────────
      final r1 = await _putNode('standard_plan_rates', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': rates.length,
        'data': rates.map((r) => {
          'planKey':       r.planKey,
          'keyword':       r.keyword,
          'yourCost':      r.yourCost,
          'customerPrice': r.customerPrice,
          'sortOrder':     r.sortOrder,
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

      // ── 3. Rate Plan Overrides ────────────────────────────────────
      final r3 = await _putNode('rate_plan_overrides', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': overrides.length,
        'data': overrides.map((o) => {
          'customerName':  o.customerName,
          'ratePlan':      o.ratePlan,
          'customerPrice': o.customerPrice,
          'yourCost':      o.yourCost,
          'notes':         o.notes,
          'lastUpdated':   o.lastUpdated?.toIso8601String() ?? '',
        }).toList(),
      });
      if (r3 != null) { _setStatus(SyncStatus.error); _lastError = r3; return r3; }

      // ── 4. Serial filter rules ────────────────────────────────────
      final r4 = await _putNode('serial_filter_rules', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': rules.length,
        'data': rules.map((r) => {
          'prefix':     r.prefix,
          'isExcluded': r.isExcluded,
          'label':      r.label,
          'isSystem':   r.isSystem,
        }).toList(),
      });
      if (r4 != null) { _setStatus(SyncStatus.error); _lastError = r4; return r4; }

      // ── 5. Imported CSV files (non-fatal) ─────────────────────────
      final csvMap = await CsvPersistService.getAllRaw();
      final hasCsv = csvMap.values.any((v) => v.isNotEmpty);
      if (hasCsv) {
        final r5csv = await _putNode('imported_csvs', {
          'updatedAt': DateTime.now().toIso8601String(),
          ...csvMap,
        });
        if (r5csv != null && kDebugMode) {
          debugPrint('[CloudSync] CSV backup warning (non-fatal): $r5csv');
        }
      }

      // ── 6. QB Customer list ───────────────────────────────────────
      // Always push customers (even if empty) so Firebase always reflects
      // the authoritative current state. The pull side will only overwrite
      // local data if the cloud list is non-empty, so an accidental empty
      // push here won't wipe other devices — but it does keep Firebase current.
      final r6 = await _putNode('qb_customers', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': customers.length,
        'data': customers.map((c) => {
          'name':              c.name,
          'accountNo':         c.accountNo,
          'email':             c.email,
          'phone':             c.phone,
          'address':           c.address,
          'isCua':             c.isCua,
          'jobType':           c.jobType,
          'parentAccountName': c.parentAccountName,
        }).toList(),
      });
      if (r6 != null && kDebugMode) {
        debugPrint('[CloudSync] QB customer backup warning (non-fatal): $r6');
      }

      // ── 7. QB Ignore Keywords ─────────────────────────────────────
      final r7 = await _putNode('qb_ignore_keywords', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': keywords.length,
        'data': keywords.map((k) => {
          'keyword':   k.keyword,
          'isDefault': k.isDefault,
        }).toList(),
      });
      if (r7 != null && kDebugMode) {
        debugPrint('[CloudSync] QB ignore keywords warning (non-fatal): $r7');
      }

      // ── 8. Item Price List (non-fatal) ────────────────────────────
      final priceItems = ItemPriceListService.getAll();
      if (priceItems.isNotEmpty) {
        final r8 = await _putNode('item_price_list', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': priceItems.length,
          'data': priceItems.map((it) => {
            'item':        it.item,
            'description': it.description,
            'cost':        it.cost,
            'price':       it.price,
          }).toList(),
        });
        if (r8 != null && kDebugMode) {
          debugPrint('[CloudSync] Item price list warning (non-fatal): $r8');
        }
      }

      // ── 9. Fuel Aliases ───────────────────────────────────────────
      final fuelAliases = FuelAliasService.instance.toCloudList();
      final r9 = await _putNode('fuel_aliases', {
        'updatedAt': DateTime.now().toIso8601String(),
        'count': fuelAliases.length,
        'data': fuelAliases,
      });
      if (r9 != null && kDebugMode) {
        debugPrint('[CloudSync] Fuel aliases warning (non-fatal): $r9');
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

  // ── Pull — 8 parallel GET calls ───────────────────────────────────────────
  //
  // Indices: 0=standard_plan_rates  1=customer_plan_codes  2=rate_plan_overrides
  //          3=serial_filter_rules  4=imported_csvs
  //          5=qb_customers         6=qb_ignore_keywords  7=item_price_list

  static Future<Map<String, dynamic>> pullAll() async {
    if (!_configured) return {'error': 'Sync not configured'};
    _setStatus(SyncStatus.syncing);

    try {
      final responses = await Future.wait([
        http.get(Uri.parse(_nodeUrl('standard_plan_rates')), headers: _headers),  // 0
        http.get(Uri.parse(_nodeUrl('customer_plan_codes')), headers: _headers),  // 1
        http.get(Uri.parse(_nodeUrl('rate_plan_overrides')), headers: _headers),  // 2
        http.get(Uri.parse(_nodeUrl('serial_filter_rules')), headers: _headers),  // 3
        http.get(Uri.parse(_nodeUrl('imported_csvs')),       headers: _headers),  // 4
        http.get(Uri.parse(_nodeUrl('qb_customers')),        headers: _headers),  // 5
        http.get(Uri.parse(_nodeUrl('qb_ignore_keywords')),  headers: _headers),  // 6
        http.get(Uri.parse(_nodeUrl('item_price_list')),     headers: _headers),  // 7
        http.get(Uri.parse(_nodeUrl('fuel_aliases')),        headers: _headers),  // 8
      ]).timeout(const Duration(seconds: 20));

      final counts = <String, int>{};

      // ── 0. Standard plan rates (includes customerPrice) ───────────
      if (responses[0].statusCode == 200 && responses[0].body != 'null') {
        final node = jsonDecode(responses[0].body) as Map<String, dynamic>;
        final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
        if (list.isNotEmpty) {
          await StandardPlanRateService.box.clear();
          for (final item in list) {
            await StandardPlanRateService.box.add(StandardPlanRate(
              planKey:       item['planKey']?.toString()              ?? '',
              keyword:       item['keyword']?.toString()              ?? '',
              yourCost:      (item['yourCost']      as num?)?.toDouble() ?? 0,
              customerPrice: (item['customerPrice'] as num?)?.toDouble() ?? 0,
              sortOrder:     (item['sortOrder']     as num?)?.toInt()    ?? 99,
            ));
          }
          counts['standardPlanRates'] = list.length;
        }
      }

      // ── 1. Customer plan codes ────────────────────────────────────
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

      // ── 2. Rate Plan Overrides ────────────────────────────────────
      if (responses[2].statusCode == 200 && responses[2].body != 'null') {
        try {
          final node = jsonDecode(responses[2].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await CustomerRatePlanOverrideService.restoreFromCloud(list);
            counts['ratePlanOverrides'] = list.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] Rate plan overrides restore warning: $e');
          // Non-fatal
        }
      }

      // ── 3. Serial filter rules ────────────────────────────────────
      if (responses[3].statusCode == 200 && responses[3].body != 'null') {
        final node = jsonDecode(responses[3].body) as Map<String, dynamic>;
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

      // ── 4. Imported CSV files (non-fatal) ─────────────────────────
      if (responses[4].statusCode == 200 && responses[4].body != 'null') {
        try {
          final node = jsonDecode(responses[4].body) as Map<String, dynamic>;
          await CsvPersistService.restoreFromMap(node);
          counts['importedCsvs'] = 1;
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] CSV restore warning: $e');
        }
      }

      // ── 5. QB Customer list ───────────────────────────────────────
      // CRITICAL SAFETY RULE: Only overwrite local customers if Firebase has
      // a NON-EMPTY list. If the cloud node is empty or null, leave local
      // Hive data intact — this prevents the list from disappearing when:
      //   • The cloud node was never populated on this device
      //   • A race condition left an empty node
      //   • The node was accidentally cleared
      if (responses[5].statusCode == 200 && responses[5].body != 'null') {
        try {
          final node = jsonDecode(responses[5].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await QbCustomerService.clear();
            for (final item in list) {
              await QbCustomerService.box.add(QbCustomer(
                name:              item['name']?.toString()              ?? '',
                accountNo:         item['accountNo']?.toString()         ?? '',
                email:             item['email']?.toString()             ?? '',
                phone:             item['phone']?.toString()             ?? '',
                address:           item['address']?.toString()           ?? '',
                isCua:             item['isCua']    as bool?             ?? false,
                jobType:           item['jobType']?.toString()           ?? '',
                parentAccountName: item['parentAccountName']?.toString() ?? '',
              ));
            }
            counts['qbCustomers'] = list.length;
          }
          // list.isEmpty → leave local Hive data intact
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] QB customer restore warning: $e');
          // Non-fatal
        }
      }

      // ── 6. QB Ignore Keywords ─────────────────────────────────────
      if (responses[6].statusCode == 200 && responses[6].body != 'null') {
        try {
          final node = jsonDecode(responses[6].body) as Map<String, dynamic>;
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

      // ── 7. Item Price List ────────────────────────────────────────
      if (responses[7].statusCode == 200 && responses[7].body != 'null') {
        try {
          final node = jsonDecode(responses[7].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await ItemPriceListService.restoreFromCloud(list);
            counts['itemPriceList'] = list.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] Item price list restore warning: $e');
          // Non-fatal
        }
      }

      // ── 8. Fuel Aliases ───────────────────────────────────────────
      if (responses[8].statusCode == 200 && responses[8].body != 'null') {
        try {
          final node = jsonDecode(responses[8].body) as Map<String, dynamic>;
          final list = (node['data'] as List? ?? []).cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            await FuelAliasService.instance.restoreFromCloud(list);
            counts['fuelAliases'] = list.length;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[CloudSync] Fuel aliases restore warning: $e');
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
  // Pushes all nodes without changing the visible SyncStatus so the UI
  // dot doesn't flicker on every keystroke. Fire-and-forget — errors are
  // logged to debug output but not surfaced to the user.
  //
  // QB CUSTOMERS: Always pushed (even if currently empty on this device) so
  // Firebase always has the latest state. The pull side is protected — it only
  // overwrites local data when the cloud list is non-empty.

  static Future<void> pushSilent() async {
    if (!_configured) return;
    try {
      final rates     = StandardPlanRateService.getAll();
      final codes     = CustomerPlanCodeService.getAll();
      final overrides = CustomerRatePlanOverrideService.getAll();
      final rules     = FilterSettingsService.getAllRules();
      final customers = QbCustomerService.getAll();
      final keywords  = QbIgnoreKeywordService.getAll();

      await Future.wait([
        _putNode('standard_plan_rates', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': rates.length,
          'data': rates.map((r) => {
            'planKey':       r.planKey,
            'keyword':       r.keyword,
            'yourCost':      r.yourCost,
            'customerPrice': r.customerPrice,
            'sortOrder':     r.sortOrder,
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
        _putNode('rate_plan_overrides', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': overrides.length,
          'data': overrides.map((o) => {
            'customerName':  o.customerName,
            'ratePlan':      o.ratePlan,
            'customerPrice': o.customerPrice,
            'yourCost':      o.yourCost,
            'notes':         o.notes,
            'lastUpdated':   o.lastUpdated?.toIso8601String() ?? '',
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
        // Always push qb_customers — never skip even if empty.
        // The pull side protects against an empty cloud node overwriting local data.
        _putNode('qb_customers', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': customers.length,
          'data': customers.map((c) => {
            'name':              c.name,
            'accountNo':         c.accountNo,
            'email':             c.email,
            'phone':             c.phone,
            'address':           c.address,
            'isCua':             c.isCua,
            'jobType':           c.jobType,
            'parentAccountName': c.parentAccountName,
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
        _putNode('fuel_aliases', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': FuelAliasService.instance.toCloudList().length,
          'data': FuelAliasService.instance.toCloudList(),
        }),
      ]);

      // ── Item Price List (non-fatal, only if non-empty) ────────────
      final priceItems = ItemPriceListService.getAll();
      if (priceItems.isNotEmpty) {
        await _putNode('item_price_list', {
          'updatedAt': DateTime.now().toIso8601String(),
          'count': priceItems.length,
          'data': priceItems.map((it) => {
            'item':        it.item,
            'description': it.description,
            'cost':        it.cost,
            'price':       it.price,
          }).toList(),
        });
      }

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
