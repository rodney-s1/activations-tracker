import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'services/app_provider.dart';
import 'services/auth_service.dart';
import 'services/history_service.dart';
import 'services/filter_settings_service.dart';
import 'services/customer_rate_service.dart';
import 'services/standard_plan_rate_service.dart';
import 'services/customer_plan_code_service.dart';
import 'services/qb_customer_service.dart';
import 'services/qb_ignore_keyword_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/csv_persist_service.dart';
import 'services/customer_rate_plan_override_service.dart';
import 'services/item_price_list_service.dart';
import 'services/plan_mapping_service.dart';
import 'services/fuel_alias_service.dart';
import 'screens/login_screen.dart';
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
  await CloudSyncService.init();
  await CustomerRatePlanOverrideService.init();
  await ItemPriceListService.init();
  await PlanMappingService.init();
  await FuelAliasService.instance.init();

  // Initialise Google Sign-In — attempts silent restore of previous session.
  await AuthService.instance.init();

  // Only pull cloud data / seed defaults if user is already signed in.
  if (AuthService.instance.isSignedIn) {
    await _initAppData();
  }

  final provider = AppProvider()
    ..initHistory()
    ..loadCustomerRates()
    ..loadPricingData()
    ..startSyncCountdown();

  // Load manual device price overrides (async — must be awaited separately)
  await provider.loadDevicePriceOverrides();

  // Load manual plan text overrides
  await provider.loadPlanOverrides();

  // Load persisted customer renames and hidden list
  await provider.loadCustomerOverrides();

  CloudSyncService.onPeriodicPullComplete = () {
    provider.loadPricingData(); // refreshes standardRates, planCodes, overrides, qbCustomers
    provider.repriceCurrent();  // immediately re-price any loaded activations
  };

  if (AuthService.instance.isSignedIn) {
    await provider.restorePersistedData();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: provider),
        ChangeNotifierProvider.value(value: AuthService.instance),
      ],
      child: const ActivationTrackerApp(),
    ),
  );
}

/// Runs cloud pull + QB seed — called after confirmed sign-in.
Future<void> _initAppData() async {
  if (CloudSyncService.isConfigured) {
    await CloudSyncService.pullAll();
  }
  await _seedBundledQbCustomerList();
}

/// Seed the bundled QB Customer List from assets on first install.
Future<void> _seedBundledQbCustomerList() async {
  try {
    if (QbCustomerService.box.isNotEmpty) return;
    final existing = await CsvPersistService.loadQbCustomerList();
    if (existing != null && existing.content.isNotEmpty) {
      await QbCustomerService.importFromCsv(existing.content);
      return;
    }
    final csvContent =
        await rootBundle.loadString('assets/data/qb_customer_list.csv');
    if (csvContent.isNotEmpty) {
      await QbCustomerService.importFromCsv(csvContent);
      await CsvPersistService.saveQbCustomerList(
        content: csvContent,
        fileName: 'QB Customer List 3-18-2026.csv',
      );
    }
  } catch (e) {
    if (const bool.fromEnvironment('dart.vm.product') == false) {
      // ignore: avoid_print
      print('[main] Could not seed bundled QB customer list: $e');
    }
  }
}

// ── Root App Widget ───────────────────────────────────────────────────────────

class ActivationTrackerApp extends StatelessWidget {
  const ActivationTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Activation Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const _AuthGate(),
    );
  }
}

// ── Auth Gate ─────────────────────────────────────────────────────────────────
// Watches AuthService and routes to LoginScreen or MainShell accordingly.
// When a user successfully signs in, it also runs the first-time data init
// (cloud pull + QB seed) so data is available immediately after login.

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _dataInitDone = false;

  @override
  void initState() {
    super.initState();
    // If already signed in from silent restore, mark data as ready
    // (it was loaded in main() above).
    if (AuthService.instance.isSignedIn) {
      _dataInitDone = true;
    }
    // Listen for sign-in events to trigger data init
    AuthService.instance.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    final auth = AuthService.instance;
    if (auth.isSignedIn && !_dataInitDone) {
      _dataInitDone = true;
      // Run data init after first successful login (not silent restore)
      _initAfterLogin();
    }
    if (!auth.isSignedIn) {
      setState(() => _dataInitDone = false);
    }
  }

  Future<void> _initAfterLogin() async {
    await _initAppData();
    if (!mounted) return;
    final provider = context.read<AppProvider>();
    provider.loadPricingData();
    provider.notifyQbCustomersChanged();
    await provider.restorePersistedData();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    if (auth.isLoading) {
      // Startup silent-sign-in in progress — show branded splash
      return const _SplashScreen();
    }

    if (!auth.isSignedIn) {
      return const LoginScreen();
    }

    return const MainShell();
  }
}

// ── Splash Screen (shown during silent sign-in check) ────────────────────────

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.teal.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppTheme.teal.withValues(alpha: 0.4), width: 1.5),
              ),
              child: const Icon(Icons.location_on,
                  size: 36, color: AppTheme.tealLight),
            ),
            const SizedBox(height: 24),
            const Text(
              'Activation Tracker',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppTheme.tealLight),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
