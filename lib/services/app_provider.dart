// App-wide state provider

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/customer_group.dart';
import '../models/import_session.dart';
import '../models/customer_rate.dart';
import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../models/customer_rate_plan_override.dart';
import '../models/qb_customer.dart';
import '../services/csv_parser_service.dart';
import '../services/history_service.dart';
import '../services/customer_rate_service.dart';
import '../services/standard_plan_rate_service.dart';
import '../services/customer_plan_code_service.dart';
import '../services/customer_rate_plan_override_service.dart';
import '../services/qb_customer_service.dart';
import '../services/pricing_engine.dart';
import '../services/cloud_sync_service.dart';
import '../services/csv_persist_service.dart';
import '../services/item_price_list_service.dart';
import '../services/device_price_override_service.dart';
export '../services/csv_parser_service.dart' show BlankCustomerRecord;

enum AppState { idle, loading, loaded, error }

class AppProvider extends ChangeNotifier {
  AppState _state = AppState.idle;
  String _errorMessage = '';
  CsvParseResult? _parseResult;
  List<CustomerGroup> _customerGroups = [];
  String _currentFileName = '';
  String _searchQuery = '';

  // History
  List<ImportSession> _history = [];

  // Settings
  List<CustomerRate> _customerRates = [];
  List<StandardPlanRate> _standardRates = [];
  List<CustomerPlanCode> _customerPlanCodes = [];
  List<QbCustomer> _qbCustomers = [];
  List<CustomerRatePlanOverride> _ratePlanOverrides = [];

  // ── Customer renames: originalName → renamedName ────────────────────
  Map<String, String> _customerRenames = {};

  // ── Hidden customers: set of original (pre-rename) customer names ─────
  Set<String> _hiddenCustomers = {};

  // ── Manual per-device price overrides (serial → override) ─────────────
  Map<String, DevicePriceOverride> _devicePriceOverrides = {};

  Map<String, DevicePriceOverride> get devicePriceOverrides => _devicePriceOverrides;

  /// Read-only view of the rename map (original → new).
  Map<String, String> get customerRenames => Map.unmodifiable(_customerRenames);

  /// Read-only set of hidden customer names (these are the *current display* names).
  Set<String> get hiddenCustomers => Set.unmodifiable(_hiddenCustomers);

  // ── Cloud sync countdown timer (updates UI every minute) ──────────────
  Timer? _countdownTimer;

