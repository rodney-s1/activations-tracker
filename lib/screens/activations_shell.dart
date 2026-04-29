// Activations shell — wraps Activations, History, Filters, and Pricing
// as sub-tabs so the top-level nav stays clean.

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'serial_filter_screen.dart';
import 'customer_pricing_screen.dart';

class ActivationsShell extends StatefulWidget {
  const ActivationsShell({super.key});

  @override
  State<ActivationsShell> createState() => _ActivationsShellState();
}

class _ActivationsShellState extends State<ActivationsShell>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Sub-tab bar sits at the very top of the content area
        Container(
          color: AppTheme.navyDark,
          child: TabBar(
            controller: _tabs,
            labelColor: AppTheme.tealLight,
            unselectedLabelColor: Colors.white38,
            indicatorColor: AppTheme.teal,
            indicatorWeight: 2.5,
            isScrollable: false,
            tabs: const [
              Tab(
                icon: Icon(Icons.upload_file_outlined, size: 17),
                text: 'Activations',
                iconMargin: EdgeInsets.only(bottom: 2),
              ),
              Tab(
                icon: Icon(Icons.history_outlined, size: 17),
                text: 'History',
                iconMargin: EdgeInsets.only(bottom: 2),
              ),
              Tab(
                icon: Icon(Icons.filter_list_outlined, size: 17),
                text: 'Filters',
                iconMargin: EdgeInsets.only(bottom: 2),
              ),
              Tab(
                icon: Icon(Icons.price_change_outlined, size: 17),
                text: 'Pricing',
                iconMargin: EdgeInsets.only(bottom: 2),
              ),
            ],
          ),
        ),

        // TabBarView only renders the active tab — inactive tabs are NOT
        // kept in the widget tree, so they cannot absorb drag/drop events
        // intended for other top-level screens (e.g. QB Verify DropTargets).
        // AutomaticKeepAlive inside each screen handles state preservation.
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [
              _KeepAlive(child: DashboardScreen()),
              _KeepAlive(child: HistoryScreen()),
              _KeepAlive(child: SerialFilterScreen()),
              _KeepAlive(child: CustomerPricingScreen()),
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps a subtree alive between tab switches via AutomaticKeepAliveClientMixin.
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
