import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'services/app_provider.dart';
import 'services/history_service.dart';
import 'services/filter_settings_service.dart';
import 'services/customer_rate_service.dart';
import 'services/standard_plan_rate_service.dart';
import 'services/customer_plan_code_service.dart';
import 'services/qb_customer_service.dart';
import 'services/cloud_sync_service.dart';
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
  await CloudSyncService.init(); // load saved Firebase config (if any)

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppProvider()
        ..initHistory()
        ..loadCustomerRates()
        ..loadPricingData()
        ..startSyncCountdown(), // starts the 1-min countdown ticker for Cloud Sync UI
      child: const ActivationTrackerApp(),
    ),
  );
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
