// Settings Screen — QB Customer List + Export/Import Settings

import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/qb_customer.dart';
import '../services/app_provider.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../services/settings_export_service.dart';
import '../utils/app_theme.dart';
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadPricingData();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.scaffoldBg,
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.settings, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Settings'),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppTheme.tealLight,
          unselectedLabelColor: Colors.white60,
          indicatorColor: AppTheme.teal,
          tabs: const [
            Tab(icon: Icon(Icons.business, size: 18), text: 'QB Customers'),
            Tab(icon: Icon(Icons.filter_list, size: 18), text: 'QB Filters'),
            Tab(icon: Icon(Icons.import_export, size: 18), text: 'Backup'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _QbCustomersTab(),
          _QbFiltersTab(),
          _BackupRestoreTab(),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 1 — QB Customers
// ════════════════════════════════════════════════════════════════════════════

class _QbCustomersTab extends StatefulWidget {
  const _QbCustomersTab();

  @override
  State<_QbCustomersTab> createState() => _QbCustomersTabState();
}

class _QbCustomersTabState extends State<_QbCustomersTab> {
  String _search = '';

  Future<void> _importQbCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      int count;

      if (file.bytes != null) {
        // Web: pass raw bytes directly — avoids String.fromCharCodes encoding corruption
        if (!mounted) return;
        count = await context.read<AppProvider>().importQbCustomersFromBytes(file.bytes!);
      } else if (file.path != null) {
        // Mobile/desktop: read file as string via path
        final content = await File(file.path!).readAsString();
        if (!mounted) return;
        count = await context.read<AppProvider>().importQbCustomers(content);
      } else {
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Imported $count active QB customer${count == 1 ? '' : 's'}.'),
            backgroundColor: count > 0 ? AppTheme.green : AppTheme.amber,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final all = provider.qbCustomers;
        final filtered = _search.isEmpty
            ? all
            : all
                .where((c) =>
                    c.name.toLowerCase().contains(_search.toLowerCase()) ||
                    c.email.toLowerCase().contains(_search.toLowerCase()))
                .toList();

        return Column(
          children: [
            // ── Info banner ─────────────────────────────────────────
            Container(
              color: AppTheme.navyMid,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 15, color: Colors.white54),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Import the QuickBooks Customer List CSV to enable '
                      'auto-complete when adding plan codes. '
                      'Tap the ⚡ Std/CUA button on each customer to mark them as '
                      '"Charged Upon Activation" — CUA customers are only billed for Active devices.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),

            // ── Action row ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _importQbCsv,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('Import QB CSV', style: TextStyle(fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.teal,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (all.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => _confirmClear(context, provider),
                      icon: const Icon(Icons.delete_sweep, size: 16, color: AppTheme.red),
                      label: const Text('Clear All',
                          style: TextStyle(fontSize: 12, color: AppTheme.red)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.red),
                      ),
                    ),
                ],
              ),
            ),

            // ── Search ──────────────────────────────────────────────
            if (all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search customers…',
                    prefixIcon: Icon(Icons.search, color: AppTheme.textSecondary),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),

            // ── Count ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Row(
                children: [
                  Text(
                    '${all.length} customer${all.length == 1 ? '' : 's'} stored',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  if (all.any((c) => c.isCua)) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.deepPurple.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        '${all.where((c) => c.isCua).length} CUA',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.deepPurple),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── List ────────────────────────────────────────────────
            Expanded(
              child: all.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.business,
                              size: 48,
                              color: AppTheme.textSecondary.withValues(alpha: 0.4)),
                          const SizedBox(height: 16),
                          const Text(
                            'No QB customers imported yet.\n'
                            'Import your QuickBooks Customer List CSV.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _importQbCsv,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('Import QB Customer List'),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, i) =>
                          _QbCustomerTile(customer: filtered[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  void _confirmClear(BuildContext context, AppProvider provider) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear QB Customers?'),
        content: const Text(
            'This removes all stored QB customers. '
            'Your pricing rules will not be affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await provider.clearQbCustomers();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}

class _QbCustomerTile extends StatefulWidget {
  final QbCustomer customer;
  const _QbCustomerTile({required this.customer});

  @override
  State<_QbCustomerTile> createState() => _QbCustomerTileState();
}

class _QbCustomerTileState extends State<_QbCustomerTile> {
  @override
  Widget build(BuildContext context) {
    final customer = widget.customer;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Avatar — purple if CUA, navy otherwise
            CircleAvatar(
              radius: 18,
              backgroundColor: customer.isCua
                  ? Colors.deepPurple.withValues(alpha: 0.18)
                  : AppTheme.navyAccent.withValues(alpha: 0.12),
              child: Text(
                customer.name.isNotEmpty ? customer.name[0].toUpperCase() : '?',
                style: TextStyle(
                    color: customer.isCua ? Colors.deepPurple : AppTheme.navyAccent,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(customer.name,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary)),
                      ),
                      if (customer.isCua)
                        Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.deepPurple.withValues(alpha: 0.35)),
                          ),
                          child: const Text('CUA',
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.deepPurple)),
                        ),
                    ],
                  ),
                  if (customer.email.isNotEmpty)
                    Text(customer.email,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                  if (customer.phone.isNotEmpty)
                    Text(customer.phone,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            if (customer.accountNo.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '#${customer.accountNo}',
                  style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.teal,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
            ],
            // CUA toggle button
            Tooltip(
              message: customer.isCua
                  ? 'CUA: billed for Active devices only.\nTap to set as Standard.'
                  : 'Standard: billed for Active + Suspended + Never Activated.\nTap to set as CUA.',
              child: GestureDetector(
                onTap: () async {
                  final box = QbCustomerService.box;
                  // Find box key for this customer object
                  int? boxKey;
                  for (int i = 0; i < box.length; i++) {
                    if (box.getAt(i) == customer) {
                      boxKey = i;
                      break;
                    }
                  }
                  if (boxKey != null) {
                    await QbCustomerService.toggleCua(boxKey);
                    if (mounted) setState(() {});
                    // Notify AppProvider so QB Verify re-reads the flag
                    if (mounted) {
                      context.read<AppProvider>().notifyQbCustomersChanged();
                    }
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: customer.isCua
                        ? Colors.deepPurple.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: customer.isCua
                          ? Colors.deepPurple.withValues(alpha: 0.5)
                          : AppTheme.textSecondary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt,
                          size: 13,
                          color: customer.isCua
                              ? Colors.deepPurple
                              : AppTheme.textSecondary),
                      const SizedBox(width: 3),
                      Text(
                        customer.isCua ? 'CUA' : 'Std',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: customer.isCua
                              ? Colors.deepPurple
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 2 — QB Import Filters
// ════════════════════════════════════════════════════════════════════════════

class _QbFiltersTab extends StatefulWidget {
  const _QbFiltersTab();

  @override
  State<_QbFiltersTab> createState() => _QbFiltersTabState();
}

class _QbFiltersTabState extends State<_QbFiltersTab> {
  final _ctrl = TextEditingController();
  List<dynamic> _keywords = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _keywords = QbIgnoreKeywordService.getAll();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    // Prevent duplicates
    if (_keywords.any((k) => k.keyword.toLowerCase() == kw.toLowerCase())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$kw" is already in the list.'),
            backgroundColor: AppTheme.amber,
          ),
        );
      }
      return;
    }
    await QbIgnoreKeywordService.add(kw);
    _ctrl.clear();
    _load();
    if (mounted) context.read<AppProvider>().refreshQbIgnoreKeywords();
  }

  Future<void> _delete(dynamic kw) async {
    await QbIgnoreKeywordService.delete(kw);
    _load();
    if (mounted) context.read<AppProvider>().refreshQbIgnoreKeywords();
  }

  Future<void> _resetDefaults() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset to Defaults?'),
        content: const Text(
          'This will remove all custom keywords and restore the '
          'original default list. Your changes cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await QbIgnoreKeywordService.resetToDefaults();
    _load();
    if (mounted) {
      context.read<AppProvider>().refreshQbIgnoreKeywords();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('QB import filters reset to defaults.'),
          backgroundColor: AppTheme.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Info banner ───────────────────────────────────────────────
        Container(
          color: AppTheme.navyMid,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: const Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: Colors.white54),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Lines in your QuickBooks "Sales by Customer Detail" report '
                  'whose Item/SKU column contains any of these keywords will be '
                  'skipped during import — they are not monthly service fees. '
                  'Also skips any line whose description contains "- New Activations".',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
            ],
          ),
        ),

        // ── Add keyword row ───────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'Add keyword (e.g. Rosco, Xtract)…',
                    prefixIcon: Icon(Icons.add_circle_outline, color: AppTheme.teal),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _add,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                child: const Text('Add'),
              ),
            ],
          ),
        ),

        // ── Count + Reset row ─────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Text(
                '${_keywords.length} keyword${_keywords.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _resetDefaults,
                icon: const Icon(Icons.restore, size: 15, color: AppTheme.amber),
                label: const Text('Reset to Defaults',
                    style: TextStyle(fontSize: 12, color: AppTheme.amber)),
              ),
            ],
          ),
        ),

        const Divider(height: 1, color: AppTheme.divider),

        // ── Keyword list ──────────────────────────────────────────────
        Expanded(
          child: _keywords.isEmpty
              ? const Center(
                  child: Text(
                    'No keywords. Add keywords above to start filtering.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _keywords.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final kw = _keywords[i];
                    return Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.block,
                              size: 16,
                              color: AppTheme.red.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    kw.keyword,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  if (kw.isDefault)
                                    const Text(
                                      'Default keyword',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.textSecondary),
                                    ),
                                ],
                              ),
                            ),
                            // Delete button
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: AppTheme.red.withValues(alpha: 0.7),
                              ),
                              onPressed: () => _showDeleteConfirm(kw),
                              tooltip: 'Remove keyword',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showDeleteConfirm(dynamic kw) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Keyword?'),
        content: Text(
          'Remove "${kw.keyword}" from the ignore list?\n'
          'QB lines containing this keyword will no longer be skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _delete(kw);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 3 — Backup / Restore
// ════════════════════════════════════════════════════════════════════════════

class _BackupRestoreTab extends StatelessWidget {
  const _BackupRestoreTab();

  Future<void> _exportSettings(BuildContext context) async {
    try {
      final json = SettingsExportService.exportAll();
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Settings JSON copied to clipboard!\n'
              'Paste into a text file and save as activation_tracker_settings.json',
            ),
            backgroundColor: AppTheme.green,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: AppTheme.red),
        );
      }
    }
  }

  Future<void> _importSettings(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        try {
          content = utf8.decode(file.bytes!, allowMalformed: false);
        } catch (_) {
          content = latin1.decode(file.bytes!);
        }
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }
      if (content.isEmpty) return;

      jsonDecode(content); // validate JSON early

      if (!context.mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Restore Settings?'),
          content: const Text(
              'This will REPLACE all current settings:\n'
              '• Standard plan rates\n'
              '• Customer plan codes\n'
              '• Customer rate overrides\n'
              '• Serial filter rules\n\n'
              'This cannot be undone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
              child: const Text('Restore'),
            ),
          ],
        ),
      );

      if (confirm != true || !context.mounted) return;

      final counts = await SettingsExportService.importAll(content);
      if (!context.mounted) return;
      context.read<AppProvider>().loadPricingData();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored: '
            '${counts['standardPlanRates'] ?? 0} plan rates, '
            '${counts['customerPlanCodes'] ?? 0} customer codes, '
            '${counts['customerRates'] ?? 0} rate overrides, '
            '${counts['serialFilterRules'] ?? 0} filter rules.',
          ),
          backgroundColor: AppTheme.green,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), backgroundColor: AppTheme.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          icon: Icons.upload,
          iconColor: AppTheme.teal,
          title: 'Export Settings',
          subtitle:
              'Copy all pricing rules, customer codes, plan rates, and filter settings '
              'to clipboard as JSON. Paste into a .json file to transfer to another computer.',
          actionLabel: 'Export to Clipboard',
          actionColor: AppTheme.teal,
          onAction: () => _exportSettings(context),
          tips: const [
            'Copy → paste into Notepad/TextEdit → save as .json',
            'Store in Google Drive / OneDrive for easy access',
            'Use "Restore Settings" on another computer to apply',
          ],
        ),
        const SizedBox(height: 16),
        _SectionCard(
          icon: Icons.download,
          iconColor: AppTheme.navyAccent,
          title: 'Restore Settings',
          subtitle:
              'Load a previously exported .json settings file to restore all pricing '
              'and filter rules. This REPLACES current settings.',
          actionLabel: 'Import Settings File',
          actionColor: AppTheme.navyAccent,
          onAction: () => _importSettings(context),
          tips: const [
            'Accepts .json or .txt files',
            'All current settings will be overwritten',
            'QB Customer list is NOT included in settings backup',
          ],
        ),
        const SizedBox(height: 16),
        _BackupContentsCard(),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.navyDark,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(16),
          child: const Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bolt, size: 20, color: AppTheme.tealLight),
                  SizedBox(width: 8),
                  Text('Activation Tracker',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              SizedBox(height: 6),
              Text('v1.0 · Geotab Reseller Billing Tool',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackupContentsCard extends StatelessWidget {
  const _BackupContentsCard();

  @override
  Widget build(BuildContext context) {
    const items = [
      ('Standard Plan Rates',
          'GO, ProPlus, Pro, Regulatory, Base, Suspend — your Geotab costs',
          AppTheme.green),
      ('Customer Plan Codes',
          'Special rate codes + prices per customer', AppTheme.teal),
      ('Customer Rate Overrides',
          'Legacy per-customer monthly rate overrides', AppTheme.navyAccent),
      ('Serial Filter Rules',
          'Custom prefix exclusions (EVD always excluded)', AppTheme.amber),
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
              Icon(Icons.inventory_2_outlined, size: 20, color: AppTheme.navyAccent),
              SizedBox(width: 8),
              Text("What's Included in the Backup",
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 4, right: 8),
                      decoration: BoxDecoration(
                          color: item.$3, shape: BoxShape.circle),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.$1,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          Text(item.$2,
                              style: const TextStyle(
                                  fontSize: 11, color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
          const Divider(height: 16, color: AppTheme.divider),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: AppTheme.textSecondary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'QB Customer list and import history are NOT included — '
                  're-import them on the new computer.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String actionLabel;
  final Color actionColor;
  final VoidCallback onAction;
  final List<String> tips;

  const _SectionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.actionColor,
    required this.onAction,
    required this.tips,
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: iconColor.withValues(alpha: 0.12),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onAction,
                icon: Icon(icon, size: 18),
                label: Text(actionLabel),
                style: ElevatedButton.styleFrom(
                  backgroundColor: actionColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (tips.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...tips.map((t) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.tips_and_updates,
                            size: 12, color: AppTheme.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(t,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary)),
                        ),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
