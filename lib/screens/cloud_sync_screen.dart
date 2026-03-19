// Cloud Sync Screen — simplified, user-friendly view.
// The Firebase credentials are stored securely in SharedPreferences and never
// shown in plain text on screen. The user only sees connection status,
// sync timestamps, and simple action buttons.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
// import '../services/auth_service.dart'; // removed — shared data path, no per-user ID needed
import '../services/cloud_sync_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  // Credential fields — only shown inside the collapsed "Advanced" section
  final _dbUrlCtrl  = TextEditingController();
  final _apiKeyCtrl = TextEditingController();

  bool    _enabled      = false;
  bool    _autoSync     = true;
  bool    _loading      = false;
  bool    _saved        = false;
  bool    _showAdvanced = false; // credentials panel hidden by default
  String? _statusMsg;
  bool    _statusOk     = true;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppProvider>().startSyncCountdown();
    });
    CloudSyncService.statusNotifier.addListener(_onStatusChanged);
  }

  @override
  void dispose() {
    CloudSyncService.statusNotifier.removeListener(_onStatusChanged);
    _dbUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSaved() async {
    final cfg = await CloudSyncService.readConfig();
    if (!mounted) return;
    setState(() {
      _dbUrlCtrl.text  = cfg['dbUrl']   ?? '';
      _apiKeyCtrl.text = cfg['apiKey']  ?? '';
      _enabled         = cfg['enabled'] == 'true';
      _autoSync        = cfg['autoSync'] != 'false';
      _saved           = _dbUrlCtrl.text.isNotEmpty;
    });
  }

  // ── Save credentials (hidden advanced panel) ──────────────────────────────

  Future<void> _saveAndConnect() async {
    if (_dbUrlCtrl.text.trim().isEmpty) {
      setState(() {
        _statusMsg = 'Database URL is required.';
        _statusOk  = false;
      });
      return;
    }
    setState(() { _loading = true; _statusMsg = null; });

    final err = await CloudSyncService.configure(
      dbUrl:    _dbUrlCtrl.text.trim(),
      apiKey:   _apiKeyCtrl.text.trim(),
      enabled:  _enabled,
      autoSync: _autoSync,
    );

    if (err != null) {
      setState(() {
        _loading   = false;
        _statusMsg = 'Connection failed: $err';
        _statusOk  = false;
      });
      return;
    }

    if (_enabled) {
      final ok = await CloudSyncService.testConnection();
      setState(() {
        _loading      = false;
        _saved        = true;
        _showAdvanced = false; // collapse after successful save
        _statusMsg    = ok
            ? 'Connected! Settings will sync automatically.'
            : 'Saved, but could not reach the database. Check your URL and Rules.';
        _statusOk = ok;
      });
    } else {
      setState(() {
        _loading      = false;
        _saved        = true;
        _showAdvanced = false;
        _statusMsg    = 'Cloud sync is disabled. Settings saved.';
        _statusOk     = true;
      });
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _enabled = value);
    if (_saved && _dbUrlCtrl.text.isNotEmpty) {
      await CloudSyncService.configure(
        dbUrl:    _dbUrlCtrl.text.trim(),
        apiKey:   _apiKeyCtrl.text.trim(),
        enabled:  value,
        autoSync: _autoSync,
      );
    }
  }

  Future<void> _toggleAutoSync(bool value) async {
    setState(() => _autoSync = value);
    await CloudSyncService.setAutoSync(value);
  }

  // ── Manual push ───────────────────────────────────────────────────────────

  Future<void> _push() async {
    setState(() { _loading = true; _statusMsg = null; });
    final err = await CloudSyncService.pushAll();
    if (!mounted) return;
    setState(() {
      _loading   = false;
      _statusMsg = err == null
          ? 'All settings pushed to cloud successfully.'
          : 'Push failed: $err';
      _statusOk  = err == null;
    });
  }

  // ── Manual pull ───────────────────────────────────────────────────────────

  Future<void> _pull() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pull from Cloud?'),
        content: const Text(
          'This will replace your local settings and CSV files with the cloud version:\n'
          '• Standard plan rates\n'
          '• Customer plan codes\n'
          '• Serial filter rules\n'
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
    provider.notifyQbCustomersChanged(); // refresh QB customer list from Hive

    if (result.containsKey('error')) {
      setState(() {
        _loading   = false;
        _statusMsg = 'Pull failed: ${result['error']}';
        _statusOk  = false;
      });
    } else {
      final counts = result['counts'] as Map<String, int>? ?? {};
      final csvRestored  = (counts['importedCsvs']      ?? 0) > 0;
      final qbRestored   = (counts['qbCustomers']       ?? 0) > 0;
      final kwRestored   = (counts['qbIgnoreKeywords']  ?? 0) > 0;
      setState(() {
        _loading   = false;
        _statusMsg =
            'Pulled: ${counts['standardPlanRates'] ?? 0} plan rates, '
            '${counts['customerPlanCodes'] ?? 0} customer codes, '
            '${counts['serialFilterRules'] ?? 0} filter rules'
            '${csvRestored ? ', + CSV files' : ''}'
            '${qbRestored ? ', ${counts['qbCustomers']} QB customers' : ''}'
            '${kwRestored ? ', ${counts['qbIgnoreKeywords']} QB filter keywords' : ''}.';
        _statusOk = true;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    context.watch<AppProvider>(); // subscribe for countdown ticker rebuilds

    final configured = CloudSyncService.isConfigured;
    final status     = CloudSyncService.status;
    final last       = CloudSyncService.lastSyncAt;
    final next       = CloudSyncService.nextSyncIn;
    final autoOn     = CloudSyncService.autoSync && configured;

    // Status dot colour
    Color dotColor;
    String statusLabel;
    if (!configured || !_enabled) {
      dotColor    = Colors.white24;
      statusLabel = _saved ? 'Sync disabled' : 'Not configured';
    } else {
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
          statusLabel = 'Sync error';
          break;
        default:
          dotColor    = AppTheme.green;
          statusLabel = 'Connected · idle';
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [

        // ── Hero status card ──────────────────────────────────────────────
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
                  // Animated-ish status dot
                  Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                      boxShadow: configured && _enabled
                          ? [BoxShadow(color: dotColor.withValues(alpha: 0.5), blurRadius: 6)]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: dotColor == Colors.white24
                            ? Colors.white38
                            : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Enable toggle right in the header
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _enabled ? 'ON' : 'OFF',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _enabled ? AppTheme.tealLight : Colors.white30,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Switch(
                        value: _enabled,
                        activeColor: AppTheme.teal,
                        onChanged: _saved ? _toggleEnabled : null,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Last sync / next sync row
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

        // ── Auto-sync toggle ──────────────────────────────────────────────
        if (_saved && _enabled) ...[
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              secondary: Icon(
                Icons.alarm,
                color: _autoSync ? AppTheme.amber : Colors.grey,
              ),
              title: const Text('Auto-sync every 3 minutes',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: Text(
                _autoSync
                    ? 'Pulls latest data from cloud every 3 min — all users stay in sync automatically.'
                    : 'Disabled — use Push below to sync manually.',
                style: const TextStyle(fontSize: 12),
              ),
              value: _autoSync,
              activeColor: AppTheme.amber,
              onChanged: _toggleAutoSync,
            ),
          ),
          const SizedBox(height: 12),

          // ── Push / Pull action row ──────────────────────────────────
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
          // Small info note
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
                    'Settings and imported CSV files are automatically saved to the cloud whenever you import or make changes. '
                    'On relaunch, the app restores everything — your settings AND your last imported files — automatically.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Divider(color: AppTheme.divider),
          const SizedBox(height: 8),
        ],

        // ── Status banner ─────────────────────────────────────────────────
        if (_statusMsg != null) ...[
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
                  _statusOk ? Icons.check_circle_outline : Icons.error_outline,
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
          const SizedBox(height: 12),
        ],

        // ── Advanced credentials panel (collapsed by default) ─────────────
        GestureDetector(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.navyMid,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.settings, size: 16, color: Colors.white38),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Connection Settings',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white54,
                    ),
                  ),
                ),
                Icon(
                  _showAdvanced
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 18,
                  color: Colors.white38,
                ),
              ],
            ),
          ),
        ),

        if (_showAdvanced) ...[
          const SizedBox(height: 10),
          _CredentialsPanel(
            dbUrlCtrl:  _dbUrlCtrl,
            apiKeyCtrl: _apiKeyCtrl,

            enabled:    _enabled,
            onEnabledChanged: (v) => setState(() => _enabled = v),
            loading:    _loading,
            onSave:     _saveAndConnect,
            saved:      _saved,
          ),
        ],

        const SizedBox(height: 32),
      ],
    );
  }
}

