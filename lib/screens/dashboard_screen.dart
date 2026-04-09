// Main dashboard screen

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/activations_export_service.dart';
import '../services/app_provider.dart';
export '../services/csv_parser_service.dart' show MissingCodeFlag;
import '../utils/app_theme.dart';
import '../utils/formatters.dart';
import '../utils/web_download.dart';
import '../widgets/customer_card.dart';
import '../widgets/summary_bar.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isRefreshing = false;

  // ── Date range filter ──────────────────────────────────────────────
  DateTime? _filterFrom;
  DateTime? _filterTo;

  /// Returns groups filtered by active date range.
  /// A group is included if it has at least one device whose billingStart
  /// falls within [_filterFrom, _filterTo] (inclusive, date-only).
  List<dynamic> _applyDateFilter(List<dynamic> groups) {
    if (_filterFrom == null && _filterTo == null) return groups;
    return groups.where((g) {
      return g.devices.any((d) {
        final bs = d.billingStart;
        if (bs == null) return false;
        final day = DateTime(bs.year, bs.month, bs.day);
        if (_filterFrom != null && day.isBefore(_filterFrom!)) return false;
        if (_filterTo != null && day.isAfter(_filterTo!)) return false;
        return true;
      });
    }).toList();
  }

  Future<void> _pickDate(BuildContext context, bool isFrom) async {
    final initial = isFrom
        ? (_filterFrom ?? DateTime.now())
        : (_filterTo ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: isFrom ? 'Filter FROM date' : 'Filter TO date',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppTheme.navyAccent,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        final d = DateTime(picked.year, picked.month, picked.day);
        if (isFrom) {
          _filterFrom = d;
          if (_filterTo != null && _filterTo!.isBefore(d)) _filterTo = null;
        } else {
          _filterTo = d;
          if (_filterFrom != null && _filterFrom!.isAfter(d)) _filterFrom = null;
        }
      });
    }
  }

  Future<void> _importCsv(BuildContext context) async {
    final provider = context.read<AppProvider>();

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

      if (context.mounted) {
        // Clear all customer completion states when a fresh CSV is loaded —
        // a new month's data means everything starts unchecked again.
        final prefs = await SharedPreferences.getInstance();
        final keysToRemove = prefs.getKeys()
            .where((k) => k.startsWith('completed_v1_'))
            .toList();
        for (final k in keysToRemove) {
          await prefs.remove(k);
        }

        await provider.loadCsv(file.name, content);
        // Show blank customer warning after import
        if (context.mounted) {
          _showBlankCustomerWarning(context, provider);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing file: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  void _showBlankCustomerWarning(BuildContext context, AppProvider provider) {
    // Show all blanks (including dismissed) so user can un-check if needed
    final allBlanks = provider.allBlankCustomerWarnings;
    if (allBlanks.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogCtx) => _BlankCustomerDialog(
        allBlanks: allBlanks,
        onExport: (serialList, count) =>
            _exportBlankSerials(context, serialList, count),
      ),
    );
  }

  /// Shows a dialog listing devices where the required RPC is absent
  void _showMissingRpcWarning(BuildContext context, AppProvider provider) {
    final flags = provider.missingRpcFlags;
    if (flags.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.qr_code, color: Color(0xFF0F766E), size: 36),
        title: Text(
          '${flags.length} Device${flags.length > 1 ? 's' : ''} — Missing Rate Plan Code',
          style: const TextStyle(fontSize: 17),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These devices matched a customer plan code rule that requires a specific '
                'Rate Plan Code (RPC) in MyAdmin, but the RPC is missing. '
                'Geotab has not applied the discount to your account for these devices, '
                'so they are billed at full price. '
                'Add the correct RPC in MyAdmin to enable the discounted rate.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: flags.length,
                  itemBuilder: (_, i) {
                    final f = flags[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDFA),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFF0F766E).withValues(alpha: 0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.customerName,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Serial: ${f.serialNumber}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          Text(
                            'Plan: ${f.ratePlan}',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSecondary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (f.requiredRpc.isNotEmpty)
                            Text(
                              'Required RPC: ${f.requiredRpc}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF0F766E),
                                fontFamily: 'monospace',
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  /// Shows a dialog listing devices with missing/unmatched plan codes
  void _showMissingCodeWarning(BuildContext context, AppProvider provider) {
    final flags = provider.missingCodeFlags;
    if (flags.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.warning, color: Color(0xFFB45309), size: 36),
        title: Text(
          '${flags.length} Device${flags.length > 1 ? 's' : ''} — Missing Plan Code',
          style: const TextStyle(fontSize: 17),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These customers have plan codes configured, but the device\'s '
                'rate plan didn\'t match any of them. '
                'The CSV price was used as a fallback. '
                'Fix the plan code in MyAdmin or add the missing code in Pricing Settings.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: flags.length,
                  itemBuilder: (_, i) {
                    final f = flags[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.customerName,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Serial: ${f.serialNumber}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          Text(
                            'Plan: ${f.ratePlan}',
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  /// Saves serial list to a .txt file.
  /// On web: triggers browser download via anchor element.
  /// On mobile/desktop: writes to the app's temp directory.
  Future<void> _exportBlankSerials(
      BuildContext context, String content, int count) async {
    try {
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final fileName = 'blank_customers_$timestamp.txt';

      // On web the path is null — use a data URL download trick via JS interop
      // On native platforms write to a temp file and prompt save
      if (Platform.isAndroid || Platform.isIOS) {
        // Mobile: save to temp and notify
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(content);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved to ${file.path}'),
              backgroundColor: AppTheme.green,
            ),
          );
        }
      } else {
        // Web / desktop fallback — copy with notification
        await Clipboard.setData(ClipboardData(text: content));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '$count serials copied to clipboard (use Ctrl+V to paste into a text file)'),
              backgroundColor: AppTheme.teal,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  // ── Activations Snapshot Export ───────────────────────────────────────────

  /// Show a confirmation dialog with a summary of the snapshot, then download.
  Future<void> _showExportDialog(
      BuildContext context, AppProvider provider) async {
    final groups = provider.filteredGroups;
    final totalDevices =
        groups.fold<int>(0, (s, g) => s + g.devices.length);
    final completedCount = await ActivationsExportService.loadCompletedCustomers(groups);
    final processedMap = await ActivationsExportService.loadProcessedDates(groups);

    if (!context.mounted) return;

    final dateFmt = DateFormat('MMM d, yyyy');
    final now = DateTime.now();
    final fileName =
        'activations_snapshot_${DateFormat('yyyy-MM-dd').format(now)}.csv';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.download_rounded, color: AppTheme.teal, size: 20),
            SizedBox(width: 8),
            Text('Export Activations Snapshot'),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.teal.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ExportStat(
                        icon: Icons.people_outline,
                        label: 'Customers',
                        value: '${groups.length}'),
                    const SizedBox(height: 6),
                    _ExportStat(
                        icon: Icons.devices_other,
                        label: 'Devices',
                        value: '$totalDevices'),
                    const SizedBox(height: 6),
                    _ExportStat(
                        icon: Icons.check_box_outlined,
                        label: 'Completed',
                        value: '${completedCount.length} / ${groups.length}'),
                    const SizedBox(height: 6),
                    _ExportStat(
                        icon: Icons.calendar_today_outlined,
                        label: 'Export date',
                        value: dateFmt.format(now)),
                    const SizedBox(height: 6),
                    _ExportStat(
                        icon: Icons.insert_drive_file_outlined,
                        label: 'File',
                        value: fileName),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.amber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.amber.withValues(alpha: 0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 14, color: AppTheme.amber),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Exports all currently visible customers and devices '
                        'with resolved pricing, completed/processed status, '
                        'and pricing rule applied. Save this file before '
                        'importing a new CSV to keep a permanent record.',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.download, size: 14),
            label: const Text('Download CSV'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.teal,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await _doExport(
                context: context,
                provider: provider,
                groups: groups,
                completedCustomers: completedCount,
                processedDatesMap: processedMap,
                fileName: fileName,
              );
            },
          ),
        ],
      ),
    );
  }

  /// Generate the CSV and trigger download / clipboard copy.
  Future<void> _doExport({
    required BuildContext context,
    required AppProvider provider,
    required List groups,
    required Set<String> completedCustomers,
    required Map<String, Set<DateTime>> processedDatesMap,
    required String fileName,
  }) async {
    try {
      final csvContent = ActivationsExportService.buildCsv(
        groups: provider.filteredGroups,
        completedCustomers: completedCustomers,
        processedDatesMap: processedDatesMap,
        filterFrom: _filterFrom,
        filterTo: _filterTo,
      );

      if (kIsWeb) {
        // Web: trigger browser download via JS interop
        _webDownloadCsv(csvContent, fileName);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Downloading $fileName…'),
              backgroundColor: AppTheme.teal,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        // Mobile: write to temp and notify
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(csvContent);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved to ${file.path}'),
              backgroundColor: AppTheme.teal,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else {
        // Desktop fallback — clipboard
        await Clipboard.setData(ClipboardData(text: csvContent));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'CSV copied to clipboard — paste into a .csv file to save.'),
              backgroundColor: AppTheme.teal,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    }
  }

  /// Trigger a file download in the browser using a real Blob URL.
  void _webDownloadCsv(String content, String fileName) {
    try {
      triggerWebDownload(content, fileName);
    } catch (_) {
      // Fallback: clipboard
      Clipboard.setData(ClipboardData(text: content));
    }
  }

  /// Re-parses the current raw CSV content with fresh pricing/filter settings.
  Future<void> _refresh(BuildContext context) async {
    final provider = context.read<AppProvider>();
    if (!provider.hasData && provider.parseResult == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No data loaded — import a CSV first.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _isRefreshing = true);
    try {
      await provider.refreshCurrentData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Refreshed — pricing & filters re-applied.'),
            backgroundColor: AppTheme.green,
            duration: Duration(seconds: 2),
          ),
        );
        if (context.mounted) {
          _showBlankCustomerWarning(context, provider);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Refresh failed: $e'),
            backgroundColor: AppTheme.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.scaffoldBg,
      appBar: _buildAppBar(context),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          if (provider.state == AppState.loading) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: AppTheme.teal),
                  SizedBox(height: 16),
                  Text('Parsing CSV…',
                      style: TextStyle(color: AppTheme.textSecondary)),
                ],
              ),
            );
          }

          if (provider.state == AppState.error) {
            return _buildError(context, provider);
          }

          if (!provider.hasData) {
            return _buildEmptyState(context);
          }

          return _buildResults(context, provider);
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: const Row(
        children: [
          Icon(Icons.upload_file, size: 22, color: AppTheme.tealLight),
          SizedBox(width: 8),
          Text('Activations'),
        ],
      ),
      actions: [
        // Refresh button
        Consumer<AppProvider>(
          builder: (context, provider, _) {
            final canRefresh = provider.parseResult != null;
            return Tooltip(
              message: canRefresh
                  ? 'Re-apply filters & pricing to current data'
                  : 'No data loaded',
              child: IconButton(
                icon: _isRefreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        Icons.refresh,
                        color: canRefresh ? Colors.white : Colors.white30,
                      ),
                onPressed: canRefresh && !_isRefreshing
                    ? () => _refresh(context)
                    : null,
              ),
            );
          },
        ),
        // Export Snapshot icon button (only when data is loaded)
        Consumer<AppProvider>(
          builder: (context, provider, _) {
            if (!provider.hasData) return const SizedBox.shrink();
            return Tooltip(
              message: 'Export activations snapshot as CSV',
              child: IconButton(
                onPressed: () => _showExportDialog(context, provider),
                icon: const Icon(Icons.download_rounded, color: Colors.white),
              ),
            );
          },
        ),
        // Import CSV button
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: ElevatedButton.icon(
            onPressed: () => _importCsv(context),
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Import CSV'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.teal,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppTheme.navyAccent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.upload_file,
              size: 44,
              color: AppTheme.navyAccent,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'No activations loaded',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import your Device Contract Request\nAdmin CSV to calculate proration.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => _importCsv(context),
            icon: const Icon(Icons.upload_file),
            label: const Text('Import CSV File'),
            style: ElevatedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Use the tabs below to access History,\nFilters, Pricing, and Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, AppProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.red),
            const SizedBox(height: 16),
            Text(
              provider.errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.red),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => _importCsv(context),
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  /// Banner shown when one or more customers are hidden, with options to
  /// restore individual customers or restore all at once.
  Widget _buildHiddenBanner(BuildContext context, AppProvider provider) {
    final hidden = provider.hiddenCustomers.toList()..sort();
    final count = hidden.length;
    return Container(
      color: const Color(0xFF374151), // gray-700
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.visibility_off_outlined,
              size: 13, color: Colors.white54),
          const SizedBox(width: 6),
          Text(
            '$count customer${count == 1 ? '' : 's'} hidden',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          // Restore individual
          InkWell(
            onTap: () => _showRestoreHiddenDialog(context, provider, hidden),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                'Manage',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.tealLight,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Restore all
          InkWell(
            onTap: () => provider.unhideAllCustomers(),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                'Restore All',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.tealLight,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showRestoreHiddenDialog(
      BuildContext context, AppProvider provider, List<String> hidden) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Hidden Customers'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tap a customer to restore them to the list.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              ...hidden.map(
                (name) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_off_outlined,
                      size: 16, color: AppTheme.textSecondary),
                  title: Text(name,
                      style: const TextStyle(fontSize: 13)),
                  trailing: TextButton(
                    onPressed: () {
                      provider.unhideCustomer(name);
                      if (hidden.length == 1) Navigator.pop(dialogCtx);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.teal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: const Size(48, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Restore',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              provider.unhideAllCustomers();
              Navigator.pop(dialogCtx);
            },
            child: const Text('Restore All'),
          ),
        ],
      ),
    );
  }

  Widget _buildDateRangeFilter(
      BuildContext context,
      List<dynamic> groups,
      AppProvider provider) {
    final hasFilter = _filterFrom != null || _filterTo != null;
    final deviceCount =
        groups.fold<int>(0, (s, g) => s + (g.deviceCount as int));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 3),
      child: Row(
        children: [
          // ── Date filter chips ───────────────────────────────────
          const Icon(Icons.date_range, size: 14, color: AppTheme.navyAccent),
          const SizedBox(width: 5),
          _DateChip(
            label:
                _filterFrom != null ? Formatters.date(_filterFrom) : 'From',
            isSet: _filterFrom != null,
            onTap: () => _pickDate(context, true),
            onClear: _filterFrom != null
                ? () => setState(() => _filterFrom = null)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '→',
              style: TextStyle(
                fontSize: 11,
                color:
                    hasFilter ? AppTheme.navyAccent : AppTheme.textSecondary,
              ),
            ),
          ),
          _DateChip(
            label: _filterTo != null ? Formatters.date(_filterTo) : 'To',
            isSet: _filterTo != null,
            onTap: () => _pickDate(context, false),
            onClear: _filterTo != null
                ? () => setState(() => _filterTo = null)
                : null,
          ),
          if (hasFilter) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: () => setState(() {
                _filterFrom = null;
                _filterTo = null;
              }),
              borderRadius: BorderRadius.circular(4),
              child: const Icon(Icons.filter_alt_off,
                  size: 13, color: AppTheme.red),
            ),
          ],
          const Spacer(),
          // ── Count label ─────────────────────────────────────────
          Text(
            '${groups.length} customer${groups.length == 1 ? '' : 's'}'
            ' · $deviceCount devices',
            style: const TextStyle(
                fontSize: 11, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 4),
          // ── Clear data button ────────────────────────────────────
          InkWell(
            onTap: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Clear Current Data?'),
                content: const Text(
                    'This will clear the current view. The import will remain in history.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      provider.clearCurrent();
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text('✕ Clear',
                  style: TextStyle(
                      fontSize: 11, color: AppTheme.red)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, AppProvider provider) {
    final allGroups = provider.filteredGroups;
    final groups = _applyDateFilter(allGroups);
    final result = provider.parseResult!;
    final blanks = provider.blankCustomerWarnings;

    return Column(
      children: [
        // ── Report metadata banner ────────────────────────────────
        Container(
          color: AppTheme.navyMid,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: Row(
            children: [
              const Icon(Icons.insert_drive_file,
                  size: 13, color: Colors.white54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  provider.currentFileName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (result.dateFrom.isNotEmpty)
                Text(
                  '${result.dateFrom} → ${result.dateTo}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),

        // ── Blank customer warning banner ─────────────────────────
        if (blanks.isNotEmpty)
          GestureDetector(
            onTap: () => _showBlankCustomerWarning(context, provider),
            child: Container(
              color: AppTheme.amber,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${blanks.length} device${blanks.length > 1 ? 's' : ''} '
                      'had blank customer names — excluded. Tap to review.',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 16, color: Colors.white),
                ],
              ),
            ),
          ),

        // ── Missing plan-code warning banner ─────────────────────
        if (provider.missingCodeFlags.isNotEmpty)
          GestureDetector(
            onTap: () => _showMissingCodeWarning(context, provider),
            child: Container(
              color: const Color(0xFFB45309), // amber-700
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.warning, size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${provider.missingCodeFlags.length} device${provider.missingCodeFlags.length > 1 ? 's' : ''} '
                      'missing a matching plan code — tap to review.',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: Colors.white),
                ],
              ),
            ),
          ),

        // ── Missing RPC warning banner ────────────────────────────
        if (provider.missingRpcFlags.isNotEmpty)
          GestureDetector(
            onTap: () => _showMissingRpcWarning(context, provider),
            child: Container(
              color: const Color(0xFF0F766E), // teal-700
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.qr_code, size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${provider.missingRpcFlags.length} device${provider.missingRpcFlags.length > 1 ? 's' : ''} '
                      'missing required Rate Plan Code — billed at full price. Tap to review.',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: Colors.white),
                ],
              ),
            ),
          ),

        // ── Summary chips ─────────────────────────────────────────
        SummaryBar(
          chips: [
            SummaryChip(
              icon: Icons.business,
              label: 'CUSTOMERS',
              value: '${provider.customerGroups.length}',
            ),
            SummaryChip(
              icon: Icons.devices,
              label: 'DEVICES',
              value: '${provider.totalDeviceCount}',
            ),
            SummaryChip(
              icon: Icons.attach_money,
              label: 'PRORATED TOTAL',
              value: Formatters.currency(provider.grandTotalCustomerPrice),
              valueColor: AppTheme.greenLight,
            ),
            SummaryChip(
              icon: Icons.calendar_month,
              label: 'FULL MONTH',
              value: Formatters.currency(provider.grandTotalMonthly),
            ),
          ],
        ),

        // ── Search bar ────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 5, 16, 2),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search customer, serial, or plan…',
              prefixIcon: Icon(Icons.search, color: AppTheme.textSecondary),
              hintStyle: TextStyle(color: AppTheme.textSecondary),
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            ),
            onChanged: provider.setSearchQuery,
          ),
        ),

        // ── Hidden customers restore banner ───────────────────────
        if (provider.hiddenCustomers.isNotEmpty)
          _buildHiddenBanner(context, provider),

        // ── Date range filter + count/clear (merged into one row) ───
        _buildDateRangeFilter(context, groups, provider),

        // ── Customer cards list ───────────────────────────────────
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Text(
                    'No matching results',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: groups.length + 1,
                  itemBuilder: (context, index) {
                    if (index == groups.length) {
                      return _buildGrandTotal(provider);
                    }
                    return CustomerCard(
                      key: ValueKey(groups[index].customerName),
                      group: groups[index],
                      filterFrom: _filterFrom,
                      filterTo: _filterTo,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildGrandTotal(AppProvider provider) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.navyDark, AppTheme.navyMid],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GRAND TOTAL',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'All Customers · Proration Invoice',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Formatters.currency(provider.grandTotalCustomerPrice),
                style: const TextStyle(
                  color: AppTheme.greenLight,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${Formatters.currency(provider.grandTotalMonthly)} full month',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Date chip widget ──────────────────────────────────────────────────────────

class _DateChip extends StatelessWidget {
  final String label;
  final bool isSet;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _DateChip({
    required this.label,
    required this.isSet,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSet
              ? AppTheme.navyAccent.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSet
                ? AppTheme.navyAccent.withValues(alpha: 0.45)
                : const Color(0xFFCBD5E1),
            width: isSet ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSet ? Icons.event_available : Icons.calendar_today,
              size: 12,
              color: isSet ? AppTheme.navyAccent : AppTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSet ? FontWeight.w700 : FontWeight.w500,
                color: isSet ? AppTheme.navyAccent : AppTheme.textSecondary,
              ),
            ),
            if (onClear != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onClear,
                child: Icon(
                  Icons.close,
                  size: 11,
                  color: AppTheme.navyAccent.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Helper widget for export dialog stats ────────────────────────────────────

class _ExportStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ExportStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: AppTheme.teal),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: const TextStyle(
              fontSize: 12, color: AppTheme.textSecondary),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── Blank Customer Warning Dialog ─────────────────────────────────────────────
// Stateful so checkboxes update instantly without rebuilding parent.

class _BlankCustomerDialog extends StatefulWidget {
  final List<BlankCustomerRecord> allBlanks;
  final Future<void> Function(String serialList, int count) onExport;

  const _BlankCustomerDialog({
    required this.allBlanks,
    required this.onExport,
  });

  @override
  State<_BlankCustomerDialog> createState() => _BlankCustomerDialogState();
}

class _BlankCustomerDialogState extends State<_BlankCustomerDialog> {
  // Local set of serials the user has checked off as "done"
  late Set<String> _checked;

  @override
  void initState() {
    super.initState();
    // Pre-populate with whatever is already dismissed in the provider
    final provider = context.read<AppProvider>();
    _checked = Set<String>.from(provider.dismissedBlankSerials);
  }

  Future<void> _toggle(String serial, bool? value) async {
    final provider = context.read<AppProvider>();
    if (value == true) {
      await provider.dismissBlankSerial(serial);
    } else {
      await provider.undismissBlankSerial(serial);
    }
    setState(() {
      if (value == true) {
        _checked.add(serial);
      } else {
        _checked.remove(serial);
      }
    });
  }

  Future<void> _checkAll() async {
    final provider = context.read<AppProvider>();
    await provider.dismissAllBlankSerials();
    setState(() {
      _checked = widget.allBlanks.map((b) => b.serialNumber).toSet();
    });
  }

  @override
  Widget build(BuildContext context) {
    final blanks = widget.allBlanks;
    final undoneCount = blanks.where((b) => !_checked.contains(b.serialNumber)).length;

    final serialList = blanks
        .map((b) => b.serialNumber.isEmpty ? '(no serial)' : b.serialNumber)
        .join('\n');

    return AlertDialog(
      icon: Icon(
        undoneCount == 0
            ? Icons.check_circle_rounded
            : Icons.warning_amber_rounded,
        color: undoneCount == 0 ? AppTheme.teal : AppTheme.amber,
        size: 36,
      ),
      title: Text(
        undoneCount == 0
            ? 'All ${blanks.length} Resolved'
            : '$undoneCount of ${blanks.length} Blank Customer Name${blanks.length > 1 ? 's' : ''} Remaining',
        style: const TextStyle(fontSize: 17),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Check off each device once you\'ve fixed it in your system. '
              'Checked items won\'t show the warning again on future imports.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 10),

            // ── Copy / Export / Check-All row ─────────────────────
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: serialList));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            '${blanks.length} serial number${blanks.length > 1 ? 's' : ''} copied to clipboard'),
                        backgroundColor: AppTheme.teal,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy All', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.teal,
                    side: const BorderSide(color: AppTheme.teal),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.onExport(serialList, blanks.length);
                  },
                  icon: const Icon(Icons.download, size: 14),
                  label:
                      const Text('Export .txt', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.navyAccent,
                    side: const BorderSide(color: AppTheme.navyAccent),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                if (undoneCount > 0)
                  OutlinedButton.icon(
                    onPressed: _checkAll,
                    icon: const Icon(Icons.done_all, size: 14),
                    label: const Text('Mark All Done',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.teal,
                      side: const BorderSide(color: AppTheme.teal),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Serial list with checkboxes ────────────────────────
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: blanks.length,
                itemBuilder: (_, i) {
                  final b = blanks[i];
                  final done = _checked.contains(b.serialNumber);
                  return AnimatedOpacity(
                    opacity: done ? 0.45 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: done
                            ? AppTheme.teal.withValues(alpha: 0.06)
                            : AppTheme.amber.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: done
                              ? AppTheme.teal.withValues(alpha: 0.25)
                              : AppTheme.amber.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Checkbox on the left
                          Checkbox(
                            value: done,
                            activeColor: AppTheme.teal,
                            onChanged: (v) => _toggle(b.serialNumber, v),
                          ),
                          // Serial + meta
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  b.serialNumber.isEmpty
                                      ? '(no serial)'
                                      : b.serialNumber,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    decoration: done
                                        ? TextDecoration.lineThrough
                                        : TextDecoration.none,
                                  ),
                                ),
                                Text(
                                  'Line ${b.lineNumber}  ·  ${b.requestType}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          // Copy button
                          IconButton(
                            icon: const Icon(Icons.copy,
                                size: 14, color: AppTheme.textSecondary),
                            tooltip: 'Copy serial',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              Clipboard.setData(
                                  ClipboardData(text: b.serialNumber));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Serial copied'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
