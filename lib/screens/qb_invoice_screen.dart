// QB Verify Screen
// Import a QuickBooks "Sales by Customer Detail" CSV and cross-reference
// against the loaded activation CSV to surface billing discrepancies.

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

// ── Data models ──────────────────────────────────────────────────────────────

enum VerifyStatus { match, overbilled, underbilled, qbOnly, activationOnly }

class QbInvoiceLine {
  final String invoiceNumber;
  final String date;
  final String description;
  final double qty;
  final double unitPrice;
  final double amount;

  const QbInvoiceLine({
    required this.invoiceNumber,
    required this.date,
    required this.description,
    required this.qty,
    required this.unitPrice,
    required this.amount,
  });
}

class QbCustomerSummary {
  final String customerName;
  final int billedCount;
  final double totalBilled;
  final List<QbInvoiceLine> lines;
  final int activatedCount;
  final List<String> activationSerials;

  const QbCustomerSummary({
    required this.customerName,
    required this.billedCount,
    required this.totalBilled,
    required this.lines,
    required this.activatedCount,
    required this.activationSerials,
  });

  VerifyStatus get status {
    if (activatedCount == 0 && billedCount == 0) return VerifyStatus.match;
    if (billedCount > 0 && activatedCount == 0) return VerifyStatus.qbOnly;
    if (billedCount == 0 && activatedCount > 0) return VerifyStatus.activationOnly;
    if (billedCount > activatedCount) return VerifyStatus.overbilled;
    if (billedCount < activatedCount) return VerifyStatus.underbilled;
    return VerifyStatus.match;
  }
}

// ── Parser ────────────────────────────────────────────────────────────────────

/// Parse a QuickBooks "Sales by Customer Detail" CSV export.
/// Returns a map of normalised customer name → list of invoice lines.
Map<String, List<QbInvoiceLine>> _parseQbSalesCsv(String content) {
  final lines = content.split(RegExp(r'\r?\n'));
  if (lines.isEmpty) return {};

  // Find the header row (contains "Name" and "Item")
  int headerIdx = -1;
  List<String> headers = [];
  for (int i = 0; i < lines.length; i++) {
    final row = _splitCsvRow(lines[i]);
    final lower = row.map((c) => c.toLowerCase()).toList();
    if (lower.any((c) => c.contains('name')) &&
        lower.any((c) => c.contains('item') || c.contains('product'))) {
      headerIdx = i;
      headers = row.map((c) => c.trim().toLowerCase()).toList();
      break;
    }
  }

  if (headerIdx < 0) return {};

  int nameIdx = headers.indexWhere((h) => h == 'name' || h == 'customer');
  int typeIdx = headers.indexWhere((h) => h == 'type');
  int numIdx  = headers.indexWhere((h) => h.contains('num') || h.contains('invoice'));
  int dateIdx = headers.indexWhere((h) => h == 'date');
  int itemIdx = headers.indexWhere((h) => h.contains('item') || h.contains('product') || h.contains('description'));
  int qtyIdx  = headers.indexWhere((h) => h == 'qty' || h == 'quantity');
  int rateIdx = headers.indexWhere((h) => h == 'rate' || h.contains('unit') || h.contains('price'));
  int amtIdx  = headers.indexWhere((h) => h == 'amount' || h == 'total');

  // Fallback column indices
  if (nameIdx < 0) nameIdx = 3;
  if (itemIdx < 0) itemIdx = 5;
  if (amtIdx < 0)  amtIdx  = headers.length > 7 ? 7 : headers.length - 1;

  final Map<String, List<QbInvoiceLine>> result = {};
  String currentCustomer = '';
  String currentInvoice  = '';
  String currentDate     = '';

  for (int i = headerIdx + 1; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty) continue;
    final cells = _splitCsvRow(raw);
    if (cells.length < 3) continue;

    String getCell(int idx) =>
        (idx >= 0 && idx < cells.length) ? cells[idx].trim() : '';

    final rowType = typeIdx >= 0 ? getCell(typeIdx).toLowerCase() : '';
    final nameCell = getCell(nameIdx);

    // Customer/Invoice header rows
    if (rowType.contains('invoice') || rowType.contains('total')) {
      if (nameCell.isNotEmpty) currentCustomer = nameCell;
      if (numIdx >= 0 && getCell(numIdx).isNotEmpty) {
        currentInvoice = getCell(numIdx);
      }
      if (dateIdx >= 0 && getCell(dateIdx).isNotEmpty) {
        currentDate = getCell(dateIdx);
      }
      // Some exports put line items on the same row as "Invoice"
      final item = getCell(itemIdx);
      if (item.isNotEmpty && !item.toLowerCase().contains('total')) {
        final customer =
            currentCustomer.isEmpty ? nameCell : currentCustomer;
        if (customer.isEmpty) continue;
        final normKey = customer.toLowerCase().trim();
        result.putIfAbsent(normKey, () => []);
        result[normKey]!.add(QbInvoiceLine(
          invoiceNumber: currentInvoice,
          date: currentDate,
          description: item,
          qty: double.tryParse(getCell(qtyIdx).replaceAll(',', '')) ?? 1.0,
          unitPrice:
              double.tryParse(getCell(rateIdx).replaceAll(RegExp(r'[,\$]'), '')) ??
                  0.0,
          amount:
              double.tryParse(getCell(amtIdx).replaceAll(RegExp(r'[,\$]'), '')) ??
                  0.0,
        ));
      }
      continue;
    }

    // Line item rows — use the "current" customer context
    final customer = nameCell.isNotEmpty ? nameCell : currentCustomer;
    if (customer.isEmpty) continue;

    final item = getCell(itemIdx);
    if (item.isEmpty || item.toLowerCase().contains('total')) continue;
    // Skip non-product rows like shipping or flat fees
    if (item.toLowerCase().contains('shipping')) continue;

    if (nameCell.isNotEmpty) currentCustomer = nameCell;

    final normKey = customer.toLowerCase().trim();
    result.putIfAbsent(normKey, () => []);
    result[normKey]!.add(QbInvoiceLine(
      invoiceNumber: currentInvoice,
      date: currentDate,
      description: item,
      qty: double.tryParse(getCell(qtyIdx).replaceAll(',', '')) ?? 1.0,
      unitPrice:
          double.tryParse(getCell(rateIdx).replaceAll(RegExp(r'[,\$]'), '')) ??
              0.0,
      amount:
          double.tryParse(getCell(amtIdx).replaceAll(RegExp(r'[,\$]'), '')) ??
              0.0,
    ));
  }

  return result;
}

