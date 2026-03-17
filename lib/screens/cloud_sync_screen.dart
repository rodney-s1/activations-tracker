// Cloud Sync Settings Screen — with batch-sync status, auto-sync toggle,
// last-sync timestamp, and next-sync countdown.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../services/cloud_sync_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  final _dbUrlCtrl   = TextEditingController();  // Realtime Database URL
  final _apiKeyCtrl  = TextEditingController();  // Web API Key
  final _userIdCtrl  = TextEditingController();

  bool    _enabled    = false;
  bool    _autoSync   = true;   // hourly auto-push
  bool    _loading    = false;
  bool    _saved      = false;
  String? _statusMsg;
  bool    _statusOk   = true;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    // Start the 1-minute countdown ticker so "Next sync in…" updates.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppProvider>().startSyncCountdown();
    });
    // Listen to CloudSyncService status changes for immediate rebuilds.
    CloudSyncService.statusNotifier.addListener(_onSyncStatusChanged);
  }

  @override
  void dispose() {
    CloudSyncService.statusNotifier.removeListener(_onSyncStatusChanged);
    _dbUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _userIdCtrl.dispose();
    super.dispose();
  }

  void _onSyncStatusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSaved() async {
    final cfg = await CloudSyncService.readConfig();
    if (!mounted) return;
    setState(() {
      _dbUrlCtrl.text  = cfg['dbUrl']    ?? '';
      _apiKeyCtrl.text = cfg['apiKey']   ?? '';
      _userIdCtrl.text = cfg['userId']   ?? '';
      _enabled         = cfg['enabled'] == 'true';
      _autoSync        = cfg['autoSync'] != 'false';
      _saved           = _dbUrlCtrl.text.isNotEmpty;
    });
  }

  // ── Save & Connect ────────────────────────────────────────────────────────

  Future<void> _saveAndConnect() async {
    if (_dbUrlCtrl.text.trim().isEmpty) {
      setState(() {
        _statusMsg = 'Database URL is required (e.g. https://my-app-default-rtdb.firebaseio.com).';
        _statusOk  = false;
      });
      return;
    }

    setState(() { _loading = true; _statusMsg = null; });

    final err = await CloudSyncService.configure(
      dbUrl:    _dbUrlCtrl.text.trim(),
      apiKey:   _apiKeyCtrl.text.trim(),
      userId:   _userIdCtrl.text.trim(),
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
        _loading   = false;
        _saved     = true;
        _statusMsg = ok
            ? 'Connected to Realtime Database successfully!'
            : 'Saved, but could not reach the database. '
              'Check your Database URL and Rules.';
        _statusOk  = ok;
      });
    } else {
      setState(() {
        _loading   = false;
        _saved     = true;
        _statusMsg = 'Cloud sync disabled. Settings saved locally.';
        _statusOk  = true;
      });
    }
  }

  // ── Toggle auto-sync ──────────────────────────────────────────────────────

  Future<void> _toggleAutoSync(bool value) async {
    setState(() => _autoSync = value);
    await CloudSyncService.setAutoSync(value);
  }

  // ── Push ──────────────────────────────────────────────────────────────────

  Future<void> _push() async {
    setState(() { _loading = true; _statusMsg = null; });
    final err = await CloudSyncService.pushAll();
    if (!mounted) return;
    setState(() {
      _loading   = false;
      _statusMsg = err == null
          ? 'Settings pushed to cloud successfully! (3 writes)'
          : 'Push failed: $err';
      _statusOk  = err == null;
    });
  }

  // ── Pull ──────────────────────────────────────────────────────────────────

  Future<void> _pull() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pull from Cloud?'),
        content: const Text(
          'This will REPLACE your local settings with the cloud version:\n'
          '• Standard plan rates\n'
          '• Customer plan codes\n'
          '• Serial filter rules\n\n'
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

    context.read<AppProvider>().loadPricingData();

    if (result.containsKey('error')) {
      setState(() {
        _loading   = false;
        _statusMsg = 'Pull failed: ${result['error']}';
        _statusOk  = false;
      });
    } else {
      final counts = result['counts'] as Map<String, int>? ?? {};
      setState(() {
        _loading   = false;
        _statusMsg = 'Pulled: '
            '${counts['standardPlanRates'] ?? 0} plan rates, '
            '${counts['customerPlanCodes'] ?? 0} customer codes, '
            '${counts['serialFilterRules'] ?? 0} filter rules. (3 reads)';
        _statusOk  = true;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Subscribe to AppProvider so the countdown ticker causes rebuilds here.
    context.watch<AppProvider>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildHeaderCard(),
        const SizedBox(height: 16),
        _buildStatusBar(),
        const SizedBox(height: 16),
        _buildEnableToggle(),
        const SizedBox(height: 8),
        _buildAutoSyncToggle(),
        const SizedBox(height: 16),
        _buildCredentialsCard(),
        const SizedBox(height: 12),
        _buildUserIdCard(),
        const SizedBox(height: 16),
        _buildSaveButton(),
        if (_statusMsg != null) ...[
          const SizedBox(height: 10),
          _buildStatusBanner(),
        ],
        if (_saved && _enabled) ...[
          const SizedBox(height: 16),
          const Divider(color: AppTheme.divider),
          const SizedBox(height: 12),
          _buildSyncActionsSection(),
        ],
        const SizedBox(height: 16),
        _buildBatchInfoCard(),
        const SizedBox(height: 16),
        _SetupGuideCard(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Sub-widgets ───────────────────────────────────────────────────────────

  Widget _buildHeaderCard() {
    final status = CloudSyncService.status;
    final isOk   = status == SyncStatus.success || status == SyncStatus.idle;
    final dotColor = CloudSyncService.isConfigured
        ? (status == SyncStatus.syncing
            ? AppTheme.amber
            : isOk ? AppTheme.green : AppTheme.red)
        : Colors.white30;

    String statusLabel;
    switch (status) {
      case SyncStatus.notConfigured: statusLabel = 'Not configured'; break;
      case SyncStatus.idle:          statusLabel = 'Connected · Idle'; break;
      case SyncStatus.syncing:       statusLabel = 'Syncing…'; break;
      case SyncStatus.success:       statusLabel = 'Last sync succeeded'; break;
      case SyncStatus.error:         statusLabel = 'Sync error'; break;
    }

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.navyDark, AppTheme.navyMid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud_sync, color: AppTheme.tealLight, size: 28),
              SizedBox(width: 10),
              Text(
                'Firebase Cloud Sync',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Connect your Firebase Realtime Database to sync pricing '
            'rules and filter settings across all your computers. '
            'Uses plain JSON over HTTPS — no CORS issues, no SDK needed.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
              ),
              const SizedBox(width: 8),
              Text(
                statusLabel,
                style: TextStyle(
                  color: CloudSyncService.isConfigured
                      ? (isOk ? AppTheme.greenLight : AppTheme.amber)
                      : Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    final last  = CloudSyncService.lastSyncAt;
    final next  = CloudSyncService.nextSyncIn;
    final auto  = CloudSyncService.autoSync && CloudSyncService.isConfigured;
    final mins  = next.inMinutes;
    final nextLabel = auto
        ? (next == Duration.zero ? 'pending' : '$mins min')
        : 'disabled';

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.navyMid,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: _StatCell(
              label: 'Last Sync',
              value: last == null
                  ? 'Never'
                  : Formatters.dateTime(last),
              icon: Icons.history,
              iconColor: AppTheme.tealLight,
            ),
          ),
          Container(width: 1, height: 36, color: Colors.white12),
          Expanded(
            child: _StatCell(
              label: 'Next Auto-Sync',
              value: nextLabel,
              icon: Icons.schedule,
              iconColor: auto ? AppTheme.amber : Colors.white30,
            ),
          ),
          Container(width: 1, height: 36, color: Colors.white12),
          Expanded(
            child: _StatCell(
              label: 'Mode',
              value: CloudSyncService.isConfigured
                  ? (auto ? 'Auto (1 hr)' : 'Manual')
                  : 'Off',
              icon: Icons.sync,
              iconColor: CloudSyncService.isConfigured
                  ? AppTheme.green
                  : Colors.white30,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnableToggle() {
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        title: const Text('Enable Cloud Sync',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: const Text(
            'Sync settings to Firebase across devices',
            style: TextStyle(fontSize: 12)),
        value: _enabled,
        activeColor: AppTheme.teal,
        onChanged: (v) => setState(() => _enabled = v),
      ),
    );
  }

  Widget _buildAutoSyncToggle() {
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: Icon(
          Icons.alarm,
          color: _autoSync && _enabled ? AppTheme.amber : Colors.grey,
        ),
        title: const Text('Hourly Auto-Sync',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(
          _enabled
              ? (_autoSync
                  ? 'App will push settings to cloud every hour while open.'
                  : 'Disabled — use the Push button to sync manually.')
              : 'Enable Cloud Sync first.',
          style: const TextStyle(fontSize: 12),
        ),
        value: _autoSync && _enabled,
        activeColor: AppTheme.amber,
        onChanged: _enabled ? _toggleAutoSync : null,
      ),
    );
  }

  Widget _buildCredentialsCard() {
    return _FieldCard(
      title: 'Realtime Database Credentials',
      hint: 'Firebase Console → Build → Realtime Database',
      fields: [
        _FieldDef(
          controller: _dbUrlCtrl,
          label: 'Database URL *',
          hint: 'e.g. https://my-app-default-rtdb.firebaseio.com',
          helper: 'Firebase Console → Realtime Database → Data tab → copy the URL at the top',
        ),
        _FieldDef(
          controller: _apiKeyCtrl,
          label: 'Web API Key (optional)',
          hint: 'e.g. AIzaSy… — only needed if rules require auth',
          helper: 'Firebase Console → Project Settings → General → Web API Key',
        ),
      ],
    );
  }

  Widget _buildUserIdCard() {
    return _FieldCard(
      title: 'Sync Identity',
      hint: 'Used as the Firestore document path — same ID on all computers',
      fields: [
        _FieldDef(
          controller: _userIdCtrl,
          label: 'User / Account ID',
          hint: 'e.g. my_company or john_doe',
          helper: 'Any unique string. All computers with the same ID share data.',
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _loading ? null : _saveAndConnect,
        icon: _loading
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.link, size: 18),
        label: Text(_loading ? 'Connecting…' : 'Save & Connect'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.navyAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (_statusOk ? AppTheme.green : AppTheme.red).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (_statusOk ? AppTheme.green : AppTheme.red).withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _statusOk ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
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
    );
  }

  Widget _buildSyncActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Manual Sync Actions',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SyncActionButton(
                icon: Icons.upload_rounded,
                label: 'Push to Cloud',
                sublabel: '3 writes · Local → Firebase',
                color: AppTheme.teal,
                onTap: _loading ? null : _push,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SyncActionButton(
                icon: Icons.download_rounded,
                label: 'Pull from Cloud',
                sublabel: '3 reads · Firebase → Local',
                color: AppTheme.navyAccent,
                onTap: _loading ? null : _pull,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.amber.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.amber.withValues(alpha: 0.25)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tips_and_updates, size: 14, color: AppTheme.amber),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Hourly auto-sync pushes from this device automatically. '
                  'Pull on other computers to receive the latest settings. '
                  'Import history is NOT synced — only settings.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBatchInfoCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.batch_prediction, size: 20, color: AppTheme.teal),
              SizedBox(width: 8),
              Text(
                'Realtime Database — Usage & Limits',
                style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...[
            (
              Icons.upload,
              AppTheme.teal,
              'Push (3 writes per sync)',
              'Plan rates, customer codes, and filter rules are each written '
                  'as one JSON node via PUT. Each sync = exactly 3 writes.'
            ),
            (
              Icons.download,
              AppTheme.navyAccent,
              'Pull (3 reads per sync)',
              'All three nodes are fetched in parallel. '
                  'One pull = exactly 3 reads.'
            ),
            (
              Icons.alarm,
              AppTheme.amber,
              'Hourly auto-sync',
              'A timer fires every hour while the app is open and calls Push. '
                  'Free tier allows 100k writes/day — hourly sync uses only 72 writes/day.'
            ),
            (
              Icons.lock_open,
              AppTheme.green,
              'No CORS issues',
              'Realtime Database REST API uses plain HTTPS GET/PUT — '
                  'no preflight, no channel errors, works in every browser.'
            ),
          ].map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(item.$1, size: 18, color: item.$2),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.$3,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          Text(item.$4,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _StatCell({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
                fontSize: 9, color: Colors.white38, letterSpacing: 0.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _FieldDef {
  final TextEditingController controller;
  final String label;
  final String hint;
  final String helper;
  const _FieldDef({
    required this.controller,
    required this.label,
    required this.hint,
    required this.helper,
  });
}

class _FieldCard extends StatelessWidget {
  final String title;
  final String hint;
  final List<_FieldDef> fields;

  const _FieldCard({
    required this.title,
    required this.hint,
    required this.fields,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          Text(hint,
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          ...fields.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: f.controller,
                  decoration: InputDecoration(
                    labelText: f.label,
                    hintText: f.hint,
                    helperText: f.helper,
                    helperMaxLines: 2,
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

class _SyncActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final VoidCallback? onTap;

  const _SyncActionButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
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
            Icon(icon, color: color, size: 28),
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

class _SetupGuideCard extends StatelessWidget {
  const _SetupGuideCard();

  @override
  Widget build(BuildContext context) {
    final steps = [
      (
        'Firebase Console',
        'console.firebase.google.com → select your project',
        Icons.open_in_new
      ),
      (
        'Enable Realtime Database',
        'Build → Realtime Database → Create database → Start in test mode',
        Icons.storage
      ),
      (
        'Copy the Database URL',
        'Data tab → copy the URL shown at the top (e.g. https://my-app-default-rtdb.firebaseio.com)',
        Icons.link
      ),
      (
        'Paste URL into the field above',
        'The Web API Key is optional — leave blank if using open rules',
        Icons.edit
      ),
      (
        'Set a User / Account ID',
        'Any unique string. All computers with the same ID share data.',
        Icons.person
      ),
      (
        'Enable Hourly Auto-Sync',
        'Toggle ON so the app pushes settings every hour automatically.',
        Icons.alarm
      ),
      (
        'Pull on other computers',
        'Enter same DB URL + User ID → click Pull from Cloud',
        Icons.download_rounded
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: AppTheme.navyAccent),
              SizedBox(width: 8),
              Text('Setup Guide',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          ...steps.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22, height: 22,
                      margin: const EdgeInsets.only(top: 1, right: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.navyAccent.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${e.key + 1}',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.navyAccent),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.value.$1,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          Text(e.value.$2,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
