// App-wide state provider

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/customer_group.dart';
import '../models/import_session.dart';
import '../models/customer_rate.dart';
import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../models/qb_customer.dart';
import '../services/csv_parser_service.dart';
import '../services/history_service.dart';
import '../services/customer_rate_service.dart';
import '../services/standard_plan_rate_service.dart';
import '../services/customer_plan_code_service.dart';
import '../services/qb_customer_service.dart';
import '../services/pricing_engine.dart';
import '../services/cloud_sync_service.dart';
import '../services/csv_persist_service.dart';
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

  bool get hasData => _parseResult != null && _customerGroups.isNotEmpty;

  /// Blank customer warnings from the last import
  List<BlankCustomerRecord> get blankCustomerWarnings =>
      _parseResult?.blankCustomers ?? [];

  List<CustomerGroup> get filteredGroups {
    if (_searchQuery.isEmpty) return _customerGroups;
    final q = _searchQuery.toLowerCase();
    return _customerGroups.where((g) {
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
    notifyListeners();
  }

  PricingEngine get _pricingEngine => PricingEngine(
        standardRates: _standardRates,
        customerCodes: _customerPlanCodes,
      );

  // ── CSV Import ────────────────────────────────────────────────────────────

  Future<void> loadCsv(String fileName, String content) async {
    _state = AppState.loading;
    _errorMessage = '';
    notifyListeners();

    try {
      // Reload pricing data before parsing so prices are fresh
      loadPricingData();

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

  // ── Customer Rates (legacy rate book) ──────────────────────────────────────

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
    notifyListeners();
    CloudSyncService.pushSilent(); // persist change to cloud immediately
  }

  Future<void> addStandardRate(StandardPlanRate rate) async {
    await StandardPlanRateService.add(rate);
    _standardRates = StandardPlanRateService.getAll();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> deleteStandardRate(StandardPlanRate rate) async {
    await StandardPlanRateService.delete(rate);
    _standardRates = StandardPlanRateService.getAll();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> resetStandardRates() async {
    await StandardPlanRateService.resetToDefaults();
    _standardRates = StandardPlanRateService.getAll();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  // ── Customer Plan Codes ───────────────────────────────────────────────────

  Future<void> saveCustomerPlanCode(CustomerPlanCode code) async {
    await CustomerPlanCodeService.save(code);
    _customerPlanCodes = CustomerPlanCodeService.getAll();
    notifyListeners();
    CloudSyncService.pushSilent();
  }

  Future<void> deleteCustomerPlanCode(CustomerPlanCode code) async {
    await CustomerPlanCodeService.delete(code);
    _customerPlanCodes = CustomerPlanCodeService.getAll();
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
    notifyListeners();
    CloudSyncService.pushSilent(); // push updated plan codes to cloud
    return counts;
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
    notifyListeners();
    CloudSyncService.pushSilent(); // persist filter rule changes to cloud
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
    if (_parseResult == null) return;

    // We need the original raw content. It's stored in the last history session.
    // Grab it from the most recent session that matches the current filename.
    final session = _history.firstWhere(
      (s) => s.fileName == _currentFileName,
      orElse: () => _history.first,
    );

    await loadCsv(_currentFileName, session.rawCsvContent);
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
    final saved = await CsvPersistService.loadActivations();
    if (saved == null || saved.content.isEmpty) return;

    try {
      loadPricingData();
      final result = CsvParserService.parse(saved.content, _pricingEngine);
      final groups = CsvParserService.groupByCustomer(result.records);
      _parseResult     = result;
      _customerGroups  = groups;
      _currentFileName = saved.fileName;
      _searchQuery     = '';
      _state           = AppState.loaded;
    } catch (_) {
      // Silently ignore restore errors — user can re-import manually
    }
    notifyListeners();
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  void clearCurrent() {
    _parseResult = null;
    _customerGroups = [];
    _currentFileName = '';
    _searchQuery = '';
    _state = AppState.idle;
    notifyListeners();
  }
}
