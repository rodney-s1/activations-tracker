// Import history screen

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/import_session.dart';
import '../services/app_provider.dart';
import '../services/history_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.history, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('Import History'),
          ],
        ),
        actions: [
          Consumer<AppProvider>(
            builder: (context, provider, _) {
              if (provider.history.isEmpty) return const SizedBox();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Clear All History',
                onPressed: () => _confirmClearAll(context, provider),
              );
            },
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final sessions = provider.history;

          if (sessions.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 56, color: AppTheme.textSecondary),
                  SizedBox(height: 16),
                  Text(
                    'No imports yet',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Import a CSV from the dashboard\nto see history here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              return _SessionCard(
                session: sessions[index],
                index: index,
                onReload: () {
                  provider.loadFromHistory(sessions[index]);
                  Navigator.pop(context);
                },
                onDelete: () async {
                  // Find the actual Hive key for this session
                  final target = sessions[index];
                  // Find by comparing importedAt since sessions are HiveObjects
                  final box = HistoryService.box;
                  for (final key in box.keys.toList()) {
                    final s = box.get(key);
                    if (s != null &&
                        s.importedAt == target.importedAt &&
                        s.fileName == target.fileName) {
                      await box.delete(key);
                      break;
                    }
                  }
                  provider.refreshHistory();
                },
              );
            },
          );
        },
      ),
    );
  }

  void _confirmClearAll(BuildContext context, AppProvider provider) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear All History?'),
        content: const Text(
            'This will permanently delete all import records. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await HistoryService.clearAll();
              provider.refreshHistory();
            },
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final ImportSession session;
  final int index;
  final VoidCallback onReload;
  final VoidCallback onDelete;

  const _SessionCard({
    required this.session,
    required this.index,
    required this.onReload,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onReload,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.navyAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.insert_drive_file,
                    color: AppTheme.navyAccent, size: 22),
              ),
              const SizedBox(width: 14),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.fileName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Imported ${Formatters.dateTime(session.importedAt)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _tag('${session.totalCustomers} customers',
                            AppTheme.teal),
                        const SizedBox(width: 6),
                        _tag('${session.totalDevices} devices',
                            AppTheme.navyAccent),
                        if (session.reportDateFrom.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _tag(
                              '${session.reportDateFrom}–${session.reportDateTo}',
                              AppTheme.amber),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Cost + actions
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Formatters.currency(session.totalProratedCost),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.green,
                    ),
                  ),
                  const Text(
                    'prorated',
                    style:
                        TextStyle(fontSize: 10, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _iconBtn(
                          Icons.open_in_new, AppTheme.teal, 'Load', onReload),
                      const SizedBox(width: 4),
                      _iconBtn(
                          Icons.delete_outline, AppTheme.red, 'Delete',
                          onDelete),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w600),
        ),
      );

  static Widget _iconBtn(
      IconData icon, Color color, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}
