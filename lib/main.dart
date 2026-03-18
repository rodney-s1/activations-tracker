import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'services/app_provider.dart';
import 'services/history_service.dart';
import 'services/filter_settings_service.dart';
import 'services/customer_rate_service.dart';
import 'services/standard_plan_rate_service.dart';
import 'services/customer_plan_code_service.dart';
import 'services/qb_customer_service.dart';
import 'services/qb_ignore_keyword_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/csv_persist_service.dart';
import 'screens/main_shell.dart';
import 'utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await HistoryService.init();
  await FilterSettingsService.init();
  await CustomerRateService.init();
  await StandardPlanRateService.init();
  await CustomerPlanCodeService.init();
  await QbCustomerService.init();
  await QbIgnoreKeywordService.init();
  await CloudSyncService.init(); // load saved Firebase config (if any)

  // Auto-pull from Firebase on startup if configured.
  // This restores all settings AND imported CSVs after a browser storage clear
  // or first load on a new device — silently in background.
  if (CloudSyncService.isConfigured) {
    await CloudSyncService.pullAll();
  }

  // ── Seed bundled QB Customer List on first install ────────────────────────
  // If no QB Customer List has ever been imported (neither in Hive nor in
  // SharedPreferences), load the bundled 3-18-2026 CSV from app assets.
  // On subsequent launches the persisted CSV or cloud-pulled data takes over.
  await _seedBundledQbCustomerList();

  // Build provider first so restorePersistedData can notify listeners
  final provider = AppProvider()
    ..initHistory()
    ..loadCustomerRates()
    ..loadPricingData()
    ..startSyncCountdown();

  // Wire periodic pull callback so pulled data refreshes the UI automatically
  CloudSyncService.onPeriodicPullComplete = () {
    provider.loadPricingData();
    provider.notifyQbCustomersChanged();
  };

  // Restore last imported Activations CSV (if any) from local storage.
  // This runs AFTER cloud pull so cloud data takes precedence.
  await provider.restorePersistedData();

  runApp(
    ChangeNotifierProvider.value(
      value: provider,
      child: const ActivationTrackerApp(),
    ),
  );
}

/// Seed the bundled QB Customer List from assets on first install.
/// Only runs if the Hive box is empty AND no persisted CSV exists.
/// This guarantees CUA flags are always set correctly from day one.
Future<void> _seedBundledQbCustomerList() async {
  try {
    // Check if we already have data (Hive or persisted CSV)
    if (QbCustomerService.box.isNotEmpty) return;
    final existing = await CsvPersistService.loadQbCustomerList();
    if (existing != null && existing.content.isNotEmpty) {
      // Re-import from persisted CSV (handles browser-clear scenario)
      await QbCustomerService.importFromCsv(existing.content);
      return;
    }

    // No data anywhere — load bundled CSV from assets
    final csvContent = await rootBundle
        .loadString('assets/data/qb_customer_list.csv');
    if (csvContent.isNotEmpty) {
      await QbCustomerService.importFromCsv(csvContent);
      // Persist so it survives next browser clear
      await CsvPersistService.saveQbCustomerList(
        content: csvContent,
        fileName: 'QB Customer List 3-18-2026.csv',
      );
      if (const bool.fromEnvironment('dart.vm.product') == false) {
        // ignore: avoid_print
        print('[main] Seeded ${QbCustomerService.box.length} QB customers from bundled asset');
      }
    }
  } catch (e) {
    // Non-fatal — user can always import manually via Settings
    if (const bool.fromEnvironment('dart.vm.product') == false) {
      // ignore: avoid_print
      print('[main] Could not seed bundled QB customer list: $e');
    }
  }
}

class ActivationTrackerApp extends StatelessWidget {
  const ActivationTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Activation Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const MainShell(),
    );
  }
}
