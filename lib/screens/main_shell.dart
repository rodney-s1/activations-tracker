// Main shell — bottom navigation bar wrapping all top-level screens

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../services/auth_service.dart';
import '../utils/app_theme.dart';
import 'activations_shell.dart';
import 'qb_invoice_screen.dart';
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
    _KeepAlive(child: ActivationsShell()),
    _KeepAlive(child: QbInvoiceScreen()),
    _KeepAlive(child: SettingsScreen()),
  ];

  static const _navItems = [
    BottomNavigationBarItem(
      icon: Icon(Icons.upload_file_outlined),
      activeIcon: Icon(Icons.upload_file),
      label: 'Activations',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.verified_outlined),
      activeIcon: Icon(Icons.verified),
      label: 'QB Verify',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.settings_outlined),
      activeIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // Show a badge on the Activations tab if there are warnings
    final provider = context.watch<AppProvider>();
    final hasWarnings = provider.blankCustomerWarnings.isNotEmpty ||
        provider.missingCodeFlags.isNotEmpty;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      // User identity bar at top
      appBar: _UserBar(email: AuthService.instance.currentUser?.email ?? ''),
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
                // Badge on Activations tab when warnings exist
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

// ── User identity bar ─────────────────────────────────────────────────────────

class _UserBar extends StatelessWidget implements PreferredSizeWidget {
  final String email;
  const _UserBar({required this.email});

  @override
  Size get preferredSize => const Size.fromHeight(38);

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    final initials = user != null && user.displayName.isNotEmpty
        ? user.displayName.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase()
        : (email.isNotEmpty ? email[0].toUpperCase() : '?');

    return Container(
      height: 38,
      color: AppTheme.navyMid,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.location_on, size: 14, color: AppTheme.tealLight),
          const SizedBox(width: 6),
          const Text(
            'Activation Tracker',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.tealLight,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          // Avatar
          CircleAvatar(
            radius: 12,
            backgroundColor: AppTheme.teal.withValues(alpha: 0.25),
            backgroundImage: (user?.photoUrl.isNotEmpty == true)
                ? NetworkImage(user!.photoUrl)
                : null,
            child: (user?.photoUrl.isNotEmpty != true)
                ? Text(initials,
                    style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.tealLight))
                : null,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              email,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Sign out button
          Tooltip(
            message: 'Sign out',
            child: InkWell(
              onTap: () => _confirmSignOut(context),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.logout,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(width: 3),
                    Text('Sign out',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withValues(alpha: 0.5))),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out?'),
        content: Text('Sign out of $email?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              AuthService.instance.signOut();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Sign Out'),
          ),
        ],
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
