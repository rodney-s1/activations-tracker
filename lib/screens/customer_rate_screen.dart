// Customer Rate Book Screen
// Manual price overrides per customer + CSV bulk import

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/customer_rate.dart';
import '../services/app_provider.dart';
import '../services/customer_rate_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CustomerRateScreen extends StatefulWidget {
  const CustomerRateScreen({super.key});

  @override
  State<CustomerRateScreen> createState() => _CustomerRateScreenState();
}

class _CustomerRateScreenState extends State<CustomerRateScreen> {
  String _search = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadCustomerRates();
    });
  }

  Future<void> _importCsv() async {
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

      if (!mounted) return;
      final count =
          await context.read<AppProvider>().importCustomerRatesFromCsv(content);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported $count customer rate(s) successfully.'),
            backgroundColor: AppTheme.green,
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

  Future<void> _editRate(CustomerRate? existing, {String? prefilledName}) async {
    final nameCtrl =
        TextEditingController(text: existing?.customerName ?? prefilledName ?? '');
    final rateCtrl = TextEditingController(
        text: existing?.overrideMonthlyRate != null
            ? existing!.overrideMonthlyRate!.toStringAsFixed(2)
            : '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');
    final planCtrl =
        TextEditingController(text: existing?.ratePlanLabel ?? '');

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existing == null ? 'Add Customer Rate' : 'Edit Rate'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Customer Name *',
                  hintText: 'Must match name in CSV exactly',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: rateCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,5}')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Monthly Rate Override (\$)',
                  hintText: 'Leave blank to use CSV value',
                  prefixText: '\$ ',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: planCtrl,
                decoration: const InputDecoration(
                  labelText: 'Rate Plan Label (optional)',
                  hintText: 'e.g. GO Bundle, ProPlus',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'QB invoice ref, PO number, etc.',
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
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final rateStr = rateCtrl.text.trim();
              final rate = rateStr.isNotEmpty ? double.tryParse(rateStr) : null;
              final cr = CustomerRate(
                customerName: name,
                overrideMonthlyRate: rate,
                notes: notesCtrl.text.trim(),
                ratePlanLabel: planCtrl.text.trim(),
              );
              if (context.mounted) {
                await context.read<AppProvider>().saveCustomerRate(cr);
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.price_change, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Customer Rate Book'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import CSV',
            onPressed: _importCsv,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Customer Rate',
            onPressed: () => _editRate(null),
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final allRates = provider.customerRates;
          final rates = _search.isEmpty
              ? allRates
              : allRates
                  .where((r) => r.customerName
                      .toLowerCase()
                      .contains(_search.toLowerCase()))
                  .toList();

          return Column(
            children: [
              // ── Info banner ───────────────────────────────────────
              Container(
                color: AppTheme.navyMid,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 15, color: Colors.white54),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Rate overrides apply to all future imports. '
                        'CSV import format: Customer Name, Monthly Rate, Notes (optional)',
                        style:
                            TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _importCsv,
                      icon: const Icon(Icons.upload_file,
                          size: 14, color: AppTheme.tealLight),
                      label: const Text('Import CSV',
                          style: TextStyle(
                              color: AppTheme.tealLight, fontSize: 12)),
                    ),
                  ],
                ),
              ),

              // ── Search bar ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search customers…',
                    prefixIcon: Icon(Icons.search,
                        color: AppTheme.textSecondary),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),

              // ── Count row ─────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Text(
                      '${allRates.length} customer rate${allRates.length == 1 ? '' : 's'} saved',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                    const Spacer(),
                    if (allRates.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => _confirmClearAll(context, provider),
                        icon: const Icon(Icons.delete_sweep,
                            size: 14, color: AppTheme.red),
                        label: const Text('Clear All',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.red)),
                      ),
                  ],
                ),
              ),

              // ── Rate list ─────────────────────────────────────────
              Expanded(
                child: rates.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.price_change,
                                size: 48,
                                color: AppTheme.textSecondary
                                    .withValues(alpha: 0.4)),
                            const SizedBox(height: 16),
                            Text(
                              allRates.isEmpty
                                  ? 'No customer rates yet.\nAdd manually or import a CSV.'
                                  : 'No results for "$_search"',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppTheme.textSecondary),
                            ),
                            if (allRates.isEmpty) ...[
                              const SizedBox(height: 24),
                              ElevatedButton.icon(
                                onPressed: () => _editRate(null),
                                icon: const Icon(Icons.add),
                                label: const Text('Add First Customer'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: rates.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final r = rates[index];
                          return _RateTile(
                            rate: r,
                            onEdit: () => _editRate(r),
                            onDelete: () async {
                              await context
                                  .read<AppProvider>()
                                  .deleteCustomerRate(r);
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editRate(null),
        backgroundColor: AppTheme.teal,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Customer'),
      ),
    );
  }

  void _confirmClearAll(BuildContext context, AppProvider provider) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear All Rates?'),
        content: const Text(
            'This permanently removes all saved customer rate overrides.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await CustomerRateService.clearAll();
              provider.loadCustomerRates();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}

class _RateTile extends StatelessWidget {
  final CustomerRate rate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RateTile({
    required this.rate,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasOverride = rate.overrideMonthlyRate != null;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Left accent
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: hasOverride ? AppTheme.green : AppTheme.textSecondary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rate.customerName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    if (rate.ratePlanLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        rate.ratePlanLabel,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                    if (rate.notes.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        rate.notes,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                            fontStyle: FontStyle.italic),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (hasOverride)
                    Text(
                      Formatters.currency(rate.overrideMonthlyRate!),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.green,
                      ),
                    )
                  else
                    const Text(
                      'CSV price',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  const Text(
                    '/mo override',
                    style: TextStyle(
                        fontSize: 10, color: AppTheme.textSecondary),
                  ),
                  if (rate.lastUpdated != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      Formatters.dateShort(rate.lastUpdated),
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textSecondary),
                    ),
                  ],
                ],
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: onEdit,
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.edit_outlined,
                          size: 18, color: AppTheme.teal),
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: onDelete,
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.delete_outline,
                          size: 18, color: AppTheme.red),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
