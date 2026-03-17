// Main shell — bottom navigation bar wrapping all top-level screens

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../utils/app_theme.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'serial_filter_screen.dart';
import 'customer_pricing_screen.dart';
import 'qb_invoice_screen.dart';
import 'cloud_sync_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // Keep pages alive between tab switches
  static const _pages = [
    _KeepAlive(child: DashboardScreen()),
    _KeepAlive(child: HistoryScreen()),
    _KeepAlive(child: SerialFilterScreen()),
    _KeepAlive(child: CustomerPricingScreen()),
    _KeepAlive(child: QbInvoiceScreen()),
    _KeepAlive(child: CloudSyncScreen()),
    _KeepAlive(child: SettingsScreen()),
  ];

  static const _navItems = [
    BottomNavigationBarItem(
      icon: Icon(Icons.dashboard_outlined),
      activeIcon: Icon(Icons.dashboard),
      label: 'Dashboard',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.history_outlined),
      activeIcon: Icon(Icons.history),
      label: 'History',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.filter_list_outlined),
      activeIcon: Icon(Icons.filter_list),
      label: 'Filters',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.price_change_outlined),
      activeIcon: Icon(Icons.price_change),
      label: 'Pricing',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.verified_outlined),
      activeIcon: Icon(Icons.verified),
      label: 'QB Verify',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.cloud_upload_outlined),
      activeIcon: Icon(Icons.cloud_upload),
      label: 'Cloud Sync',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.settings_outlined),
      activeIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // Show a badge on the Dashboard tab if there are warnings
    final provider = context.watch<AppProvider>();
    final hasWarnings = provider.blankCustomerWarnings.isNotEmpty ||
        provider.missingCodeFlags.isNotEmpty;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppTheme.navyDark,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: List.generate(_navItems.length, (i) {
                final item = _navItems[i];
                final isActive = _currentIndex == i;
                // Badge on dashboard tab when warnings exist
                final showBadge = i == 0 && hasWarnings;

                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _currentIndex = i),
                    splashColor: AppTheme.teal.withValues(alpha: 0.2),
                    highlightColor: Colors.transparent,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: isActive
                                ? AppTheme.teal
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: IconTheme(
                                  key: ValueKey(isActive),
                                  data: IconThemeData(
                                    color: isActive
                                        ? AppTheme.tealLight
                                        : Colors.white38,
                                    size: 22,
                                  ),
                                  child: isActive
                                      ? item.activeIcon
                                      : item.icon,
                                ),
                              ),
                              if (showBadge)
                                Positioned(
                                  right: -4,
                                  top: -3,
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    decoration: const BoxDecoration(
                                      color: AppTheme.amber,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: isActive
                                  ? AppTheme.tealLight
                                  : Colors.white38,
                            ),
                            child: Text((item.label ?? '')),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps a subtree alive in the IndexedStack so state is preserved
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