  /// Kick off the countdown ticker so the Cloud Sync screen refreshes
  /// its "next sync in Xm Ys" display without manual rebuilds.
  void startSyncCountdown() {
    _countdownTimer?.cancel();
    // Tick every 30 seconds — fine-grained enough for "Xm Ys" without spam
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      notifyListeners(); // triggers UI rebuild in CloudSyncScreen
    });
  }

  void stopSyncCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  @override
  void dispose() {
    stopSyncCountdown();
    CloudSyncService.dispose();
    super.dispose();
  }

  AppState get state => _state;
  String get errorMessage => _errorMessage;
  CsvParseResult? get parseResult => _parseResult;
  List<CustomerGroup> get customerGroups => _customerGroups;
  String get currentFileName => _currentFileName;
  String get searchQuery => _searchQuery;
  List<ImportSession> get history => _history;
  List<CustomerRate> get customerRates => _customerRates;
  List<StandardPlanRate> get standardRates => _standardRates;
  List<CustomerPlanCode> get customerPlanCodes => _customerPlanCodes;
  List<QbCustomer> get qbCustomers => _qbCustomers;
  List<CustomerRatePlanOverride> get ratePlanOverrides => _ratePlanOverrides;

  /// Apply manual device price overrides on top of engine pricing.
  /// Called at the end of repriceCurrent and loadCsv.
  void _applyDeviceOverrides() {
    if (_devicePriceOverrides.isEmpty) return;
    _customerGroups = _customerGroups.map((group) {
      final newDevices = group.devices.map((record) {
        final ov = _devicePriceOverrides[record.serialNumber];
        if (ov == null) return record;
        return record.withResolvedPricing(
          customerPrice: ov.customerPrice > 0 ? ov.customerPrice : record.resolvedCustomerPrice,
          matchedRule: 'Manual override',
          missingCode: false,
          missingRpc: false,
        ).copyWithMonthlyCost(ov.yourCost > 0 ? ov.yourCost : record.monthlyCost);
      }).toList();
      return CustomerGroup(customerName: group.customerName, devices: newDevices);
    }).toList();
  }

  bool get hasData => _parseResult != null && _customerGroups.isNotEmpty;

  /// Load device price overrides from storage on startup.
  Future<void> loadDevicePriceOverrides() async {
    _devicePriceOverrides = await DevicePriceOverrideService.loadAll();
    notifyListeners();
  }

  /// Set a manual price override for a device.
  ///
  /// The primary device ([serialNumber]) is always overridden.
  /// Pass [extraSerials] to also override a caller-selected list of sibling
  /// devices (the dialog builds this list after filtering out outliers, flagged
  /// devices, and devices that already have overrides).
  ///
  /// The legacy [spreadToSamePlan] / [customerName] / [ratePlan] path is kept
  /// for backwards-compatibility but is no longer used by the dialog.
  Future<int> setDevicePriceOverride(
    String serialNumber,
    double yourCost,
    double customerPrice, {
    List<String> extraSerials = const [],
    // legacy params kept for compat
    bool spreadToSamePlan = false,
    String? customerName,
    String? ratePlan,
  }) async {
    // Build the list of serials to override (always includes the target serial)
    final seriesToOverride = <String>{serialNumber};

    // Prefer the explicit list from the dialog
    if (extraSerials.isNotEmpty) {
      seriesToOverride.addAll(extraSerials);
    } else if (spreadToSamePlan && customerName != null && ratePlan != null && _state == AppState.loaded) {
      // Legacy fallback: collect all serials on the same plan
      final planNorm = ratePlan.trim().toLowerCase();
      for (final group in _customerGroups) {
        if (group.customerName == customerName) {
          for (final d in group.devices) {
            if (d.serialNumber != serialNumber &&
                d.ratePlan.trim().toLowerCase() == planNorm) {
              seriesToOverride.add(d.serialNumber);
            }
          }
          break;
        }
      }
    }

    // Save all overrides
    for (final s in seriesToOverride) {
      final ov = DevicePriceOverride(
        serialNumber: s,
        yourCost: yourCost,
        customerPrice: customerPrice,
      );
      await DevicePriceOverrideService.save(ov);
      _devicePriceOverrides[s] = ov;
    }

    // Apply immediately to the loaded data
    if (_state == AppState.loaded) {
      _applyDeviceOverrides();
      notifyListeners();
    }

    return seriesToOverride.length; // how many devices were updated
  }

  /// Clear the manual override for a device and re-price from rules.
  Future<void> clearDevicePriceOverride(String serialNumber) async {
    await DevicePriceOverrideService.clear(serialNumber);
    _devicePriceOverrides.remove(serialNumber);
    // Re-price from scratch without the override
    repriceCurrent();
  }

  /// Blank customer warnings from the last import
  List<BlankCustomerRecord> get blankCustomerWarnings =>
      _parseResult?.blankCustomers ?? [];

  List<CustomerGroup> get filteredGroups {
    // Filter out hidden customers first
    final visible = _customerGroups
        .where((g) => !_hiddenCustomers.contains(g.customerName))
        .toList();
    if (_searchQuery.isEmpty) return visible;
    final q = _searchQuery.toLowerCase();
    return visible.where((g) {
      if (g.customerName.toLowerCase().contains(q)) return true;
      return g.devices.any((d) =>
          d.serialNumber.toLowerCase().contains(q) ||
          d.ratePlan.toLowerCase().contains(q));
    }).toList();
  }

  double get grandTotalProrated =>
      _customerGroups.fold(0.0, (s, g) => s + g.totalProratedCost);

  double get grandTotalMonthly =>
      _customerGroups.fold(0.0, (s, g) => s + g.totalMonthlyCost);

  /// Grand total using customer billing prices (what you charge them)
  double get grandTotalCustomerPrice =>
      _customerGroups.fold(0.0, (s, g) => s + g.totalCustomerProratedCost);

  int get totalDeviceCount =>
      _customerGroups.fold(0, (s, g) => s + g.deviceCount);

  /// Any missing-code flags detected in the last import
  List<MissingCodeFlag> get missingCodeFlags =>
      _parseResult?.missingCodeFlags ?? [];

  List<MissingRpcFlag> get missingRpcFlags =>
      _parseResult?.missingRpcFlags ?? [];

  void setSearchQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  // ── Load all pricing data from Hive ──────────────────────────────────────

  void loadPricingData() {
    _standardRates = StandardPlanRateService.getAll();
    _customerPlanCodes = CustomerPlanCodeService.getAll();
    _qbCustomers = QbCustomerService.getAll();
    _ratePlanOverrides = CustomerRatePlanOverrideService.getAll();
    // Device price overrides are async — load separately via loadDevicePriceOverrides()
    notifyListeners();
  }

  PricingEngine get _pricingEngine => PricingEngine(
        standardRates: _standardRates,
        customerCodes: _customerPlanCodes,
        ratePlanOverrides: _ratePlanOverrides,
      );

  // ── CSV Import ────────────────────────────────────────────────────────────

  /// Load a CSV file.
  /// [isNewImport] = true  → user picked a new file; clears renames & hidden.
  /// [isNewImport] = false → internal re-parse (refresh / restore); preserves renames & hidden.
  Future<void> loadCsv(String fileName, String content,
      {bool isNewImport = true}) async {
    _state = AppState.loading;
    _errorMessage = '';
    notifyListeners();

    try {
      // Reload pricing data before parsing so prices are fresh
      loadPricingData();

      // Only wipe renames/hidden on a genuine new CSV import, not on
      // refresh/restore — those paths must preserve the user's edits.
      if (isNewImport) {
        _hiddenCustomers = {};
        _customerRenames = {};
        await _saveHidden();
        await _saveRenames();
      }

      final result = CsvParserService.parse(content, _pricingEngine);
      final groups = CsvParserService.groupByCustomer(result.records);

      _parseResult = result;
      _customerGroups = groups;
      _currentFileName = fileName;
      _searchQuery = '';
      _state = AppState.loaded;

      // Save to history
      final session = ImportSession(
        fileName: fileName,
        importedAt: DateTime.now(),
        reportDateFrom: result.dateFrom,
        reportDateTo: result.dateTo,
        totalDevices: result.records.length,
        totalCustomers: groups.length,
        totalProratedCost: groups.fold(0.0, (s, g) => s + g.totalProratedCost),
        rawCsvContent: content,
      );
      await HistoryService.saveSession(session);
      _history = HistoryService.getAllSessions();

      // Persist the CSV so it survives page refresh / app reopen
      await CsvPersistService.saveActivations(
        content:  content,
        fileName: fileName,
      );

      // Re-apply any saved customer renames on top of fresh parse,
      // then re-price so overrides using renamed names resolve correctly.
      _applyRenames();
      repriceCurrent();
    } catch (e) {
      _state = AppState.error;
      _errorMessage = 'Failed to parse CSV: $e';
    }

    notifyListeners();
  }

  /// Re-load a historical session for viewing
  void loadFromHistory(ImportSession session) {
    try {
      loadPricingData();
      final result = CsvParserService.parse(session.rawCsvContent, _pricingEngine);
      final groups = CsvParserService.groupByCustomer(result.records);
      _parseResult = result;
      _customerGroups = groups;
      _currentFileName = session.fileName;
      _searchQuery = '';
      _state = AppState.loaded;
    } catch (e) {
      _state = AppState.error;
      _errorMessage = 'Failed to reload session: $e';
    }
    notifyListeners();
  }

  void refreshHistory() {
    _history = HistoryService.getAllSessions();
    notifyListeners();
  }

  void initHistory() {
    _history = HistoryService.getAllSessions();
  }

  /// Re-price all currently loaded activation records with the latest pricing
  /// data — without re-parsing the CSV. Called automatically after any pricing
  /// change (standard rates, plan codes, overrides) so the Activations page
  /// always reflects the latest settings immediately.
  ///
  /// Also rebuilds missingCodeFlags and missingRpcFlags so warning banners
  /// clear automatically when the underlying issue is resolved.
  void repriceCurrent() {
    if (_state != AppState.loaded || _customerGroups.isEmpty) return;

    final engine = _pricingEngine;
    final newMissingCodes = <MissingCodeFlag>[];
    final newMissingRpcs  = <MissingRpcFlag>[];

    final repriced = _customerGroups.map((group) {
      final newDevices = group.devices.map((record) {
        final result = engine.resolve(record);

        // Rebuild warning flags live
        if (result.missingCode) {
          newMissingCodes.add(MissingCodeFlag(
            customerName: record.customer,
            serialNumber: record.serialNumber,
            ratePlan: record.ratePlan,
          ));
        }
        if (result.missingRpc) {
          newMissingRpcs.add(MissingRpcFlag(
            customerName: record.customer,
            serialNumber: record.serialNumber,
            ratePlan: record.ratePlan,
            requiredRpc: result.matchedRule.contains('"')
                ? RegExp(r'MISSING RPC "([^"]+)"')
                        .firstMatch(result.matchedRule)
                        ?.group(1) ?? ''
                : '',
          ));
        }

        return record.withResolvedPricing(
          customerPrice: result.customerPrice,
          matchedRule: result.matchedRule,
          missingCode: result.missingCode,
          missingRpc: result.missingRpc,
        );
      }).toList();
      return CustomerGroup(customerName: group.customerName, devices: newDevices);
    }).toList();

    _customerGroups = repriced;

    // Apply manual device price overrides last — they are always final
    _applyDeviceOverrides();

    // Update the parse result's warning flags so banners reflect current state
    if (_parseResult != null) {
      _parseResult = CsvParseResult(
        reportName: _parseResult!.reportName,
        reportDate: _parseResult!.reportDate,
        dateFrom: _parseResult!.dateFrom,
        dateTo: _parseResult!.dateTo,
        records: _parseResult!.records, // raw records unchanged
        skippedReasons: _parseResult!.skippedReasons,
        blankCustomers: _parseResult!.blankCustomers,
        missingCodeFlags: newMissingCodes,
        missingRpcFlags: newMissingRpcs,
      );
    }

    notifyListeners();
  }


  void loadCustomerRates() {
    _customerRates = CustomerRateService.getAllRates();
    notifyListeners();
  }

  Future<void> saveCustomerRate(CustomerRate rate) async {
    await CustomerRateService.saveRate(rate);
    _customerRates = CustomerRateService.getAllRates();
    notifyListeners();
  }

  Future<void> deleteCustomerRate(CustomerRate rate) async {
    await CustomerRateService.deleteRate(rate);
    _customerRates = CustomerRateService.getAllRates();
    notifyListeners();
  }

  Future<int> importCustomerRatesFromCsv(String content) async {
    final count = await CustomerRateService.importFromCsv(content);
    _customerRates = CustomerRateService.getAllRates();
    notifyListeners();
    return count;
  }

  // ── Standard Plan Rates ───────────────────────────────────────────────────

  Future<void> saveStandardRate(StandardPlanRate rate) async {
    await StandardPlanRateService.update(rate);
    _standardRates = StandardPlanRateService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> addStandardRate(StandardPlanRate rate) async {
    await StandardPlanRateService.add(rate);
    _standardRates = StandardPlanRateService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> deleteStandardRate(StandardPlanRate rate) async {
    await StandardPlanRateService.delete(rate);
    _standardRates = StandardPlanRateService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> resetStandardRates() async {
    await StandardPlanRateService.resetToDefaults();
    _standardRates = StandardPlanRateService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  // ── Customer Plan Codes ───────────────────────────────────────────────────

  Future<void> saveCustomerPlanCode(CustomerPlanCode code) async {
    await CustomerPlanCodeService.save(code);
    _customerPlanCodes = CustomerPlanCodeService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> deleteCustomerPlanCode(CustomerPlanCode code) async {
    await CustomerPlanCodeService.delete(code);
    _customerPlanCodes = CustomerPlanCodeService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  List<CustomerPlanCode> getPlanCodesForCustomer(String name) =>
      CustomerPlanCodeService.getForCustomer(name);

  /// Import pricing from a QuickBooks "Sales by Customer Detail" CSV.
  /// Returns {imported, updated, skipped, conflicts}.
  Future<Map<String, int>> importPricingFromQbSalesCsv(String csvContent) async {
    final counts =
        await CustomerPlanCodeService.importFromQbSalesCsvPreserveCase(csvContent);
    _customerPlanCodes = CustomerPlanCodeService.getAll();
    repriceCurrent(); // bulk import → immediately re-price activations
    notifyListeners();
    CloudSyncService.pushSilent();
    return counts;
  }

  // ── Rate Plan Overrides ─────────────────────────────────────────────────

  Future<void> saveRatePlanOverride(CustomerRatePlanOverride o) async {
    await CustomerRatePlanOverrideService.save(o);
    _ratePlanOverrides = CustomerRatePlanOverrideService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> deleteRatePlanOverride(CustomerRatePlanOverride o) async {
    await CustomerRatePlanOverrideService.delete(o);
    _ratePlanOverrides = CustomerRatePlanOverrideService.getAll();
    repriceCurrent();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  // ── QB Customers ──────────────────────────────────────────────────────────

  /// Import from raw bytes — preferred on web to avoid String.fromCharCodes encoding issues.
  Future<int> importQbCustomersFromBytes(List<int> bytes) async {
    final count = await QbCustomerService.importFromBytes(bytes);
    _qbCustomers = QbCustomerService.getAll();
    notifyListeners();
    // Persist the raw CSV permanently so it survives browser clear + app restarts.
    // We re-decode here with the same logic QbCustomerService uses (utf8 then latin1).
    try {
      String content;
      try {
        content = utf8.decode(bytes, allowMalformed: false);
      } catch (_) {
        content = latin1.decode(bytes);
      }
      await CsvPersistService.saveQbCustomerList(
        content: content,
        fileName: 'QB Customer List.csv',
      );
    } catch (_) {}
    CloudSyncService.pushSilent(); // back up QB customer list to cloud immediately
    return count;
  }

  Future<int> importQbCustomers(String csvContent) async {
    final count = await QbCustomerService.importFromCsv(csvContent);
    _qbCustomers = QbCustomerService.getAll();
    notifyListeners();
    // Persist the raw CSV permanently so it survives browser clear + app restarts.
    await CsvPersistService.saveQbCustomerList(
      content: csvContent,
      fileName: 'QB Customer List.csv',
    );
    CloudSyncService.pushSilent(); // back up QB customer list to cloud immediately
    return count;
  }

  /// Call after toggling CUA flag on a customer to refresh the QB Verify screen.
  void notifyQbCustomersChanged() {
    _qbCustomers = QbCustomerService.getAll();
    notifyListeners();
  }

  Future<void> clearQbCustomers() async {
    await QbCustomerService.clear();
    _qbCustomers = [];
    notifyListeners();
  }

  // ── Filter Settings ─────────────────────────────────────────────────────

  void refreshFilterRules() {
    // Filter rule changes affect which devices are shown — trigger a full
    // re-parse so the correct rows are included/excluded immediately.
    refreshCurrentData();
    CloudSyncService.pushSilent();
  }

  /// Called after QB ignore keywords change to push to cloud.
  void refreshQbIgnoreKeywords() {
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  // ── Refresh ───────────────────────────────────────────────────────────────

  /// Re-parse the current CSV content with fresh pricing & filter settings.
  /// This is a lightweight "soft refresh" — no file pick needed.
  Future<void> refreshCurrentData() async {
    if (_parseResult == null && _state != AppState.loaded) return;

    // 1. Try to find the raw CSV in the in-memory history
    String? rawContent;
    if (_history.isNotEmpty) {
      try {
        final session = _history.firstWhere(
          (s) => s.fileName == _currentFileName,
          orElse: () => _history.first,
        );
        rawContent = session.rawCsvContent;
      } catch (_) {}
    }

    // 2. Fall back to CsvPersistService (covers app-restored sessions)
    if (rawContent == null || rawContent.isEmpty) {
      final saved = await CsvPersistService.loadActivations();
      if (saved != null && saved.content.isNotEmpty) {
        rawContent = saved.content;
      }
    }

    if (rawContent == null || rawContent.isEmpty) return;
    // Pass isNewImport: false so renames and hidden customers are preserved
    // across the re-price — this is a refresh, not a new file import.
    await loadCsv(_currentFileName, rawContent, isNewImport: false);
  }

  /// On startup: restore the last imported Activations CSV from local storage
  /// so the dashboard shows data immediately without requiring a re-import.
  Future<void> restorePersistedData() async {
    // If data is already loaded (e.g. from history re-open), skip.
    if (_state == AppState.loaded) return;

    // ── Restore QB Customer List if Hive box is empty ─────────────────────
    // The raw CSV is stored in SharedPreferences as a permanent backup.
    // If the Hive box was cleared (browser clear, new device), re-import from
    // the persisted CSV so CUA flags and customer names are always available.
    // ── Restore QB Customer List if Hive box is empty ─────────────────────
    // Check the Hive box directly (not the in-memory list) so we don't
    // accidentally overwrite customers that were just restored from the cloud.
    // importFromCsv clears the box before importing, so it must ONLY run when
    // the box is truly empty — not just because _qbCustomers hasn't been
    // refreshed from Hive yet.
    if (QbCustomerService.box.isEmpty) {
      try {
        final saved = await CsvPersistService.loadQbCustomerList();
        if (saved != null && saved.content.isNotEmpty) {
          final count = await QbCustomerService.importFromCsv(saved.content);
          _qbCustomers = QbCustomerService.getAll();
          if (kDebugMode) {
            debugPrint('[AppProvider] QB Customer List restored from persist: $count customers');
          }
        }
      } catch (_) {
        // Silently ignore — user can re-import manually
      }
    } else {
      // Box has data (from cloud pull or previous import) — just refresh the list
      _qbCustomers = QbCustomerService.getAll();
    }

    // ── Restore Activations CSV ────────────────────────────────────────────
    // Re-enable: restore the last imported CSV so the dashboard is ready
    // immediately on app reopen, without requiring a re-import.
    // Renames and hidden customers are re-applied on top of the fresh parse.
    try {
      final saved = await CsvPersistService.loadActivations();
      if (saved != null && saved.content.isNotEmpty) {
        loadPricingData();
        final result =
            CsvParserService.parse(saved.content, _pricingEngine);
        final groups =
            CsvParserService.groupByCustomer(result.records);
        _parseResult    = result;
        _customerGroups = groups;
        _currentFileName = saved.fileName;
        _state = AppState.loaded;
        // Re-apply persisted renames so edited names are not lost
        _applyRenames();
        // Re-price with renamed customer names so overrides match correctly,
        // then apply serial-level device price overrides on top.
        repriceCurrent();
        if (kDebugMode) {
          debugPrint('[AppProvider] Activations restored from persist: '
              '${groups.length} customers');
        }
      }
    } catch (_) {
      // Silently ignore — user can re-import manually
    }
    notifyListeners();
  }

  // ── Item Price List ────────────────────────────────────────────────────────

  List<dynamic> get qbPriceItems => ItemPriceListService.getAll();

  /// Import the QB Item Price List CSV; returns count of items imported.
  Future<int> importItemPriceList(String csvContent) async {
    final count = await ItemPriceListService.importFromCsv(csvContent);
    notifyListeners();
    CloudSyncService.pushSilent(); // push to cloud immediately
    return count;
  }

  // ── Customer Name Rename ─────────────────────────────────────────────────

  static const _kRenamesKey = 'customer_renames_v1';
  static const _kHiddenKey  = 'hidden_customers_v1';

  /// Load persisted renames and hidden list from SharedPreferences.
  Future<void> loadCustomerOverrides() async {
    final prefs = await SharedPreferences.getInstance();

    // Renames: stored as JSON object {original: newName}
    final renamesJson = prefs.getString(_kRenamesKey);
    if (renamesJson != null && renamesJson.isNotEmpty) {
      try {
        final map = json.decode(renamesJson) as Map<String, dynamic>;
        _customerRenames = map.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        _customerRenames = {};
      }
    }

    // Hidden: stored as JSON array of customer display names
    final hiddenJson = prefs.getString(_kHiddenKey);
    if (hiddenJson != null && hiddenJson.isNotEmpty) {
      try {
        final list = json.decode(hiddenJson) as List<dynamic>;
        _hiddenCustomers = list.map((e) => e as String).toSet();
      } catch (_) {
        _hiddenCustomers = {};
      }
    }
  }

  Future<void> _saveRenames() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRenamesKey, json.encode(_customerRenames));
  }

  Future<void> _saveHidden() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHiddenKey, json.encode(_hiddenCustomers.toList()));
  }

  /// Apply the persisted rename map to the current in-memory groups.
  void _applyRenames() {
    if (_customerRenames.isEmpty) return;
    _customerGroups = _customerGroups.map((g) {
      final newName = _customerRenames[g.customerName];
      if (newName == null || newName == g.customerName) return g;
      final renamedDevices =
          g.devices.map((d) => d.copyWithCustomer(newName)).toList();
      return CustomerGroup(customerName: newName, devices: renamedDevices);
    }).toList();
    _customerGroups.sort((a, b) =>
        a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase()));
  }

  /// Rename a customer group from [oldName] to [newName], persist the mapping,
  /// and re-apply any device-price overrides so the override screen stays correct.
  ///
  /// Also updates the customerName field in any matching CustomerRatePlanOverrides
  /// and CustomerPlanCodes so pricing rules continue to resolve correctly after
  /// the customer is renamed.
  Future<void> renameCustomer(String oldName, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;

    // Update or insert rename: if oldName itself was already a rename target,
    // find the original key so we always map original → latest name.
    final originalKey = _customerRenames.entries
        .firstWhere((e) => e.value == oldName,
            orElse: () => MapEntry(oldName, oldName))
        .key;
    _customerRenames[originalKey] = trimmed;

    // Also update hidden set if this customer was hidden under the old name
    if (_hiddenCustomers.remove(oldName)) {
      _hiddenCustomers.add(trimmed);
    }

    _customerGroups = _customerGroups.map((g) {
      if (g.customerName != oldName) return g;
      final renamedDevices =
          g.devices.map((d) => d.copyWithCustomer(trimmed)).toList();
      return CustomerGroup(customerName: trimmed, devices: renamedDevices);
    }).toList();

    _customerGroups.sort((a, b) =>
        a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase()));

    // ── Update Rate Plan Overrides to use the new customer name ──────────
    // This ensures overrides continue to match after the customer is renamed.
    // The pricing engine does an exact (case-insensitive) name match, so stale
    // names cause overrides to silently stop working.
    final oldNorm = PricingEngine.normalizeCustomerName(oldName);
    final allOverrides = CustomerRatePlanOverrideService.getAll();
    for (final o in allOverrides) {
      if (PricingEngine.normalizeCustomerName(o.customerName) == oldNorm) {
        o.customerName  = trimmed;
        o.lastUpdated   = DateTime.now();
        await o.save(); // save in-place (HiveObject) to avoid duplicate insertion
      }
    }
    _ratePlanOverrides = CustomerRatePlanOverrideService.getAll();

    // ── Update Customer Plan Codes to use the new customer name ──────────
    final allCodes = CustomerPlanCodeService.getAll();
    for (final c in allCodes) {
      if (PricingEngine.normalizeCustomerName(c.customerName) == oldNorm) {
        c.customerName = trimmed;
        c.lastUpdated  = DateTime.now();
        await c.save(); // save in-place (HiveObject) to avoid duplicate insertion
      }
    }
    _customerPlanCodes = CustomerPlanCodeService.getAll();

    // Await both saves so the data is fully written to localStorage before
    // any potential page reload / navigation.
    await _saveRenames();
    await _saveHidden();

    // Re-price immediately so the renamed customer's overrides apply at once.
    repriceCurrent();

    // Push updated overrides/codes to cloud so other devices stay in sync.
    CloudSyncService.pushSilent();

    notifyListeners();
  }

  // ── Hide / Remove customer from Activations view ──────────────────────────

  /// Hide [customerName] from the Activations page (non-destructive).
  Future<void> hideCustomer(String customerName) async {
    _hiddenCustomers.add(customerName);
    await _saveHidden();
    notifyListeners();
  }

  /// Un-hide a previously hidden customer.
  Future<void> unhideCustomer(String customerName) async {
    _hiddenCustomers.remove(customerName);
    await _saveHidden();
    notifyListeners();
  }

  /// Un-hide all hidden customers at once.
  Future<void> unhideAllCustomers() async {
    _hiddenCustomers.clear();
    await _saveHidden();
    notifyListeners();
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  void clearCurrent() {
    _parseResult = null;
    _customerGroups = [];
    _currentFileName = '';
    _searchQuery = '';
    _hiddenCustomers = {};
    _customerRenames = {};
    _state = AppState.idle;
    // Clear persisted hidden/renames too so a future import starts clean
    _saveHidden();
    _saveRenames();
    CsvPersistService.clearActivations();
    notifyListeners();
  }
}
