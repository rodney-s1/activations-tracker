// Serial Prefix Filter Settings Screen
// User can add/toggle/remove serial number prefix exclusions

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/serial_filter_rule.dart';
import '../services/filter_settings_service.dart';
import '../services/app_provider.dart';
import '../utils/app_theme.dart';

class SerialFilterScreen extends StatefulWidget {
  const SerialFilterScreen({super.key});

  @override
  State<SerialFilterScreen> createState() => _SerialFilterScreenState();
}

class _SerialFilterScreenState extends State<SerialFilterScreen> {
  List<SerialFilterRule> _rules = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _rules = FilterSettingsService.getAllRules();
    });
  }

  Future<void> _addRule() async {
    final prefixCtrl = TextEditingController();
    final labelCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Serial Prefix Filter'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Devices whose serial number starts with this prefix will be excluded from all reports.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: prefixCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Serial Prefix *',
                hintText: 'e.g. CO, GA, GE',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'e.g. OEM Relay Devices',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final prefix = prefixCtrl.text.trim().toUpperCase();
              if (prefix.isEmpty) return;
              await FilterSettingsService.addRule(SerialFilterRule(
                prefix: prefix,
                isExcluded: true,
                label: labelCtrl.text.trim(),
                isSystem: false,
              ));
              if (context.mounted) Navigator.pop(context);
              _reload();
              if (context.mounted) {
                context.read<AppProvider>().refreshFilterRules();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Separate system rules from user-added rules
    final systemRules = _rules.where((r) => r.isSystem).toList();
    final userRules = _rules.where((r) => !r.isSystem).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.filter_list, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Serial Prefix Filters'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Filter',
            onPressed: _addRule,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Info card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.navyAccent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.navyAccent.withValues(alpha: 0.2)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline,
                    size: 18, color: AppTheme.navyAccent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Checked prefixes are excluded from every report. '
                    'Uncheck to temporarily include them. '
                    'CN serials are handled separately — they are only excluded '
                    'if their rate plan contains [0250].',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (systemRules.isNotEmpty) ...[
            _sectionHeader('Built-In Rules'),
            const SizedBox(height: 8),
            ...systemRules.map((r) => _RuleTile(
                  rule: r,
                  onToggle: () async {
                    r.isExcluded = !r.isExcluded;
                    await FilterSettingsService.updateRule(r);
                    _reload();
                    if (context.mounted) {
                      context.read<AppProvider>().refreshFilterRules();
                    }
                  },
                  onDelete: null, // system rules can't be deleted
                )),
            const SizedBox(height: 20),
          ],

          _sectionHeader('Custom Filters'),
          const SizedBox(height: 8),
          if (userRules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.filter_none,
                        size: 40,
                        color: AppTheme.textSecondary.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    const Text(
                      'No custom filters yet.\nTap + to add a serial prefix to exclude.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            )
          else
            ...userRules.map((r) => _RuleTile(
                  rule: r,
                  onToggle: () async {
                    r.isExcluded = !r.isExcluded;
                    await FilterSettingsService.updateRule(r);
                    _reload();
                    if (context.mounted) {
                      context.read<AppProvider>().refreshFilterRules();
                    }
                  },
                  onDelete: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Remove Filter?'),
                        content: Text(
                            'Remove the "${r.prefix}" prefix filter?'),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          ElevatedButton(
                            onPressed: () =>
                                Navigator.pop(context, true),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.red),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await FilterSettingsService.deleteRule(r);
                      _reload();
                      if (context.mounted) {
                        context.read<AppProvider>().refreshFilterRules();
                      }
                    }
                  },
                )),

          const SizedBox(height: 32),
          // Quick-add common prefixes
          _sectionHeader('Quick-Add Common Prefixes'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ['CO', 'GA', 'GE', 'G9', 'GO']
                .where((p) => !_rules.any(
                    (r) => r.prefix.toUpperCase() == p))
                .map((p) => ActionChip(
                      label: Text(p),
                      avatar: const Icon(Icons.add, size: 14),
                      onPressed: () async {
                        await FilterSettingsService.addRule(
                            SerialFilterRule(
                          prefix: p,
                          isExcluded: true,
                          label: '',
                        ));
                        _reload();
                        if (context.mounted) {
                          context
                              .read<AppProvider>()
                              .refreshFilterRules();
                        }
                      },
                    ))
                .toList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRule,
        backgroundColor: AppTheme.teal,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Prefix'),
      ),
    );
  }

  Widget _sectionHeader(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.textSecondary,
          letterSpacing: 1,
        ),
      );
}

class _RuleTile extends StatelessWidget {
  final SerialFilterRule rule;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;

  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Checkbox(
          value: rule.isExcluded,
          activeColor: AppTheme.teal,
          onChanged: (_) => onToggle(),
        ),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: rule.isExcluded
                    ? AppTheme.red.withValues(alpha: 0.1)
                    : AppTheme.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                rule.prefix,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: rule.isExcluded ? AppTheme.red : AppTheme.green,
                ),
              ),
            ),
            if (rule.isSystem) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'BUILT-IN',
                  style: TextStyle(
                      fontSize: 9,
                      color: AppTheme.amber,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
        subtitle: rule.label.isNotEmpty
            ? Text(rule.label,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary))
            : Text(
                rule.isExcluded
                    ? 'Excluded from all reports'
                    : 'Currently included',
                style: TextStyle(
                  fontSize: 12,
                  color: rule.isExcluded
                      ? AppTheme.red.withValues(alpha: 0.7)
                      : AppTheme.green.withValues(alpha: 0.7),
                ),
              ),
        trailing: onDelete != null
            ? IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppTheme.textSecondary),
                onPressed: onDelete,
                tooltip: 'Remove filter',
              )
            : null,
      ),
    );
  }
}
