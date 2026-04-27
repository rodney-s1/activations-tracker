// Settings Screen — QB Customer List + Export/Import Settings

import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/qb_customer.dart';
import '../models/qb_ignore_keyword.dart';
import '../models/plan_mapping.dart';
import '../services/app_provider.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../services/plan_mapping_service.dart';
import '../services/settings_export_service.dart';
import '../services/surfsight_direct_service.dart';
import '../utils/app_theme.dart';
import 'surfsight_direct_screen.dart';

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
    _tabs = TabController(length: 5, vsync: this);
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
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(icon: Icon(Icons.business, size: 18), text: 'QB Customers'),
            Tab(icon: Icon(Icons.filter_list, size: 18), text: 'QB Filters'),
            Tab(icon: Icon(Icons.map, size: 18), text: 'Plan Mapping'),
            Tab(icon: Icon(Icons.import_export, size: 18), text: 'Backup'),
            Tab(icon: Icon(Icons.store, size: 18), text: 'Vendor Data'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          const _QbCustomersTab(),
          const _QbFiltersTab(),
          const _PlanMappingTab(),
          const _BackupRestoreTab(),
          _VendorDataTab(),
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
                      'The CUA flag is auto-set from Column AK (Job Type) when you import a '
                      'QB Customer List CSV — "Charge Upon Activation" = CUA (Active devices only), '
                      'all others = Standard (Active + Suspended + Never Activated). '
                      'Use the ⚡ button to manually override any customer\'s billing type.',
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
                  if (customer.jobType.isNotEmpty)
                    Text(
                      customer.jobType,
                      style: TextStyle(
                        fontSize: 10,
                        color: customer.isCua
                            ? Colors.deepPurple.withValues(alpha: 0.8)
                            : AppTheme.textSecondary.withValues(alpha: 0.7),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  // Parent account badge
                  if (customer.parentAccountName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          Icon(Icons.account_tree_outlined,
                              size: 11,
                              color: AppTheme.navyAccent.withValues(alpha: 0.7)),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              'Bills under: ${customer.parentAccountName}',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppTheme.navyAccent.withValues(alpha: 0.85),
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
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
                      // ignore: use_build_context_synchronously
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
            // Parent account assignment button
            const SizedBox(width: 4),
            Tooltip(
              message: customer.parentAccountName.isEmpty
                  ? 'Assign parent account\n(child devices roll up to parent in QB Verify)'
                  : 'Parent: ${customer.parentAccountName}\nTap to change or remove',
              child: GestureDetector(
                onTap: () => _showParentDialog(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: customer.parentAccountName.isNotEmpty
                        ? AppTheme.navyAccent.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: customer.parentAccountName.isNotEmpty
                          ? AppTheme.navyAccent.withValues(alpha: 0.45)
                          : AppTheme.textSecondary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Icon(
                    customer.parentAccountName.isNotEmpty
                        ? Icons.account_tree
                        : Icons.account_tree_outlined,
                    size: 14,
                    color: customer.parentAccountName.isNotEmpty
                        ? AppTheme.navyAccent
                        : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dialog to assign or clear the parent account.
  Future<void> _showParentDialog(BuildContext context) async {
    final customer = widget.customer;
    final allCustomers = QbCustomerService.getAll()
        .where((c) => c.name != customer.name) // exclude self
        .map((c) => c.name)
        .toList();

    final searchCtrl = TextEditingController();
    String? selected = customer.parentAccountName.isEmpty
        ? null
        : customer.parentAccountName;
    List<String> filtered = List.from(allCustomers);

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.account_tree_outlined,
                  size: 16, color: AppTheme.navyAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Parent Account for ${customer.name}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 320,
            height: 360,
            child: Column(
              children: [
                Text(
                  'Devices under this account will be counted '
                  'under the parent\'s QB Verify row. '
                  'This account will be hidden from the verify list.',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Search customers…',
                    prefixIcon: Icon(Icons.search, size: 16),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                  onChanged: (v) => setS(() {
                    final q = v.trim().toLowerCase();
                    filtered = allCustomers
                        .where((n) => n.toLowerCase().contains(q))
                        .toList();
                  }),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('No customers found',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary)))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final name = filtered[i];
                            final isSelected = name == selected;
                            return InkWell(
                              onTap: () => setS(() => selected = name),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                margin: const EdgeInsets.only(bottom: 2),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppTheme.navyAccent
                                          .withValues(alpha: 0.1)
                                      : null,
                                  borderRadius: BorderRadius.circular(6),
                                  border: isSelected
                                      ? Border.all(
                                          color: AppTheme.navyAccent
                                              .withValues(alpha: 0.4))
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isSelected
                                              ? FontWeight.w700
                                              : FontWeight.normal,
                                          color: isSelected
                                              ? AppTheme.navyAccent
                                              : AppTheme.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      const Icon(Icons.check_circle,
                                          size: 14,
                                          color: AppTheme.navyAccent),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            if (customer.parentAccountName.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  final provider = context.read<AppProvider>();
                  await QbCustomerService.clearParent(customer.name);
                  if (mounted) setState(() {});
                  provider.notifyQbCustomersChanged();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.link_off, size: 14),
                label: const Text('Remove Parent'),
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.red),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selected == null
                  ? null
                  : () async {
                      final provider = context.read<AppProvider>();
                      await QbCustomerService.setParent(
                          customer.name, selected!);
                      if (mounted) setState(() {});
                      provider.notifyQbCustomersChanged();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.navyAccent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    searchCtrl.dispose();
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
  // ignore: unused_field
  String _pendingKeyword = ''; // mirrors _ctrl text — survives focus-loss on web
  List<QbIgnoreKeyword> _keywords = [];

  // ── New-Activations ignore text config ───────────────────────────────────
  bool _editingIgnoreText = false;
  late TextEditingController _ignoreTextCtrl;
  String _ignoreText = QbIgnoreKeywordService.newActivationsIgnoreText;

  @override
  void initState() {
    super.initState();
    _ignoreTextCtrl = TextEditingController(text: _ignoreText);
    // Use async load so Hive box is re-opened if it was closed (web edge case).
    _loadAsync();
  }

  void _load() {
    setState(() {
      _keywords = QbIgnoreKeywordService.getAll();
      _ignoreText = QbIgnoreKeywordService.newActivationsIgnoreText;
    });
  }

  Future<void> _loadAsync() async {
    // Ensure box is open (handles web reopen edge case) then reload.
    await QbIgnoreKeywordService.ensureOpen();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _ignoreTextCtrl.dispose();
    super.dispose();
  }

  // ── Ignore text save/reset ────────────────────────────────────────────────

  Future<void> _saveIgnoreText() async {
    final text = _ignoreTextCtrl.text.trim();
    await QbIgnoreKeywordService.setNewActivationsIgnoreText(text);
    setState(() {
      _ignoreText = text;
      _editingIgnoreText = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text.isEmpty
              ? 'Memo ignore text cleared — no lines will be skipped by memo.'
              : 'Memo ignore text updated to "$text".'),
          backgroundColor: AppTheme.green,
        ),
      );
    }
  }

  Future<void> _resetIgnoreText() async {
    await QbIgnoreKeywordService.resetNewActivationsIgnoreText();
    _ignoreTextCtrl.text = QbIgnoreKeywordService.defaultNewActivationsText;
    setState(() {
      _ignoreText = QbIgnoreKeywordService.defaultNewActivationsText;
      _editingIgnoreText = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Memo ignore text reset to default.'),
          backgroundColor: AppTheme.green,
        ),
      );
    }
  }

  Future<void> _add() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;

    // Guard: 'Rosco' must never be a filter keyword — Rosco QB lines must
    // flow through the parser to populate qbRoscoBilled for PDF reconciliation.
    if (kw.toLowerCase() == 'rosco') {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: AppTheme.amber),
                SizedBox(width: 8),
                Text('Cannot Filter Rosco'),
              ],
            ),
            content: const Text(
              '"Rosco" cannot be added as a filter keyword.\n\n'
              'Rosco QB lines (Service Fee Rosco, Wifi Service Fee, etc.) '
              'must be imported so they can be counted and reconciled '
              'against the Rosco PDF invoice.\n\n'
              'Filtering them out would silently break Rosco billing reconciliation.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
      }
      return;
    }

    try {
      final live = await QbIgnoreKeywordService.getAllAsync();
      if (live.any((k) => k.keyword.toLowerCase() == kw.toLowerCase())) {
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
      _pendingKeyword = '';
      _load();
      if (mounted) {
        context.read<AppProvider>().refreshQbIgnoreKeywords();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$kw" added to ignore list.'),
            backgroundColor: AppTheme.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[QB Filters] _add error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add keyword: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  Future<void> _delete(QbIgnoreKeyword kw) async {
    try {
      await QbIgnoreKeywordService.delete(kw);
      _load();
      if (mounted) context.read<AppProvider>().refreshQbIgnoreKeywords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove keyword: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
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
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 15, color: Colors.white54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Lines in your QuickBooks "Sales by Customer Detail" report '
                  'whose Item/SKU column contains any of these keywords will be '
                  'skipped during import — they are not monthly service fees. '
                  'Also skips any line whose memo/description contains the '
                  '"Memo Ignore Text" configured below.',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
            ],
          ),
        ),

        // ── Memo Ignore Text config panel ─────────────────────────────
        Container(
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          decoration: BoxDecoration(
            color: AppTheme.navyMid,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        size: 14, color: AppTheme.tealLight),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Memo Ignore Text (Column L)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (!_editingIgnoreText) ...[
                      TextButton(
                        onPressed: () {
                          _ignoreTextCtrl.text = _ignoreText;
                          setState(() => _editingIgnoreText = true);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.tealLight,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Edit', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: _resetIgnoreText,
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.amber,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Reset', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
              // Value row / edit row
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: _editingIgnoreText
                    ? Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _ignoreTextCtrl,
                              autofocus: true,
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textPrimary),
                              decoration: InputDecoration(
                                hintText: 'e.g. - New Activations',
                                helperText:
                                    'Leave empty to disable this filter.',
                                helperStyle: const TextStyle(
                                    fontSize: 10, color: AppTheme.textSecondary),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                isDense: true,
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6)),
                              ),
                              onSubmitted: (_) => _saveIgnoreText(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _saveIgnoreText,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.teal,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Save',
                                style: TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            onPressed: () =>
                                setState(() => _editingIgnoreText = false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.textSecondary,
                              side: const BorderSide(color: AppTheme.divider),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Cancel',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          const Icon(Icons.block, size: 13, color: AppTheme.amber),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _ignoreText.isEmpty
                                  ? '(disabled — no lines skipped by memo)'
                                  : '"$_ignoreText"',
                              style: TextStyle(
                                fontSize: 12,
                                color: _ignoreText.isEmpty
                                    ? AppTheme.textSecondary
                                    : AppTheme.textPrimary,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                          if (_ignoreText != QbIgnoreKeywordService.defaultNewActivationsText)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppTheme.amber.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: AppTheme.amber.withValues(alpha: 0.4)),
                              ),
                              child: const Text('custom',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.amber)),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

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
                    hintText: 'Add keyword (e.g. Xtract, TopFly)…',
                    prefixIcon: Icon(Icons.add_circle_outline, color: AppTheme.teal),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (v) => _pendingKeyword = v,
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

  void _showDeleteConfirm(QbIgnoreKeyword kw) {
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
// TAB 3 — Plan Mapping
// ════════════════════════════════════════════════════════════════════════════

class _PlanMappingTab extends StatefulWidget {
  const _PlanMappingTab();
  @override
  State<_PlanMappingTab> createState() => _PlanMappingTabState();
}

class _PlanMappingTabState extends State<_PlanMappingTab> {
  List<PlanMapping> _mappings = [];
  final _myAdminCtrl = TextEditingController();
  final _qbCtrl      = TextEditingController();
  PlanMapping? _editing; // non-null when editing an existing row inline

  @override
  void initState() {
    super.initState();
    _loadAsync();
  }

  @override
  void dispose() {
    _myAdminCtrl.dispose();
    _qbCtrl.dispose();
    super.dispose();
  }

  void _load() => setState(() => _mappings = PlanMappingService.getAll());

  Future<void> _loadAsync() async {
    await PlanMappingService.ensureOpen();
    _load();
  }

  Future<void> _add() async {
    final ma = _myAdminCtrl.text.trim();
    final qb = _qbCtrl.text.trim();
    if (ma.isEmpty || qb.isEmpty) return;
    await PlanMappingService.add(ma, qb);
    _myAdminCtrl.clear();
    _qbCtrl.clear();
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Mapping "$ma → $qb" added.'),
            backgroundColor: AppTheme.green,
            duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<void> _saveEdit(PlanMapping m) async {
    final ma = _myAdminCtrl.text.trim();
    final qb = _qbCtrl.text.trim();
    if (ma.isEmpty || qb.isEmpty) return;
    await PlanMappingService.update(m, ma, qb);
    setState(() => _editing = null);
    _myAdminCtrl.clear();
    _qbCtrl.clear();
    _load();
  }

  Future<void> _delete(PlanMapping m) async {
    await PlanMappingService.delete(m);
    if (_editing == m) {
      setState(() => _editing = null);
      _myAdminCtrl.clear();
      _qbCtrl.clear();
    }
    _load();
  }

  Future<void> _resetDefaults() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset to Defaults?'),
        content: const Text(
            'This will remove all custom mappings and restore the built-in defaults.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirm != true) return;
    await PlanMappingService.resetToDefaults();
    setState(() => _editing = null);
    _myAdminCtrl.clear();
    _qbCtrl.clear();
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Plan mappings reset to defaults.'),
            backgroundColor: AppTheme.green),
      );
    }
  }

  void _startEdit(PlanMapping m) {
    setState(() => _editing = m);
    _myAdminCtrl.text = m.myAdminPlan;
    _qbCtrl.text      = m.qbLabel;
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _myAdminCtrl.clear();
    _qbCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = _editing != null;
    return Column(
      children: [
        // ── Info banner ─────────────────────────────────────────────────
        Container(
          width: double.infinity,
          color: AppTheme.navyDark,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Text(
            'Map MyAdmin billing plan names to QB SKU labels. '
            'The audit uses these mappings to show a plan breakdown on each '
            'customer card (e.g. "GO 28 · ProPlus 6"). '
            'Matching is case-insensitive substring — the first matching rule wins.',
            style: TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ),

        // ── Add / Edit form ─────────────────────────────────────────────
        Container(
          color: AppTheme.navyMid,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEditing ? 'Edit Mapping' : 'Add Mapping',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.tealLight),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _myAdminCtrl,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'MyAdmin plan substring…',
                        hintStyle: const TextStyle(
                            fontSize: 11, color: Colors.white38),
                        filled: true,
                        fillColor: AppTheme.navyDark,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none),
                        suffixIcon: _myAdminCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear,
                                    size: 14, color: Colors.white38),
                                onPressed: () => setState(
                                    () => _myAdminCtrl.clear()))
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => isEditing ? _saveEdit(_editing!) : _add(),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward,
                        size: 16, color: AppTheme.tealLight),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _qbCtrl,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'QB label (e.g. GO, ProPlus)…',
                        hintStyle: const TextStyle(
                            fontSize: 11, color: Colors.white38),
                        filled: true,
                        fillColor: AppTheme.navyDark,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none),
                        suffixIcon: _qbCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear,
                                    size: 14, color: Colors.white38),
                                onPressed: () =>
                                    setState(() => _qbCtrl.clear()))
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => isEditing ? _saveEdit(_editing!) : _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isEditing) ...[
                    IconButton(
                      icon: const Icon(Icons.check_circle,
                          color: AppTheme.green, size: 22),
                      tooltip: 'Save',
                      onPressed: () => _saveEdit(_editing!),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel,
                          color: Colors.white38, size: 22),
                      tooltip: 'Cancel',
                      onPressed: _cancelEdit,
                    ),
                  ] else
                    IconButton(
                      icon: const Icon(Icons.add_circle,
                          color: AppTheme.teal, size: 22),
                      tooltip: 'Add',
                      onPressed: _add,
                    ),
                ],
              ),
            ],
          ),
        ),

        // ── Table header ────────────────────────────────────────────────
        Container(
          color: AppTheme.navyDark,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: const [
              Expanded(
                  flex: 5,
                  child: Text('MyAdmin Billing Plan (substring)',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white54,
                          letterSpacing: 0.5))),
              Expanded(
                  flex: 3,
                  child: Text('QB Label',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white54,
                          letterSpacing: 0.5))),
              SizedBox(width: 80),
            ],
          ),
        ),

        // ── Mapping list ────────────────────────────────────────────────
        Expanded(
          child: _mappings.isEmpty
              ? const Center(
                  child: Text('No mappings yet.',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: _mappings.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: AppTheme.divider),
                  itemBuilder: (ctx, i) {
                    final m = _mappings[i];
                    final isEditingThis = _editing == m;
                    return Container(
                      color: isEditingThis
                          ? AppTheme.teal.withValues(alpha: 0.06)
                          : null,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: Row(
                              children: [
                                if (m.isDefault)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Tooltip(
                                      message: 'Built-in default',
                                      child: Icon(Icons.lock_outline,
                                          size: 11,
                                          color: Colors.white.withValues(alpha: 0.25)),
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    m.myAdminPlan,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isEditingThis
                                            ? AppTheme.tealLight
                                            : AppTheme.textPrimary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.teal.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color:
                                        AppTheme.teal.withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                m.qbLabel,
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.tealLight),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 80,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit_outlined,
                                      size: 16,
                                      color: isEditingThis
                                          ? AppTheme.teal
                                          : Colors.white38),
                                  tooltip: 'Edit',
                                  onPressed: isEditingThis
                                      ? _cancelEdit
                                      : () => _startEdit(m),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 16, color: Colors.white38),
                                  tooltip: 'Delete',
                                  onPressed: () => _delete(m),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),

        // ── Footer: reset button ────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            color: AppTheme.navyDark,
            border: Border(top: BorderSide(color: AppTheme.divider)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_mappings.length} mapping${_mappings.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white54)),
              TextButton.icon(
                onPressed: _resetDefaults,
                icon: const Icon(Icons.restore, size: 14),
                label: const Text('Reset to Defaults',
                    style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.amber,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 4 — Backup / Restore
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

// ════════════════════════════════════════════════════════════════════════════
// TAB 5 — Vendor Data
// ════════════════════════════════════════════════════════════════════════════

class _VendorDataTab extends StatelessWidget {
  _VendorDataTab();

  final SurfsightDirectService _surfsightService = SurfsightDirectService();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Section header
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Vendor Data Sources',
            style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700),
          ),
        ),
        const Text(
          'Manage data imported from external vendor portals. These records '
          'supplement the MyAdmin device list during the QB audit so cameras '
          'billed outside of MyAdmin are properly accounted for.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 20),

        // ── Surfsight Direct tile ──────────────────────────────────────────
        _VendorTile(
          icon: Icons.videocam,
          title: 'Surfsight Direct',
          subtitle: 'Cameras billed in QB under "Surfsight Service : SS Service Fee" '
              'that do not appear in MyAdmin.',
          onTap: () async {
            await _surfsightService.load();
            if (!context.mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SurfsightDirectScreen(
                    service: _surfsightService),
              ),
            );
          },
        ),

        // ── Placeholder for future vendors ────────────────────────────────
        const SizedBox(height: 12),
        Opacity(
          opacity: 0.35,
          child: _VendorTile(
            icon: Icons.add_circle_outline,
            title: 'More Vendors Coming Soon',
            subtitle: 'Additional vendor data sources (e.g. Lytx, Netradyne, '
                'Motive) will appear here.',
            onTap: null,
          ),
        ),
      ],
    );
  }
}

// ── Vendor tile card ──────────────────────────────────────────────────────────

class _VendorTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _VendorTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppTheme.navyDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: AppTheme.teal.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: AppTheme.tealLight, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11)),
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right,
                    color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
