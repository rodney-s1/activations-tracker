// Cloud Sync Screen
//
// Credentials are baked into the app — no user configuration required.
// Every signed-in @bluearrowmail.com user is automatically connected and
// syncing to the shared Firebase Realtime Database.
//
// This screen only exposes:
//   • Live connection status
//   • Last sync / next auto-sync countdown
//   • Manual Push / Pull buttons
//   • Auto-sync every-3-min toggle

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../services/cloud_sync_service.dart';
import '../services/customer_rate_plan_override_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  bool    _autoSync  = true;
  bool    _loading   = false;
  String? _statusMsg;
  bool    _statusOk  = true;

  @override
  void initState() {
    super.initState();
    _autoSync = CloudSyncService.autoSync;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppProvider>().startSyncCountdown();
    });
    CloudSyncService.statusNotifier.addListener(_onStatusChanged);
  }

  @override
  void dispose() {
    CloudSyncService.statusNotifier.removeListener(_onStatusChanged);
    super.dispose();
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  // ── Auto-sync toggle ───────────────────────────────────────────────────────

  Future<void> _toggleAutoSync(bool value) async {
    setState(() => _autoSync = value);
    await CloudSyncService.setAutoSync(value);
  }

  // ── Manual push ────────────────────────────────────────────────────────────

  Future<void> _push() async {
    setState(() { _loading = true; _statusMsg = null; });
    final err = await CloudSyncService.pushAll();
    if (!mounted) return;
    final overrideCount = err == null
        ? CustomerRatePlanOverrideService.getAll().length
        : 0;
    setState(() {
      _loading   = false;
      _statusMsg = err == null
          ? 'All settings pushed to cloud successfully'
            '${overrideCount > 0 ? ' ($overrideCount pricing overrides included)' : ''}.'
          : 'Push failed: $err';
      _statusOk  = err == null;
    });
  }

  // ── Manual pull ────────────────────────────────────────────────────────────

  Future<void> _pull() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pull from Cloud?'),
        content: const Text(
          'This will replace your local settings with the shared cloud version:\n\n'
          '• Standard plan rates\n'
          '• Customer plan codes\n'
          '• Rate plan overrides (pricing)\n'
          '• Serial filter rules\n'
          '• QB customers & filter keywords\n'
          '• Item price list\n'
          '• Activations CSV (last imported)\n'
          '• MyAdmin & QB Verify CSVs (last imported)\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
            child: const Text('Pull & Replace'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() { _loading = true; _statusMsg = null; });
    final result = await CloudSyncService.pullAll();
    if (!mounted) return;

    final provider = context.read<AppProvider>();
    provider.loadPricingData();
    provider.repriceCurrent();
    provider.notifyQbCustomersChanged();

    if (result.containsKey('error')) {
      setState(() {
        _loading   = false;
        _statusMsg = 'Pull failed: ${result['error']}';
        _statusOk  = false;
      });
    } else {
      final counts         = result['counts'] as Map<String, int>? ?? {};
      final overrideCount  = counts['ratePlanOverrides'] ?? 0;
      final csvRestored    = (counts['importedCsvs']     ?? 0) > 0;
      final qbRestored     = (counts['qbCustomers']      ?? 0) > 0;
      final kwRestored     = (counts['qbIgnoreKeywords'] ?? 0) > 0;
      setState(() {
        _loading   = false;
        _statusMsg =
            'Pulled: ${counts['standardPlanRates'] ?? 0} plan rates, '
            '${counts['customerPlanCodes'] ?? 0} customer codes, '
            '${counts['serialFilterRules'] ?? 0} filter rules'
            '${overrideCount > 0 ? ', $overrideCount pricing overrides' : ''}'
            '${csvRestored ? ', + CSV files' : ''}'
            '${qbRestored  ? ', ${counts['qbCustomers']} QB customers' : ''}'
            '${kwRestored  ? ', ${counts['qbIgnoreKeywords']} QB filter keywords' : ''}.';
        _statusOk = true;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    context.watch<AppProvider>(); // subscribe for countdown ticker rebuilds

    final status = CloudSyncService.status;
    final last   = CloudSyncService.lastSyncAt;
    final next   = CloudSyncService.nextSyncIn;
    final autoOn = CloudSyncService.autoSync;

    // Status dot
    Color  dotColor;
    String statusLabel;
    switch (status) {
      case SyncStatus.syncing:
        dotColor    = AppTheme.amber;
        statusLabel = 'Syncing…';
        break;
      case SyncStatus.success:
        dotColor    = AppTheme.green;
        statusLabel = 'Connected · up to date';
        break;
      case SyncStatus.error:
        dotColor    = AppTheme.red;
        statusLabel = 'Sync error — tap Push/Pull to retry';
        break;
      case SyncStatus.notConfigured:
        dotColor    = AppTheme.amber;
        statusLabel = 'Connecting…';
        break;
      default:
        dotColor    = AppTheme.green;
        statusLabel = 'Connected · idle';
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [

        // ── Hero status card ────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.navyDark, AppTheme.navyMid],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Animated status dot
                  Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                      boxShadow: [
                        BoxShadow(
                          color: dotColor.withValues(alpha: 0.55),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Shared across all BlueArrow users · auto-configured',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(height: 14),
              // Last sync / next sync pills
              Row(
                children: [
                  _InfoPill(
                    icon: Icons.history,
                    label: 'Last sync',
                    value: last == null ? 'Never' : Formatters.dateTime(last),
                    color: AppTheme.tealLight,
                  ),
                  const SizedBox(width: 10),
                  _InfoPill(
                    icon: Icons.schedule,
                    label: 'Next auto',
                    value: autoOn
                        ? (next == Duration.zero
                            ? 'pending'
                            : next.inMinutes > 0
                                ? '${next.inMinutes}m ${next.inSeconds % 60}s'
                                : '${next.inSeconds}s')
                        : 'off',
                    color: autoOn ? AppTheme.amber : Colors.white30,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ── Auto-sync toggle ────────────────────────────────────────────────
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            secondary: Icon(
              Icons.alarm,
              color: _autoSync ? AppTheme.amber : Colors.grey,
            ),
            title: const Text(
              'Auto-sync every 3 minutes',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            subtitle: Text(
              _autoSync
                  ? 'Pulls latest data from cloud every 3 min — all users stay in sync automatically.'
                  : 'Disabled — use Push below to sync manually.',
              style: const TextStyle(fontSize: 12),
            ),
            value: _autoSync,
            activeColor: AppTheme.amber,
            onChanged: _loading ? null : _toggleAutoSync,
          ),
        ),

        const SizedBox(height: 12),

        // ── Push / Pull action row ──────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: _ActionButton(
                icon: Icons.upload_rounded,
                label: 'Push to Cloud',
                sublabel: 'Save settings + CSVs now',
                color: AppTheme.teal,
                loading: _loading,
                onTap: _loading ? null : _push,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionButton(
                icon: Icons.download_rounded,
                label: 'Pull from Cloud',
                sublabel: 'Restore settings + CSVs',
                color: AppTheme.navyAccent,
                loading: false,
                onTap: _loading ? null : _pull,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Info note
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.amber.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.amber.withValues(alpha: 0.2)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 13, color: AppTheme.amber),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Settings are automatically saved to the shared cloud whenever you '
                  'import files or make changes. All signed-in users see the same '
                  'pricing overrides, plan rates, and QB data.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),

        // ── Status banner ───────────────────────────────────────────────────
        if (_statusMsg != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (_statusOk ? AppTheme.green : AppTheme.red)
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (_statusOk ? AppTheme.green : AppTheme.red)
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _statusOk
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  size: 15,
                  color: _statusOk ? AppTheme.green : AppTheme.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMsg!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _statusOk ? AppTheme.green : AppTheme.red,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 32),
      ],
    );
  }
}

// ── Info pill ──────────────────────────────────────────────────────────────────

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color    color;

  const _InfoPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 9, color: color.withValues(alpha: 0.7))),
              Text(value,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Action button ──────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData      icon;
  final String        label;
  final String        sublabel;
  final Color         color;
  final bool          loading;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            loading
                ? SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color))
                : Icon(icon, color: color, size: 26),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color)),
            Text(sublabel,
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textSecondary),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
