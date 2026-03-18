// Customer Pricing Screen
// Two tabs:
//   1. Standard Plan Rates — your Geotab costs per plan keyword
//   2. Customer Plan Codes — per-customer special rate codes & what you charge them

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../services/app_provider.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CustomerPricingScreen extends StatefulWidget {
  const CustomerPricingScreen({super.key});

  @override
  State<CustomerPricingScreen> createState() => _CustomerPricingScreenState();
}

class _CustomerPricingScreenState extends State<CustomerPricingScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
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
            Icon(Icons.price_change, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Pricing Settings'),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppTheme.tealLight,
          unselectedLabelColor: Colors.white60,
          indicatorColor: AppTheme.teal,
          tabs: const [
            Tab(icon: Icon(Icons.list_alt, size: 18), text: 'Standard Plans'),
            Tab(icon: Icon(Icons.manage_accounts, size: 18), text: 'Customer Codes'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _StandardPlanRatesTab(),
          _CustomerPlanCodesTab(),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 1 — Standard Plan Rates
// ════════════════════════════════════════════════════════════════════════════

class _StandardPlanRatesTab extends StatefulWidget {
  const _StandardPlanRatesTab();

  @override
  State<_StandardPlanRatesTab> createState() => _StandardPlanRatesTabState();
}

class _StandardPlanRatesTabState extends State<_StandardPlanRatesTab> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final rates = provider.standardRates;
        return Column(
          children: [
            // ── Info / action banner ───────────────────────────────
            Container(
              color: AppTheme.navyMid,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 15, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'These are what Geotab charges YOU. '
                      'Tap a row to edit. Swipe left or tap the trash icon to delete.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _confirmReset(context, provider),
                    child: const Text('Reset',
                        style: TextStyle(color: AppTheme.amber, fontSize: 12)),
                  ),
                ],
              ),
            ),
            // ── Count + Add button row ─────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  Text(
                    '${rates.length} plan${rates.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () => _addRate(context, provider),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Plan',
                        style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            // ── Rates list ─────────────────────────────────────────
            Expanded(
              child: rates.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.list_alt,
                              size: 48,
                              color: AppTheme.textSecondary
                                  .withValues(alpha: 0.4)),
                          const SizedBox(height: 16),
                          const Text('No plan rates yet.\nTap "Add Plan" to create one.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.textSecondary)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: rates.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final rate = rates[i];
                        return Dismissible(
                          key: ValueKey(rate.key),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            decoration: BoxDecoration(
                              color: AppTheme.red.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.delete_outline,
                                color: AppTheme.red),
                          ),
                          confirmDismiss: (_) =>
                              _confirmDelete(context, rate),
                          onDismissed: (_) =>
                              provider.deleteStandardRate(rate),
                          child: _StandardRateTile(
                            rate: rate,
                            onTap: () =>
                                _editRate(context, provider, rate),
                            onDelete: () async {
                              final ok =
                                  await _confirmDelete(context, rate);
                              if (ok == true && context.mounted) {
                                provider.deleteStandardRate(rate);
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _confirmDelete(
      BuildContext context, StandardPlanRate rate) async {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Plan Rate?'),
        content: Text(
            'Remove "${rate.planKey}" (keyword: "${rate.keyword}") from the pricing engine?\n\n'
            'This cannot be undone unless you tap Reset.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _addRate(BuildContext context, AppProvider provider) async {
    await _showRateDialog(context, provider, null);
  }

  Future<void> _editRate(
      BuildContext context, AppProvider provider, StandardPlanRate rate) async {
    await _showRateDialog(context, provider, rate);
  }

  Future<void> _showRateDialog(BuildContext context, AppProvider provider,
      StandardPlanRate? existing) async {
    final isNew = existing == null;
    final keyCtrl =
        TextEditingController(text: existing?.planKey ?? '');
    final kwCtrl =
        TextEditingController(text: existing?.keyword ?? '');
    final costCtrl = TextEditingController(
        text: existing != null
            ? existing.yourCost.toStringAsFixed(2)
            : '');

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isNew ? 'Add Plan Rate' : 'Edit "${existing?.planKey}"'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Plan Name *',
                  hintText: 'e.g. Ford OEM',
                  helperText: 'Short display name shown in the UI',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: kwCtrl,
                decoration: const InputDecoration(
                  labelText: 'Match Keyword *',
                  hintText: 'e.g. ford  or  geotab gm',
                  helperText:
                      'Case-insensitive substring matched against the Rate Plan column in your activation CSV',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: costCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,5}')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Your Cost (what Geotab charges you)',
                  prefixText: r'$ ',
                  hintText: '0.00',
                  helperText:
                      'Enter 0.00 if this is an add-on with no fixed Geotab cost',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final key  = keyCtrl.text.trim();
              final kw   = kwCtrl.text.trim().toLowerCase();
              final cost = double.tryParse(costCtrl.text.trim()) ?? 0.0;
              if (key.isEmpty || kw.isEmpty) return;

              if (isNew) {
                await provider.addStandardRate(StandardPlanRate(
                  planKey:  key,
                  keyword:  kw,
                  yourCost: cost,
                ));
              } else {
                final e = existing;
                if (e == null) return;
                e.planKey  = key;
                e.keyword  = kw;
                e.yourCost = cost;
                await provider.saveStandardRate(e);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(isNew ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  void _confirmReset(BuildContext context, AppProvider provider) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset to Defaults?'),
        content: const Text(
            'This will REPLACE all current plan rates with the built-in defaults '
            '(GO, ProPlus, Pro, Regulatory, Base, Suspend + OEM plans).\n\n'
            'Any custom plans you added will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await provider.resetStandardRates();
            },
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}

class _StandardRateTile extends StatelessWidget {
  final StandardPlanRate rate;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _StandardRateTile({
    required this.rate,
    required this.onTap,
    required this.onDelete,
  });

  static const _planIcons = {
    'go': Icons.gps_fixed,
    'proplus': Icons.star,
    'pro': Icons.star_half,
    'regulatory': Icons.policy,
    'base': Icons.radio_button_unchecked,
    'suspend': Icons.pause_circle_outline,
    'ford oem': Icons.directions_car,
    'gm oem': Icons.directions_car,
    'mack oem': Icons.local_shipping,
    'mercedes oem': Icons.directions_car,
    'navistar oem': Icons.local_shipping,
    'volvo oem': Icons.local_shipping,
    'freightliner oem': Icons.local_shipping,
    'stellantis oem': Icons.directions_car,
    'sw3': Icons.verified,
    'aemp': Icons.sensors,
    'cat aemp': Icons.construction,
    'jd aemp': Icons.agriculture,
    'komatsu aemp': Icons.construction,
  };

  @override
  Widget build(BuildContext context) {
    final iconKey = rate.planKey.toLowerCase();
    final icon = _planIcons[iconKey] ?? Icons.devices;
    final isOem = iconKey.contains('oem') ||
        iconKey.contains('aemp') ||
        iconKey == 'sw3';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: (isOem
                  ? AppTheme.amber
                  : AppTheme.navyAccent)
              .withValues(alpha: 0.12),
          child: Icon(icon,
              color: isOem ? AppTheme.amber : AppTheme.navyAccent,
              size: 20),
        ),
        title: Text(rate.planKey,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(
          'keyword: "${rate.keyword}"',
          style: const TextStyle(
              fontSize: 11, color: AppTheme.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rate.yourCost > 0) ...[
              Text(
                Formatters.currency(rate.yourCost),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.green),
              ),
              const SizedBox(width: 2),
              const Text('/mo',
                  style: TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary)),
            ] else
              const Text('— set cost',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.amber,
                      fontStyle: FontStyle.italic)),
            const SizedBox(width: 6),
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.edit_outlined,
                    size: 16, color: AppTheme.teal),
              ),
            ),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.delete_outline,
                    size: 16, color: AppTheme.red),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TAB 2 — Customer Plan Codes
// ════════════════════════════════════════════════════════════════════════════

class _CustomerPlanCodesTab extends StatefulWidget {
  const _CustomerPlanCodesTab();

  @override
  State<_CustomerPlanCodesTab> createState() => _CustomerPlanCodesTabState();
}

class _CustomerPlanCodesTabState extends State<_CustomerPlanCodesTab> {
  String _search = '';
  String? _expandedCustomer;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final codes = provider.customerPlanCodes;
        // Group by customer
        final customerMap = <String, List<CustomerPlanCode>>{};
        for (final c in codes) {
          customerMap.putIfAbsent(c.customerName, () => []).add(c);
        }
        final customerNames = customerMap.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

        final filtered = _search.isEmpty
            ? customerNames
            : customerNames
                .where((n) =>
                    n.toLowerCase().contains(_search.toLowerCase()) ||
                    (customerMap[n]?.any((c) =>
                            c.planCode
                                .toLowerCase()
                                .contains(_search.toLowerCase())) ??
                        false))
                .toList();

        return Column(
          children: [
            // ── Info banner ────────────────────────────────────────
            Container(
              color: AppTheme.navyMid,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 15, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Map special rate plan codes to the price YOU charge '
                      'each customer. If a customer has codes but a device '
                      'doesn\'t match, it will be flagged on import.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: AppTheme.tealLight, size: 22),
                    tooltip: 'Add customer code',
                    onPressed: () => _addCode(context, provider, null),
                  ),
                ],
              ),
            ),

            // ── Search ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search customer or plan code…',
                  prefixIcon: Icon(Icons.search, color: AppTheme.textSecondary),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),

            // ── Count row ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '${customerNames.length} customer${customerNames.length == 1 ? '' : 's'}'
                    ' · ${codes.length} rule${codes.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () => _importFromQbCsv(context, provider),
                    icon: const Icon(Icons.upload_file, size: 15,
                        color: AppTheme.navyAccent),
                    label: const Text('Import QB Pricing',
                        style: TextStyle(fontSize: 11, color: AppTheme.navyAccent)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.navyAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _addCode(context, provider, null),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Rule', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),

            // ── Customer list ──────────────────────────────────────
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.manage_accounts,
                              size: 48,
                              color: AppTheme.textSecondary
                                  .withValues(alpha: 0.4)),
                          const SizedBox(height: 16),
                          Text(
                            codes.isEmpty
                                ? 'No customer plan codes yet.\n'
                                    'Tap "Add Rule" to create one.'
                                : 'No results for "$_search"',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textSecondary),
                          ),
                          if (codes.isEmpty) ...[
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: () =>
                                  _addCode(context, provider, null),
                              icon: const Icon(Icons.add),
                              label: const Text('Add First Rule'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final name = filtered[i];
                        final custCodes = customerMap[name] ?? [];
                        final isExpanded = _expandedCustomer == name;
                        return _CustomerCodeGroup(
                          customerName: name,
                          codes: custCodes,
                          isExpanded: isExpanded,
                          onToggle: () => setState(() {
                            _expandedCustomer = isExpanded ? null : name;
                          }),
                          onAdd: () => _addCode(context, provider, name),
                          onEdit: (c) => _editCode(context, provider, c),
                          onDelete: (c) => provider.deleteCustomerPlanCode(c),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addCode(
      BuildContext context, AppProvider provider, String? prefilledCustomer) async {
    await _showCodeDialog(context, provider, null, prefilledCustomer);
  }

  Future<void> _editCode(
      BuildContext context, AppProvider provider, CustomerPlanCode existing) async {
    await _showCodeDialog(context, provider, existing, null);
  }

  // ── Import QB "Sales by Customer Detail" CSV ──────────────────────────────

  Future<void> _importFromQbCsv(
      BuildContext context, AppProvider provider) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        content = decodeBytesToString(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }

      if (!context.mounted) return;

      // Show progress
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Importing pricing…'),
            ],
          ),
        ),
      );

      final counts = await provider.importPricingFromQbSalesCsv(content);

      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss progress

      final imported  = counts['imported']  ?? 0;
      final updated   = counts['updated']   ?? 0;
      final conflicts = counts['conflicts'] ?? 0;
      final skipped   = counts['skipped']   ?? 0;

      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
              SizedBox(width: 8),
              Text('QB Pricing Import Complete'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ImportResultRow(
                icon: Icons.add_circle_outline,
                color: AppTheme.green,
                label: 'New customer codes added',
                value: '$imported',
              ),
              _ImportResultRow(
                icon: Icons.update,
                color: AppTheme.teal,
                label: 'Existing codes updated',
                value: '$updated',
              ),
              if (conflicts > 0)
                _ImportResultRow(
                  icon: Icons.warning_amber,
                  color: AppTheme.amber,
                  label: 'Price conflicts (higher price kept)',
                  value: '$conflicts',
                ),
              _ImportResultRow(
                icon: Icons.skip_next,
                color: AppTheme.textSecondary,
                label: 'Rows skipped (non-Geotab or blank)',
                value: '$skipped',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Customer codes were matched to QB customer names from '
                  'the "Sales by Customer Detail" report (03/01/2026 invoices). '
                  'Pricing Engine will apply these rates on your next CSV import.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import failed: $e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }

  Future<void> _showCodeDialog(BuildContext context, AppProvider provider,
      CustomerPlanCode? existing, String? prefilledCustomer) async {
    // Get QB customer names for autocomplete suggestions
    final qbNames = provider.qbCustomers.map((c) => c.name).toList();
    // Also gather names already in use for codes
    final codeCustomerNames = provider.customerPlanCodes
        .map((c) => c.customerName)
        .toSet()
        .toList()
      ..sort();
    final allSuggestions = {
      ...qbNames,
      ...codeCustomerNames,
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final nameCtrl = TextEditingController(
        text: existing?.customerName ?? prefilledCustomer ?? '');
    final codeCtrl = TextEditingController(text: existing?.planCode ?? '');
    final priceCtrl = TextEditingController(
        text: existing != null
            ? existing.customerPrice.toStringAsFixed(2)
            : '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');
    final rpcCtrl   = TextEditingController(text: existing?.requiredRpc ?? '');

    // Plan type suggestions for the code field
    final planCodeHints = [
      // Bracket codes
      '[0250]', '[1250]', '[1450]', '[1550]', '[2000]', '[2250]', '[2450]',
      // Named plan substrings
      'GO Bundle Plan', 'ProPlus Bundle', 'Pro Bundle',
      // Special rate codes
      'BUNDLE', 'OFFROAD', 'NEXTLINK', 'RS78-R1', 'BUNDLE-RS78-R1',
      // HOS
      'HOS',
    ];

    await showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing == null ? 'Add Customer Plan Code' : 'Edit Plan Code'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Customer name with autocomplete
                  Autocomplete<String>(
                    initialValue:
                        TextEditingValue(text: nameCtrl.text),
                    optionsBuilder: (v) {
                      if (v.text.isEmpty) return allSuggestions;
                      return allSuggestions.where((n) => n
                          .toLowerCase()
                          .contains(v.text.toLowerCase()));
                    },
                    onSelected: (s) => nameCtrl.text = s,
                    fieldViewBuilder: (ctx, ctrl, focusNode, onSubmit) {
                      // Keep nameCtrl in sync
                      ctrl.text = nameCtrl.text;
                      ctrl.addListener(() => nameCtrl.text = ctrl.text);
                      return TextField(
                        controller: ctrl,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          labelText: 'Customer Name *',
                          hintText: 'Must match CSV exactly',
                          helperText: 'Suggestions pulled from QB customer list',
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),

                  // Plan code
                  TextField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Plan Code / Substring *',
                      hintText: 'e.g. [1450] or "GO Bundle Plan [1450]"',
                      helperText:
                          'Any part of the Rate Plan column that identifies this plan',
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Hint chips
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: planCodeHints.map((h) => ActionChip(
                      label: Text(h,
                          style: const TextStyle(fontSize: 10)),
                      onPressed: () {
                        setS(() => codeCtrl.text = h);
                      },
                      backgroundColor:
                          AppTheme.navyAccent.withValues(alpha: 0.1),
                      side: BorderSide(
                          color: AppTheme.navyAccent.withValues(alpha: 0.3)),
                      labelStyle:
                          const TextStyle(color: AppTheme.navyAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 0),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )).toList(),
                  ),
                  const SizedBox(height: 12),

                  // Price
                  TextField(
                    controller: priceCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,5}')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Price You Charge Customer *',
                      prefixText: r'$ ',
                      hintText: 'e.g. 21.50',
                      helperText:
                          'Monthly rate billed to this customer for devices on this plan',
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Notes
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      hintText: 'e.g. Special contract, QB ref',
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Required RPC
                  TextField(
                    controller: rpcCtrl,
                    decoration: InputDecoration(
                      labelText: 'Required Rate Plan Code (optional)',
                      hintText: 'e.g. BUNDLE, RS78-R1, NEXTLINK',
                      helperText:
                          'MyAdmin RPC that must be present for the discount to apply. '
                          'If missing on a device, it will be flagged and billed at full price.',
                      helperMaxLines: 3,
                      prefixIcon: const Icon(Icons.qr_code, size: 16),
                      suffixIcon: rpcCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () => setS(() => rpcCtrl.clear()),
                            )
                          : null,
                    ),
                    onChanged: (_) => setS(() {}),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final code = codeCtrl.text.trim();
                final price = double.tryParse(priceCtrl.text.trim());
                if (name.isEmpty || code.isEmpty || price == null) return;

                final entry = CustomerPlanCode(
                  customerName: name,
                  planCode: code,
                  customerPrice: price,
                  notes: notesCtrl.text.trim(),
                  requiredRpc: rpcCtrl.text.trim(),
                );
                if (ctx.mounted) {
                  await provider.saveCustomerPlanCode(entry);
                  Navigator.pop(dialogCtx);
                  // Auto-expand to this customer
                  if (ctx.mounted) {
                    // trigger parent rebuild
                    (ctx as Element).markNeedsBuild();
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerCodeGroup extends StatelessWidget {
  final String customerName;
  final List<CustomerPlanCode> codes;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onAdd;
  final ValueChanged<CustomerPlanCode> onEdit;
  final ValueChanged<CustomerPlanCode> onDelete;

  const _CustomerCodeGroup({
    required this.customerName,
    required this.codes,
    required this.isExpanded,
    required this.onToggle,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Header row ─────────────────────────────────────────
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.navyAccent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customerName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        Text(
                          '${codes.length} plan code${codes.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        size: 20, color: AppTheme.teal),
                    tooltip: 'Add code for this customer',
                    onPressed: onAdd,
                  ),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: AppTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // ── Code rows (when expanded) ───────────────────────────
          if (isExpanded) ...[
            const Divider(height: 1, color: AppTheme.divider),
            ...codes.map((c) => _CodeRow(
                  code: c,
                  onEdit: () => onEdit(c),
                  onDelete: () => onDelete(c),
                )),
          ],
        ],
      ),
    );
  }
}

class _CodeRow extends StatelessWidget {
  final CustomerPlanCode code;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CodeRow({
    required this.code,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: AppTheme.teal, width: 3),
        ),
      ),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    code.planCode,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (code.requiredRpc.isNotEmpty) ...[ 
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.qr_code, size: 10,
                            color: AppTheme.tealLight),
                        const SizedBox(width: 3),
                        Text(
                          'RPC: ${code.requiredRpc}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.tealLight,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (code.notes.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      code.notes,
                      style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic),
                    ),
                  ],
                  if (code.lastUpdated != null)
                    Text(
                      'Updated ${Formatters.dateShort(code.lastUpdated)}',
                      style: const TextStyle(
                          fontSize: 9, color: AppTheme.textSecondary),
                    ),
                ],
              ),
            ),
            Text(
              Formatters.currency(code.customerPrice),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppTheme.green,
              ),
            ),
            const Text(
              '/mo',
              style: TextStyle(fontSize: 10, color: AppTheme.textSecondary),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.edit_outlined, size: 16, color: AppTheme.teal),
              ),
            ),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.delete_outline, size: 16, color: AppTheme.red),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helper widget for import result dialog ────────────────────────────────────

class _ImportResultRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _ImportResultRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
          ),
          Text(
            value,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: color),
          ),
        ],
      ),
    );
  }
}
