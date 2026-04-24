// Surfsight Direct Management Screen
// A settings sub-page for managing Surfsight Direct camera entries.
// Allows: view table, add single entry, edit, delete, bulk import from .xlsx

import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/surfsight_direct_service.dart';
import '../utils/app_theme.dart';

class SurfsightDirectScreen extends StatefulWidget {
  final SurfsightDirectService service;
  const SurfsightDirectScreen({super.key, required this.service});

  @override
  State<SurfsightDirectScreen> createState() => _SurfsightDirectScreenState();
}

class _SurfsightDirectScreenState extends State<SurfsightDirectScreen> {
  List<SurfsightDirectEntry> _entries = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _entries = widget.service.entries.toList());
  }

  // ── Add / Edit dialog ──────────────────────────────────────────────────────

  Future<void> _showEditDialog({SurfsightDirectEntry? existing}) async {
    final nameCtrl =
        TextEditingController(text: existing?.orgName ?? '');
    final countCtrl =
        TextEditingController(text: existing != null ? '${existing.count}' : '');
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.navyDark,
        title: Text(
          existing == null ? 'Add Customer' : 'Edit Customer',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Customer / Org Name'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: countCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Active Device Count'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n <= 0) return 'Enter a positive integer';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final entry = SurfsightDirectEntry(
        orgName: nameCtrl.text.trim(),
        count: int.parse(countCtrl.text.trim()),
      );
      await widget.service.upsert(entry);
      _refresh();
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _delete(SurfsightDirectEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.navyDark,
        title: const Text('Remove Entry',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          'Remove "${entry.orgName}" (${entry.count} devices)?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.service.remove(entry.orgName);
      _refresh();
    }
  }

  // ── Bulk import from xlsx ─────────────────────────────────────────────────

  Future<void> _importXlsx() async {
    setState(() => _loading = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      final bytes = result.files.first.bytes;
      if (bytes == null) {
        _showSnack('Could not read file bytes.', isError: true);
        setState(() => _loading = false);
        return;
      }

      final imported = _parseXlsx(bytes);
      if (imported.isEmpty) {
        _showSnack('No "Activated" rows found in the spreadsheet.',
            isError: true);
        setState(() => _loading = false);
        return;
      }

      // Show preview dialog before committing
      if (!mounted) return;
      final ok = await _showImportPreview(imported);
      if (ok == true) {
        await widget.service.bulkImport(imported);
        _refresh();
        _showSnack(
            'Imported ${imported.length} customer${imported.length == 1 ? '' : 's'} '
            '(${imported.fold(0, (s, e) => s + e.count)} devices total).');
      }
    } catch (e) {
      _showSnack('Import failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Parse xlsx: Column C = Billing Status, Column F = Organization.
  /// Count rows where Billing Status == "Activated" grouped by Organization.
  List<SurfsightDirectEntry> _parseXlsx(Uint8List bytes) {
    final excel = xl.Excel.decodeBytes(bytes);
    final counts = <String, int>{};

    for (final sheetName in excel.tables.keys) {
      final sheet = excel.tables[sheetName]! as xl.Sheet;;
      final rows = sheet.rows;
      if (rows.isEmpty) continue;

      // Find header row (first row where column indices make sense)
      // Column C = index 2, Column F = index 5
      for (int r = 0; r < rows.length; r++) {
        final row = rows[r];
        if (row.length < 6) continue;

        final statusCell = row[2]?.value?.toString().trim() ?? '';
        final orgCell    = row[5]?.value?.toString().trim() ?? '';

        // Skip header rows or empty org cells
        if (orgCell.isEmpty) continue;
        if (statusCell.toLowerCase() == 'billing status') continue; // header row
        if (orgCell.toLowerCase() == 'organization') continue;

        if (statusCell.toLowerCase() == 'activated') {
          counts[orgCell] = (counts[orgCell] ?? 0) + 1;
        }
      }
    }

    return counts.entries
        .where((e) => e.value > 0)
        .map((e) => SurfsightDirectEntry(orgName: e.key, count: e.value))
        .toList()
      ..sort((a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()));
  }

  Future<bool?> _showImportPreview(List<SurfsightDirectEntry> entries) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.navyDark,
        title: Text(
          'Import Preview — ${entries.length} customers',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: SizedBox(
          width: 360,
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The following will be merged into your Surfsight Direct list '
                '(existing entries for matching orgs will be overwritten):',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(e.orgName,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                          ),
                          _badge('${e.count}'),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Total devices: ${entries.fold(0, (s, e) => s + e.count)}',
                style: const TextStyle(
                    color: AppTheme.tealLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : AppTheme.teal,
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _entries.fold(0, (s, e) => s + e.count);

    return Scaffold(
      backgroundColor: AppTheme.scaffoldBg,
      appBar: AppBar(
        backgroundColor: AppTheme.navyDark,
        title: const Row(
          children: [
            Icon(Icons.videocam, size: 18, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Surfsight Direct',
                style: TextStyle(fontSize: 16)),
          ],
        ),
        actions: [
          // Import xlsx button
          Tooltip(
            message: 'Import from .xlsx',
            child: IconButton(
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upload_file, color: Colors.white),
              onPressed: _loading ? null : _importXlsx,
            ),
          ),
          // Add single entry
          Tooltip(
            message: 'Add customer',
            child: IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () => _showEditDialog(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Summary banner
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.navyDark,
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Surfsight Direct cameras are billed in QuickBooks under '
                    '"Surfsight Service : SS Service Fee" but do not appear in MyAdmin. '
                    'These counts are added to the audit comparison.',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          // Stats row
          if (_entries.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              color: AppTheme.navyDark.withValues(alpha: 0.6),
              child: Row(
                children: [
                  _statChip(
                      '${_entries.length}',
                      'customers',
                      AppTheme.teal),
                  const SizedBox(width: 12),
                  _statChip('$total', 'devices', Colors.blueAccent),
                ],
              ),
            ),
          const Divider(height: 1, color: AppTheme.divider),
          // Table header
          if (_entries.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              color: AppTheme.navyDark,
              child: const Row(
                children: [
                  Expanded(
                    child: Text('CUSTOMER / ORG NAME',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white38,
                            letterSpacing: 0.5)),
                  ),
                  SizedBox(width: 8),
                  Text('DEVICES',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white38,
                          letterSpacing: 0.5)),
                  SizedBox(width: 72), // space for action buttons
                ],
              ),
            ),
          // Entry list
          Expanded(
            child: _entries.isEmpty
                ? _emptyState()
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: AppTheme.divider),
                    itemBuilder: (_, i) => _EntryRow(
                      entry: _entries[i],
                      onEdit: () => _showEditDialog(existing: _entries[i]),
                      onDelete: () => _delete(_entries[i]),
                    ),
                  ),
          ),
        ],
      ),
      // FAB to add when list is non-empty (complements AppBar button)
      floatingActionButton: _entries.isNotEmpty
          ? FloatingActionButton.small(
              backgroundColor: AppTheme.teal,
              onPressed: () => _showEditDialog(),
              tooltip: 'Add customer',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_off,
                  size: 48, color: Colors.white24),
              const SizedBox(height: 16),
              const Text(
                'No Surfsight Direct customers yet.',
                style: TextStyle(
                    color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Import a device list spreadsheet (.xlsx) or add customers '
                'manually using the buttons above.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.teal),
                onPressed: _importXlsx,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Import .xlsx'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.teal),
                    foregroundColor: AppTheme.tealLight),
                onPressed: () => _showEditDialog(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Manually'),
              ),
            ],
          ),
        ),
      );

  Widget _statChip(String value, String label, Color color) => Row(
        children: [
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          Text(label,
              style:
                  const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      );

  Widget _badge(String text) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.teal.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppTheme.teal.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: const TextStyle(
                color: AppTheme.tealLight,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      );
}

// ── Single entry row ──────────────────────────────────────────────────────────

class _EntryRow extends StatelessWidget {
  final SurfsightDirectEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _EntryRow({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.cardBg,
      child: ListTile(
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(
        entry.orgName,
        style: const TextStyle(
            color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Device count badge
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.teal.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.teal.withValues(alpha: 0.4)),
            ),
            child: Text(
              '${entry.count}',
              style: const TextStyle(
                  color: AppTheme.tealLight,
                  fontSize: 13,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 4),
          // Edit button
          IconButton(
            icon: const Icon(Icons.edit_outlined,
                size: 18, color: Colors.white38),
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
          // Delete button
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 18, color: Colors.red),
            tooltip: 'Remove',
            onPressed: onDelete,
          ),
        ],
      ),
      ),  // ListTile
    );   // ColoredBox
  }
}

// ── Input decoration helper ───────────────────────────────────────────────────

InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
      floatingLabelStyle: const TextStyle(color: AppTheme.tealLight, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF1A2540), // dark navy matching the dialog background
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: Colors.white24),
        borderRadius: BorderRadius.circular(8),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: AppTheme.teal, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.red.shade400),
        borderRadius: BorderRadius.circular(8),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.red.shade400, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      errorStyle: const TextStyle(color: Colors.red, fontSize: 11),
    );