List<String> _splitCsvRow(String row) {
  final cells = <String>[];
  bool inQuotes = false;
  final buf = StringBuffer();
  for (int i = 0; i < row.length; i++) {
    final ch = row[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  return cells;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class QbInvoiceScreen extends StatefulWidget {
  const QbInvoiceScreen({super.key});

  @override
  State<QbInvoiceScreen> createState() => _QbInvoiceScreenState();
}

class _QbInvoiceScreenState extends State<QbInvoiceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();

  /// Raw QB data: normKey → lines
  Map<String, List<QbInvoiceLine>> _qbData = {};
  bool _qbLoaded = false;
  String? _qbFileName;

  String _search = '';

  /// Expanded customer keys
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _searchCtrl.addListener(() {
      setState(() => _search = _searchCtrl.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Import ────────────────────────────────────────────────────────────────

  Future<void> _importQbCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        content = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }

      final parsed = _parseQbSalesCsv(content);
      if (!mounted) return;

      if (parsed.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not find invoice data. Make sure this is a '
                '"Sales by Customer Detail" CSV export from QuickBooks.'),
            backgroundColor: AppTheme.red,
          ),
        );
        return;
      }

      setState(() {
        _qbData = parsed;
        _qbLoaded = true;
        _qbFileName = file.name;
        _expanded.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Imported ${parsed.length} customers from "${file.name}"'),
          backgroundColor: AppTheme.teal,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import error: $e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }

  // ── Build summaries ───────────────────────────────────────────────────────

  List<QbCustomerSummary> _buildSummaries(AppProvider provider) {
    // Activation data: normalised name → serial list
    final Map<String, List<String>> activationMap = {};
    for (final group in provider.customerGroups) {
      final key = group.customerName.toLowerCase().trim();
      activationMap.putIfAbsent(key, () => []);
      for (final d in group.devices) {
        activationMap[key]!.add(d.serialNumber);
      }
    }

    final allKeys = {
      ...activationMap.keys,
      ..._qbData.keys,
    };

    return allKeys.map((key) {
      final qbLines  = _qbData[key] ?? [];
      final serials  = activationMap[key] ?? [];

      // Count only Geotab service line items (skip shipping, flat fees, etc.)
      final billedLines = qbLines.where((l) {
        final d = l.description.toLowerCase();
        return !d.contains('shipping') &&
               !d.contains('early term') &&
               !d.contains('mkt-fee') &&
               l.amount > 0;
      }).toList();

      // Find the display name (prefer QB name, then activation name)
      String displayName = key;
      if (_qbData.containsKey(key) && qbLines.isNotEmpty) {
        // Try to find original casing from QB data
        displayName = key; // Already normalised; we keep it as-is for now
      }
      // Try to restore proper casing from activation groups
      final actGroup = provider.customerGroups
          .where((g) => g.customerName.toLowerCase().trim() == key)
          .firstOrNull;
      if (actGroup != null) displayName = actGroup.customerName;

      return QbCustomerSummary(
        customerName: displayName.isEmpty ? key : displayName,
        billedCount: billedLines.length,
        totalBilled: billedLines.fold(0.0, (s, l) => s + l.amount),
        lines: qbLines,
        activatedCount: serials.length,
        activationSerials: serials,
      );
    }).toList()
      ..sort((a, b) {
        // Sort: issues first, then by customer name
        final aIssue = a.status != VerifyStatus.match ? 0 : 1;
        final bIssue = b.status != VerifyStatus.match ? 0 : 1;
        if (aIssue != bIssue) return aIssue - bIssue;
        return a.customerName.compareTo(b.customerName);
      });
  }

  // ── Filter for tab ────────────────────────────────────────────────────────

  List<QbCustomerSummary> _filter(
      List<QbCustomerSummary> all, int tabIndex) {
    List<QbCustomerSummary> list;
    switch (tabIndex) {
      case 1: // Issues
        list = all
            .where((s) =>
                s.status == VerifyStatus.overbilled ||
                s.status == VerifyStatus.underbilled)
            .toList();
        break;
      case 2: // Missing (Activation Only)
        list = all
            .where((s) => s.status == VerifyStatus.activationOnly)
            .toList();
        break;
      case 3: // QB Only
        list = all
            .where((s) => s.status == VerifyStatus.qbOnly)
            .toList();
        break;
      default:
        list = all;
    }
    if (_search.isEmpty) return list;
    return list
        .where((s) => s.customerName.toLowerCase().contains(_search))
        .toList();
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final hasActivations = provider.hasData;

    final summaries = (_qbLoaded || hasActivations)
        ? _buildSummaries(provider)
        : <QbCustomerSummary>[];

    final issueCount = summaries
        .where((s) =>
            s.status == VerifyStatus.overbilled ||
            s.status == VerifyStatus.underbilled)
        .length;
    final missingCount = summaries
        .where((s) => s.status == VerifyStatus.activationOnly)
        .length;
    final qbOnlyCount =
        summaries.where((s) => s.status == VerifyStatus.qbOnly).length;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.verified_outlined, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('QB Verify'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _importQbCsv,
            icon: const Icon(Icons.upload_file, size: 18, color: AppTheme.tealLight),
            label: const Text('Import QB Sales CSV',
                style: TextStyle(color: AppTheme.tealLight, fontSize: 12)),
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          tabs: [
            const Tab(text: 'All'),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Issues'),
                if (issueCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(issueCount, AppTheme.amber),
                ],
              ]),
            ),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Missing'),
                if (missingCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(missingCount, AppTheme.red),
                ],
              ]),
            ),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('QB Only'),
                if (qbOnlyCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(qbOnlyCount, Colors.grey),
                ],
              ]),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Status / info bar ───────────────────────────────────────────
          if (!_qbLoaded && !hasActivations)
            _EmptyState(onImport: _importQbCsv)
          else ...[
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search customers…',
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  isDense: true,
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        )
                      : null,
                ),
              ),
            ),

            // Status pills
            _StatusBar(
              qbLoaded: _qbLoaded,
              qbFileName: _qbFileName,
              hasActivations: hasActivations,
              totalCustomers: summaries.length,
              issueCount: issueCount,
              missingCount: missingCount,
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: List.generate(4, (tabIdx) {
                  final filtered = _filter(summaries, tabIdx);
                  if (filtered.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            tabIdx == 0
                                ? Icons.verified
                                : Icons.check_circle_outline,
                            size: 48,
                            color: AppTheme.green.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tabIdx == 0
                                ? 'No customers found'
                                : 'No issues in this category',
                            style: const TextStyle(
                                color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) => _CustomerVerifyCard(
                      summary: filtered[i],
                      expanded: _expanded.contains(
                          filtered[i].customerName.toLowerCase()),
                      onToggle: () {
                        final k = filtered[i].customerName.toLowerCase();
                        setState(() {
                          if (_expanded.contains(k)) {
                            _expanded.remove(k);
                          } else {
                            _expanded.add(k);
                          }
                        });
                      },
                    ),
                  );
                }),
              ),
            ),
          ],

          // ── Summary footer ───────────────────────────────────────────────
          if (summaries.isNotEmpty)
            _SummaryFooter(summaries: summaries),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyState({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.receipt_long,
                  size: 72,
                  color: AppTheme.navyAccent.withValues(alpha: 0.3)),
              const SizedBox(height: 20),
              const Text(
                'QB Verify',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              const Text(
                'Import a QuickBooks "Sales by Customer Detail" CSV to '
                'verify that every active device is being invoiced correctly.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 8),
              const Text(
                'You can also load the QB report without loading an activation CSV '
                '— customers will show as QB Only until activations are loaded.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import QB Sales CSV'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.navyAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 14),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'QuickBooks → Reports → Sales → Sales by Customer Detail → Export as CSV',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Status bar ─────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final bool qbLoaded;
  final String? qbFileName;
  final bool hasActivations;
  final int totalCustomers;
  final int issueCount;
  final int missingCount;

  const _StatusBar({
    required this.qbLoaded,
    required this.qbFileName,
    required this.hasActivations,
    required this.totalCustomers,
    required this.issueCount,
    required this.missingCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          _Pill(
            icon: qbLoaded ? Icons.check_circle : Icons.radio_button_unchecked,
            label: qbLoaded
                ? (qbFileName ?? 'QB data loaded')
                : 'No QB data — tap Import',
            color: qbLoaded ? AppTheme.teal : Colors.grey,
          ),
          _Pill(
            icon: hasActivations
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            label: hasActivations ? 'Activations loaded' : 'No activations loaded',
            color: hasActivations ? AppTheme.teal : Colors.grey,
          ),
          if (issueCount > 0)
            _Pill(
              icon: Icons.warning_amber,
              label: '$issueCount billing issue${issueCount > 1 ? 's' : ''}',
              color: AppTheme.amber,
            ),
          if (missingCount > 0)
            _Pill(
              icon: Icons.error,
              label: '$missingCount not invoiced',
              color: AppTheme.red,
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Customer verify card ──────────────────────────────────────────────────────

class _CustomerVerifyCard extends StatelessWidget {
  final QbCustomerSummary summary;
  final bool expanded;
  final VoidCallback onToggle;

  const _CustomerVerifyCard({
    required this.summary,
    required this.expanded,
    required this.onToggle,
  });

  Color get _statusColor {
    switch (summary.status) {
      case VerifyStatus.match:          return AppTheme.green;
      case VerifyStatus.overbilled:     return AppTheme.amber;
      case VerifyStatus.underbilled:    return AppTheme.red;
      case VerifyStatus.qbOnly:         return Colors.grey;
      case VerifyStatus.activationOnly: return AppTheme.red;
    }
  }

  IconData get _statusIcon {
    switch (summary.status) {
      case VerifyStatus.match:          return Icons.check_circle;
      case VerifyStatus.overbilled:     return Icons.warning_amber;
      case VerifyStatus.underbilled:    return Icons.error;
      case VerifyStatus.qbOnly:         return Icons.help_outline;
      case VerifyStatus.activationOnly: return Icons.money_off;
    }
  }

  String get _statusLabel {
    switch (summary.status) {
      case VerifyStatus.match:          return 'Match';
      case VerifyStatus.overbilled:     return 'Overbilled';
      case VerifyStatus.underbilled:    return 'Underbilled';
      case VerifyStatus.qbOnly:         return 'QB Only';
      case VerifyStatus.activationOnly: return 'Not Invoiced';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          // Header row
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  // Status icon
                  Icon(_statusIcon, size: 20, color: _statusColor),
                  const SizedBox(width: 10),
                  // Customer name + billing info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.customerName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            _CountChip(
                              'Billed: ${summary.billedCount}',
                              summary.billedCount > 0
                                  ? AppTheme.navyAccent
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            _CountChip(
                              'Activated: ${summary.activatedCount}',
                              summary.activatedCount > 0
                                  ? AppTheme.teal
                                  : Colors.grey,
                            ),
                            if (summary.totalBilled > 0) ...[
                              const SizedBox(width: 6),
                              Text(
                                Formatters.currency(summary.totalBilled),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _statusColor.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      _statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _statusColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // Expanded detail
          if (expanded) ...[
            const Divider(height: 1, color: AppTheme.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // QB invoice lines
                  if (summary.lines.isNotEmpty) ...[
                    const Text(
                      'QB INVOICE LINES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _InvoiceTable(lines: summary.lines),
                    const SizedBox(height: 14),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'No QB invoice lines for this customer.',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            fontStyle: FontStyle.italic),
                      ),
                    ),

                  // Activation serials
                  if (summary.activationSerials.isNotEmpty) ...[
                    const Text(
                      'ACTIVATED DEVICES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: summary.activationSerials
                          .map((s) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppTheme.teal.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                      color: AppTheme.teal
                                          .withValues(alpha: 0.25)),
                                ),
                                child: Text(
                                  s,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: AppTheme.textPrimary),
                                ),
                              ))
                          .toList(),
                    ),
                  ] else
                    const Text(
                      'No activation records for this customer.',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Invoice table ─────────────────────────────────────────────────────────────

class _InvoiceTable extends StatelessWidget {
  final List<QbInvoiceLine> lines;
  const _InvoiceTable({required this.lines});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: const Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text('Description',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 40,
                    child: Text('Qty',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 60,
                    child: Text('Rate',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 70,
                    child: Text('Amount',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
              ],
            ),
          ),
          // Rows
          ...lines.asMap().entries.map((e) {
            final odd = e.key.isOdd;
            final l   = e.value;
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: odd
                  ? Colors.transparent
                  : AppTheme.navyDark.withValues(alpha: 0.03),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(l.description,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textPrimary)),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      l.qty == l.qty.roundToDouble()
                          ? l.qty.toInt().toString()
                          : l.qty.toStringAsFixed(1),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary),
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text(
                      Formatters.currency(l.unitPrice),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary),
                    ),
                  ),
                  SizedBox(
                    width: 70,
                    child: Text(
                      Formatters.currency(l.amount),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ── Summary footer ─────────────────────────────────────────────────────────────

class _SummaryFooter extends StatelessWidget {
  final List<QbCustomerSummary> summaries;
  const _SummaryFooter({required this.summaries});

  @override
  Widget build(BuildContext context) {
    final total   = summaries.length;
    final issues  = summaries.where((s) =>
        s.status == VerifyStatus.overbilled ||
        s.status == VerifyStatus.underbilled).length;
    final missing = summaries
        .where((s) => s.status == VerifyStatus.activationOnly)
        .length;
    final totalBilled = summaries.fold(0.0, (s, c) => s + c.totalBilled);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.navyDark,
        border: const Border(
            top: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$total customers',
            style: const TextStyle(
                fontSize: 11, color: Colors.white54),
          ),
          if (issues > 0)
            Text(
              '$issues issue${issues > 1 ? 's' : ''}',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.amber,
                  fontWeight: FontWeight.w600),
            ),
          if (missing > 0)
            Text(
              '$missing not invoiced',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.red,
                  fontWeight: FontWeight.w600),
            ),
          Text(
            totalBilled > 0
                ? 'Total billed: ${Formatters.currency(totalBilled)}'
                : 'No QB data',
            style: const TextStyle(
                fontSize: 11,
                color: Colors.white70,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _CountChip extends StatelessWidget {
  final String text;
  final Color color;
  const _CountChip(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _CountBadge(this.count, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Colors.white),
      ),
    );
  }
}