// ── Info pill ─────────────────────────────────────────────────────────────────

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

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

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final bool loading;
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
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color))
                : Icon(icon, color: color, size: 26),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
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

// ── Credentials panel (shown only when _showAdvanced == true) ─────────────────

class _CredentialsPanel extends StatelessWidget {
  final TextEditingController dbUrlCtrl;
  final TextEditingController apiKeyCtrl;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final bool loading;
  final VoidCallback onSave;
  final bool saved;

  const _CredentialsPanel({
    required this.dbUrlCtrl,
    required this.apiKeyCtrl,
    required this.enabled,
    required this.onEnabledChanged,
    required this.loading,
    required this.onSave,
    required this.saved,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Firebase Realtime Database',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          const Text(
            'Firebase Console → Build → Realtime Database → Data tab → copy the URL',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),

          // Enable toggle
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable Cloud Sync',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            value: enabled,
            activeColor: AppTheme.teal,
            onChanged: onEnabledChanged,
          ),
          const Divider(height: 16),

          TextField(
            controller: dbUrlCtrl,
            obscureText: true, // hide the URL visually
            decoration: const InputDecoration(
              labelText: 'Database URL *',
              hintText: 'https://my-app-default-rtdb.firebaseio.com',
              prefixIcon: Icon(Icons.link, size: 18),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: apiKeyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Web API Key (optional)',
              hintText: 'AIzaSy…',
              prefixIcon: Icon(Icons.vpn_key, size: 18),
            ),
          ),
          // No User ID field — all @bluearrowmail.com users share the same data path.
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: loading ? null : onSave,
              icon: loading
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 18),
              label: Text(loading ? 'Saving…' : 'Save & Connect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.navyAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Setup guide compact
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.navyMid.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Quick setup:',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary)),
                SizedBox(height: 6),
                _SetupStep('1', 'console.firebase.google.com → your project'),
                _SetupStep('2', 'Build → Realtime Database → Create database (test mode)'),
                _SetupStep('3', 'Data tab → copy the URL shown at the top'),
                _SetupStep('4', 'Paste URL above, set an Account ID, click Save'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  final String step;
  final String text;
  const _SetupStep(this.step, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 16, height: 16,
            margin: const EdgeInsets.only(right: 8, top: 1),
            decoration: BoxDecoration(
              color: AppTheme.navyAccent.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(step,
                  style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.navyAccent)),
            ),
          ),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ),
        ],
      ),
    );
  }
}
