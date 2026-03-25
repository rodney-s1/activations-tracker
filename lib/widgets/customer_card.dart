// Customer card widget — always expanded, with completed checkbox
// Per-billing-date invoice lines with individual copy buttons

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/customer_group.dart';
import '../models/activation_record.dart';
import '../services/app_provider.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CustomerCard extends StatefulWidget {
  final CustomerGroup group;

  /// Set of billing-start dates (year-month-day) the user has already processed.
  /// Rows matching these dates will be visually dimmed and skipped in "copy all".
  final Set<DateTime> processedDates;

  /// Optional date range filter from the dashboard.
  /// Only date groups whose date falls within [filterFrom, filterTo] are shown.
  final DateTime? filterFrom;
  final DateTime? filterTo;

  const CustomerCard({
    super.key,
    required this.group,
    this.processedDates = const {},
    this.filterFrom,
    this.filterTo,
  });

  @override
  State<CustomerCard> createState() => _CustomerCardState();
}

class _CustomerCardState extends State<CustomerCard> {
  bool _completed = false;
  final Set<DateTime> _localProcessed = {};

  // ── Inline rename ─────────────────────────────────────────────────────────
  bool _isEditing = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocus = FocusNode();

  // ── Completion persistence ────────────────────────────────────────────────
  /// SharedPreferences key for this customer's completed state.
  String get _prefKey =>
      'completed_v1_${widget.group.customerName.replaceAll(RegExp(r'[^\w]'), '_')}';

  Future<void> _loadCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _completed = prefs.getBool(_prefKey) ?? false;
      });
    }
  }

  Future<void> _saveCompleted(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.group.customerName);
    _loadCompleted(); // restore persisted state
  }

  @override
  void didUpdateWidget(CustomerCard old) {
    super.didUpdateWidget(old);
    // Keep controller in sync if provider renames the group externally
    if (!_isEditing && old.group.customerName != widget.group.customerName) {
      _nameController.text = widget.group.customerName;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _startEditing() {
    _nameController.text = widget.group.customerName;
    setState(() => _isEditing = true);
    // Auto-select all text so user can overtype immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
      _nameController.selection =
          TextSelection(baseOffset: 0, extentOffset: _nameController.text.length);
    });
  }

  Future<void> _saveEdit(BuildContext context) async {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty && newName != widget.group.customerName) {
      // Await the rename so SharedPreferences is fully written before any
      // potential page reload \u2014 this prevents the name reverting on refresh.
      await context.read<AppProvider>().renameCustomer(widget.group.customerName, newName);
    }
    if (mounted) setState(() => _isEditing = false);
  }

  void _cancelEdit() {
    _nameController.text = widget.group.customerName;
    setState(() => _isEditing = false);
  }

  Future<void> _confirmHide(BuildContext context) async {
    final name = widget.group.customerName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove from View?'),
        content: Text(
          '"$name" will be hidden from the Activations page.\n\n'
          'You can restore it any time from the menu at the top of the '
          'customer list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<AppProvider>().hideCustomer(name);
    }
  }

  static const _completedBg   = Color(0xFFECFDF5); // very light green bg
  static const _completedBar  = Color(0xFF16A34A); // solid green accent bar
  static const _completedCard = Color(0xFFDCFCE7); // slightly deeper green for subtotal

  Set<DateTime> get _allProcessed => {...widget.processedDates, ..._localProcessed};

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final accent = _completed ? _completedBar : AppTheme.navyAccent;

    // Apply date range filter: only show date-groups within [filterFrom, filterTo]
    final allDates = g.sortedBillingDates;
    final sortedDates = (widget.filterFrom == null && widget.filterTo == null)
        ? allDates
        : allDates.where((date) {
            final day = DateTime(date.year, date.month, date.day);
            if (widget.filterFrom != null && day.isBefore(widget.filterFrom!)) return false;
            if (widget.filterTo != null && day.isAfter(widget.filterTo!)) return false;
            return true;
          }).toList();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: _completed ? _completedBg : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _completed
              ? _completedBar.withValues(alpha: 0.45)
              : Colors.transparent,
          width: _completed ? 1.5 : 0,
        ),
        boxShadow: [
          BoxShadow(
            color: _completed
                ? _completedBar.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Header ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ✅ Completed checkbox
                Tooltip(
                  message: _completed ? 'Mark as incomplete' : 'Mark as completed',
                  child: Transform.scale(
                    scale: 1.15,
                    child: Checkbox(
                      value: _completed,
                      activeColor: _completedBar,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      onChanged: (v) {
                        final newVal = v ?? false;
                        setState(() => _completed = newVal);
                        _saveCompleted(newVal);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                // Left: color accent bar
                Container(
                  width: 4,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),

                // Customer name + badges
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Name row: static view or inline editor ────────
                      if (_isEditing)
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _nameController,
                                focusNode: _nameFocus,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    borderSide: const BorderSide(
                                        color: AppTheme.navyAccent, width: 1.5),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    borderSide: const BorderSide(
                                        color: AppTheme.navyAccent, width: 1.5),
                                  ),
                                ),
                                onSubmitted: (_) => _saveEdit(context),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Save
                            Tooltip(
                              message: 'Save name',
                              child: InkWell(
                                onTap: () => _saveEdit(context),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: AppTheme.navyAccent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.check,
                                      size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Cancel
                            Tooltip(
                              message: 'Cancel',
                              child: InkWell(
                                onTap: _cancelEdit,
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE2E8F0),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.close,
                                      size: 14,
                                      color: AppTheme.textSecondary),
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                g.customerName,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _completed
                                      ? _completedBar
                                      : AppTheme.textPrimary,
                                  decoration: _completed
                                      ? TextDecoration.none
                                      : null,
                                ),
                              ),
                            ),
                            if (_completed) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _completedBar,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check,
                                        size: 10, color: Colors.white),
                                    SizedBox(width: 3),
                                    Text(
                                      'DONE',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            // Pencil edit icon
                            const SizedBox(width: 6),
                            Tooltip(
                              message: 'Rename customer',
                              child: InkWell(
                                onTap: _startEditing,
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 13,
                                    color: AppTheme.textSecondary
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _badge(
                            () {
                              // Show filtered device count when date filter is active
                              final filteredCount = sortedDates.isEmpty
                                  ? g.deviceCount
                                  : sortedDates.fold<int>(0, (sum, d) =>
                                      sum + (g.devicesByBillingDate[d]?.length ?? 0));
                              return '$filteredCount device${filteredCount == 1 ? '' : 's'}';
                            }(),
                            _completed ? _completedBar : AppTheme.teal,
                          ),
                          const SizedBox(width: 8),
                          if (sortedDates.isNotEmpty) ...[
                            Icon(Icons.calendar_today,
                                size: 12,
                                color: AppTheme.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              'From ${Formatters.date(sortedDates.first)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ] else if (g.earliestBillingStart != null) ...[
                            Icon(Icons.calendar_today,
                                size: 12,
                                color: AppTheme.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              'From ${Formatters.date(g.earliestBillingStart)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Right: prorated total + hide button
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // ── Hide/remove customer button ───────────────
                    Tooltip(
                      message: 'Remove from view',
                      child: InkWell(
                        onTap: () => _confirmHide(context),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.only(
                              bottom: 4, left: 4),
                          child: Icon(
                            Icons.visibility_off_outlined,
                            size: 14,
                            color: AppTheme.textSecondary
                                .withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      Formatters.currency(g.totalCustomerProratedCost),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: _completed ? _completedBar : AppTheme.green,
                      ),
                    ),
                    const Text(
                      'Prorated',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${Formatters.currency(g.totalCustomerMonthlyCost)}/mo',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Divider ───────────────────────────────────────────────
          Divider(
            height: 1,
            color: _completed
                ? _completedBar.withValues(alpha: 0.2)
                : AppTheme.divider,
          ),

          // ── Column headers ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text('Serial / Plan', style: _headerStyle()),
                ),
                SizedBox(
                  width: 90,
                  child: Text('Billing Start',
                      style: _headerStyle(), textAlign: TextAlign.center),
                ),
                SizedBox(
                  width: 72,
                  child: Text('Monthly',
                      style: _headerStyle(), textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 80,
                  child: Text('Prorated',
                      style: _headerStyle(), textAlign: TextAlign.right),
                ),
              ],
            ),
          ),

          // ── Per-date groups with copy buttons ─────────────────────
          if (sortedDates.isEmpty)
            ...g.devices.map((d) => _DeviceRow(record: d, completed: _completed, customerGroup: g))
          else
            ...sortedDates.map((date) {
              final devicesOnDate = g.devicesByBillingDate[date] ?? [];
              final isProcessed = _allProcessed.contains(date);
              return _DateGroup(
                date: date,
                devices: devicesOnDate,
                group: g,
                completed: _completed,
                isProcessed: isProcessed,
                completedBar: _completedBar,
                onToggleProcessed: () {
                  setState(() {
                    if (_localProcessed.contains(date)) {
                      _localProcessed.remove(date);
                    } else {
                      _localProcessed.add(date);
                    }
                  });
                },
              );
            }),

          // ── Subtotal footer ───────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              color: _completed ? _completedCard : const Color(0xFFF8FAFC),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Column(
              children: [
                // ── Totals row ──────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _completed ? 'Invoiced ✓' : 'Customer Subtotal',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _completed ? _completedBar : AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    SizedBox(width: 90, child: Container()),
                    SizedBox(
                      width: 72,
                      child: Text(
                        Formatters.currency(g.totalCustomerMonthlyCost),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Text(
                        Formatters.currency(g.totalCustomerProratedCost),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: _completed ? _completedBar : AppTheme.green,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),

                // ── Copy Invoice Lines button (copies all dates) ────
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: _CopyInvoiceLinesButton(
                    group: g,
                    completed: _completed,
                    completedBar: _completedBar,
                    skipDates: _allProcessed,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static TextStyle _headerStyle() => const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: AppTheme.textSecondary,
        letterSpacing: 0.5,
      );

  static Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      );
}

// ── Per-Date Group with individual copy button ────────────────────────────────

class _DateGroup extends StatefulWidget {
  final DateTime date;
  final List<ActivationRecord> devices;
  final CustomerGroup group;
  final bool completed;
  final bool isProcessed;
  final Color completedBar;
  final VoidCallback onToggleProcessed;

  const _DateGroup({
    required this.date,
    required this.devices,
    required this.group,
    required this.completed,
    required this.isProcessed,
    required this.completedBar,
    required this.onToggleProcessed,
  });

  @override
  State<_DateGroup> createState() => _DateGroupState();
}

class _DateGroupState extends State<_DateGroup> {
  bool _copied = false;

  Future<void> _copyDateLine(BuildContext context) async {
    final line = widget.group.buildInvoiceLineForDate(widget.date);
    if (line.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: line));
    setState(() => _copied = true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${_fmtDateLabel(widget.date)} copied to clipboard!'),
          backgroundColor: AppTheme.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    }
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) setState(() => _copied = false);
  }

  String _fmtDateLabel(DateTime d) {
    final fmt = DateFormat('MMM d');
    return fmt.format(d);
  }

  @override
  Widget build(BuildContext context) {
    final devicesOnDate = widget.devices;
    final isProcessed = widget.isProcessed;
    final dateLabel = _fmtDateLabel(widget.date);

    // Last day of the billing month
    final lastDay = DateTime(widget.date.year, widget.date.month + 1, 0).day;
    final monthFmt = DateFormat('MMMM');
    final monthName = monthFmt.format(widget.date);
    final endMonthName =
        monthFmt.format(DateTime(widget.date.year, widget.date.month, lastDay));
    final year = widget.date.year;

    final dateRangeLabel =
        '$monthName ${widget.date.day} – $endMonthName $lastDay $year';

    final dotColor = widget.completed
        ? widget.completedBar
        : (isProcessed ? const Color(0xFF94A3B8) : AppTheme.teal);

    return Opacity(
      opacity: isProcessed ? 0.5 : 1.0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Date header row with copy button ────────────────────────
          Divider(
            height: 1,
            color: widget.completed
                ? widget.completedBar.withValues(alpha: 0.2)
                : AppTheme.divider,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                Icon(
                  isProcessed ? Icons.check_circle : Icons.calendar_today,
                  size: 13,
                  color: isProcessed
                      ? const Color(0xFF16A34A)
                      : AppTheme.navyAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dateRangeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isProcessed
                          ? const Color(0xFF94A3B8)
                          : AppTheme.navyAccent,
                      decoration: isProcessed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Mark processed toggle
                Tooltip(
                  message: isProcessed ? 'Unmark processed' : 'Mark as processed',
                  child: InkWell(
                    onTap: widget.onToggleProcessed,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isProcessed
                                ? Icons.undo_rounded
                                : Icons.done_all_rounded,
                            size: 13,
                            color: isProcessed
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            isProcessed ? 'Undo' : 'Done',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isProcessed
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF16A34A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Per-date copy button
                Tooltip(
                  message: 'Copy "$dateLabel" invoice line',
                  child: InkWell(
                    onTap: () => _copyDateLine(context),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _copied
                            ? const Color(0xFF16A34A)
                            : AppTheme.navyAccent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _copied ? Icons.check : Icons.content_copy,
                            size: 12,
                            color: _copied
                                ? Colors.white
                                : AppTheme.navyAccent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _copied ? 'Copied!' : 'Copy',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: _copied
                                  ? Colors.white
                                  : AppTheme.navyAccent,
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

          // ── Device rows for this date ──────────────────────────────
          ...devicesOnDate.map((d) => _DeviceRow(
                record: d,
                completed: widget.completed || isProcessed,
                accentDotColor: dotColor,
                customerGroup: widget.group,
              )),
        ],
      ),
    );
  }
}

// ── Copy Invoice Lines Button ─────────────────────────────────────────────────

class _CopyInvoiceLinesButton extends StatefulWidget {
  final CustomerGroup group;
  final bool completed;
  final Color completedBar;
  final Set<DateTime> skipDates;

  const _CopyInvoiceLinesButton({
    required this.group,
    required this.completed,
    required this.completedBar,
    this.skipDates = const {},
  });

  @override
  State<_CopyInvoiceLinesButton> createState() =>
      _CopyInvoiceLinesButtonState();
}

class _CopyInvoiceLinesButtonState extends State<_CopyInvoiceLinesButton> {
  bool _copied = false;

  /// Build invoice lines, optionally skipping already-processed dates.
  String _buildLines({bool skipProcessed = false}) {
    final sortedDates = widget.group.sortedBillingDates;
    final buffer = StringBuffer();
    int written = 0;
    for (final date in sortedDates) {
      if (skipProcessed && widget.skipDates.contains(date)) continue;
      final line = widget.group.buildInvoiceLineForDate(date);
      if (line.isEmpty) continue;
      if (written > 0) buffer.write('\n\n');
      buffer.write(line);
      written++;
    }
    return buffer.toString().trimRight();
  }

  Future<void> _copyLines(BuildContext context) async {
    // Skip already-processed dates when copying
    final lines = _buildLines(skipProcessed: widget.skipDates.isNotEmpty);
    if (lines.isEmpty) {
      // Try without skip filter
      final allLines = _buildLines(skipProcessed: false);
      if (allLines.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No billable devices with billing dates found.'),
            backgroundColor: Color(0xFFB45309),
          ),
        );
        return;
      }
    }

    final toCopy = lines.isEmpty ? _buildLines(skipProcessed: false) : lines;
    await Clipboard.setData(ClipboardData(text: toCopy));
    setState(() => _copied = true);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invoice lines for ${widget.group.customerName} copied!'),
          backgroundColor: AppTheme.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    await Future.delayed(const Duration(seconds: 3));
    if (mounted) setState(() => _copied = false);
  }

  void _previewLines(BuildContext context) {
    final lines = _buildLines(skipProcessed: false);
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No billable devices with billing dates found.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.receipt_long, size: 20, color: AppTheme.teal),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.group.customerName,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Invoice lines to paste into QuickBooks:',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: SelectableText(
                  lines,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.6,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: lines));
              if (ctx.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied invoice lines for ${widget.group.customerName}'),
                    backgroundColor: AppTheme.teal,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy All'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.teal,
              side: const BorderSide(color: AppTheme.teal),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.completed
        ? widget.completedBar
        : AppTheme.navyAccent;

    return Row(
      children: [
        // Preview button (eye icon)
        Tooltip(
          message: 'Preview invoice lines',
          child: OutlinedButton.icon(
            onPressed: () => _previewLines(context),
            icon: const Icon(Icons.visibility_outlined, size: 14),
            label: const Text('Preview', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textSecondary,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: Size.zero,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Copy button
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () => _copyLines(context),
            icon: Icon(
              _copied ? Icons.check : Icons.content_copy,
              size: 14,
            ),
            label: Text(
              _copied ? 'Copied!' : 'Copy All Invoice Lines',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _copied
                  ? const Color(0xFF16A34A)
                  : accentColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Device row (stateful – has per-plan copy button) ─────────────────────────

class _DeviceRow extends StatefulWidget {
  final ActivationRecord record;
  final bool completed;
  final Color? accentDotColor;
  final CustomerGroup? customerGroup;

  const _DeviceRow({
    required this.record,
    required this.completed,
    this.accentDotColor,
    this.customerGroup,
  });

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool _planCopied = false;
  bool _serialCopied = false;

  /// Show the manual price override dialog.
  ///
  /// Siblings (same customer, same rate plan) are classified into four buckets:
  ///   • clean     – same price, no flags, no existing override → included by default
  ///   • outlier   – different resolvedCustomerPrice → excluded by default, shown with warning
  ///   • flagged   – missingCodeFlag or missingRpcFlag → excluded by default, shown with warning
  ///   • overridden – already has a manual override → excluded by default, shown with warning
  Future<void> _showPriceEditDialog(BuildContext context) async {
    final record = widget.record;
    final provider = context.read<AppProvider>();
    final existing = provider.devicePriceOverrides[record.serialNumber];
    final planText = record.ratePlan.isEmpty ? record.planMode : record.ratePlan;
    final basePrice = record.resolvedCustomerPrice;

    // ── Classify siblings ──────────────────────────────────────────────────
    final CustomerGroup? group = widget.customerGroup;

    // Each entry: { 'record': ActivationRecord, 'bucket': 'clean'|'outlier'|'flagged'|'overridden' }
    final siblings = <Map<String, dynamic>>[];

    if (group != null) {
      for (final d in group.devices) {
        if (d.serialNumber == record.serialNumber) continue;
        final dPlan = (d.ratePlan.isEmpty ? d.planMode : d.ratePlan).trim().toLowerCase();
        if (dPlan != planText.trim().toLowerCase()) continue;

        String bucket;
        if (provider.devicePriceOverrides.containsKey(d.serialNumber)) {
          bucket = 'overridden';
        } else if (d.missingCodeFlag || d.missingRpcFlag) {
          bucket = 'flagged';
        } else if (d.resolvedCustomerPrice != basePrice) {
          bucket = 'outlier';
        } else {
          bucket = 'clean';
        }
        siblings.add({'record': d, 'bucket': bucket, 'included': bucket == 'clean'});
      }
    }

    final costCtrl = TextEditingController(
      text: existing != null && existing.yourCost > 0
          ? existing.yourCost.toStringAsFixed(2)
          : record.monthlyCost.toStringAsFixed(2),
    );
    final priceCtrl = TextEditingController(
      text: existing != null && existing.customerPrice > 0
          ? existing.customerPrice.toStringAsFixed(2)
          : record.resolvedCustomerPrice.toStringAsFixed(2),
    );

    final hasExisting = existing != null;
    final hasSiblings = siblings.isNotEmpty;
    final cleanCount = siblings.where((s) => s['bucket'] == 'clean').length;
    final outlierCount = siblings.where((s) => s['bucket'] == 'outlier').length;
    final flaggedCount = siblings.where((s) => s['bucket'] == 'flagged').length;
    final overriddenCount = siblings.where((s) => s['bucket'] == 'overridden').length;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final includedCount = siblings.where((s) => s['included'] == true).length;

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.edit, size: 18, color: AppTheme.navyAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Override Price: ${record.serialNumber}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Plan / auto-price summary ──────────────────────
                    Text(
                      'Rate Plan: $planText',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Auto-priced: cost \$${record.monthlyCost.toStringAsFixed(2)}  ·  customer \$${record.resolvedCustomerPrice.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 16),

                    // ── Cost / price fields ────────────────────────────
                    TextField(
                      controller: costCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Your Cost (Geotab → you)',
                        helperText: 'Monthly cost Geotab charges you',
                        isDense: true,
                        prefixText: '\$ ',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Customer Price (you → customer)',
                        helperText: 'Monthly price you charge the customer',
                        isDense: true,
                        prefixText: '\$ ',
                      ),
                    ),

                    // ── Sibling section ────────────────────────────────
                    if (hasSiblings) ...[
                      const SizedBox(height: 18),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Text(
                        'Other devices on this plan',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.navyAccent.withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 6),

                      // ── Clean siblings ─────────────────────────────
                      if (cleanCount > 0) ...[
                        _siblingHeader(
                          icon: Icons.check_circle_outline,
                          color: AppTheme.teal,
                          label: '$cleanCount matching device${cleanCount == 1 ? '' : 's'} — same price, no issues',
                          trailing: TextButton(
                            onPressed: () => setS(() {
                              for (final s in siblings) {
                                if (s['bucket'] == 'clean') s['included'] = true;
                              }
                            }),
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(40, 24),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: AppTheme.teal),
                            child: const Text('All', style: TextStyle(fontSize: 10)),
                          ),
                        ),
                        ...siblings.where((s) => s['bucket'] == 'clean').map((s) =>
                          _siblingRow(
                            s['record'] as ActivationRecord,
                            s['included'] as bool,
                            onChanged: (v) => setS(() => s['included'] = v),
                            subtext: '\$${(s['record'] as ActivationRecord).resolvedCustomerPrice.toStringAsFixed(2)} / mo',
                            checkColor: AppTheme.teal,
                          ),
                        ),
                      ],

                      // ── Outlier siblings ───────────────────────────
                      if (outlierCount > 0) ...[
                        const SizedBox(height: 8),
                        _siblingHeader(
                          icon: Icons.warning_amber_rounded,
                          color: const Color(0xFFD97706),
                          label: '$outlierCount device${outlierCount == 1 ? '' : 's'} with a different price — excluded by default',
                        ),
                        ...siblings.where((s) => s['bucket'] == 'outlier').map((s) {
                          final d = s['record'] as ActivationRecord;
                          return _siblingRow(
                            d,
                            s['included'] as bool,
                            onChanged: (v) => setS(() => s['included'] = v),
                            subtext: 'currently \$${d.resolvedCustomerPrice.toStringAsFixed(2)} / mo  ≠  \$${basePrice.toStringAsFixed(2)}',
                            subColor: const Color(0xFFD97706),
                            checkColor: const Color(0xFFD97706),
                          );
                        }),
                      ],

                      // ── Flagged siblings ───────────────────────────
                      if (flaggedCount > 0) ...[
                        const SizedBox(height: 8),
                        _siblingHeader(
                          icon: Icons.error_outline,
                          color: AppTheme.red,
                          label: '$flaggedCount device${flaggedCount == 1 ? '' : 's'} with pricing warnings — excluded by default',
                        ),
                        ...siblings.where((s) => s['bucket'] == 'flagged').map((s) {
                          final d = s['record'] as ActivationRecord;
                          final reason = d.missingCodeFlag ? 'missing plan code' : 'missing RPC';
                          return _siblingRow(
                            d,
                            s['included'] as bool,
                            onChanged: (v) => setS(() => s['included'] = v),
                            subtext: reason,
                            subColor: AppTheme.red,
                            checkColor: AppTheme.red,
                          );
                        }),
                      ],

                      // ── Already-overridden siblings ────────────────
                      if (overriddenCount > 0) ...[
                        const SizedBox(height: 8),
                        _siblingHeader(
                          icon: Icons.lock_outline,
                          color: AppTheme.textSecondary,
                          label: '$overriddenCount device${overriddenCount == 1 ? '' : 's'} already have a manual override — excluded by default',
                        ),
                        ...siblings.where((s) => s['bucket'] == 'overridden').map((s) {
                          final d = s['record'] as ActivationRecord;
                          final ov = provider.devicePriceOverrides[d.serialNumber];
                          final ovStr = ov != null ? '\$${ov.customerPrice.toStringAsFixed(2)}' : '?';
                          return _siblingRow(
                            d,
                            s['included'] as bool,
                            onChanged: (v) => setS(() => s['included'] = v),
                            subtext: 'override: $ovStr / mo',
                            subColor: AppTheme.textSecondary,
                            checkColor: AppTheme.textSecondary,
                          );
                        }),
                      ],

                      // ── Summary ────────────────────────────────────
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: includedCount > 0
                              ? AppTheme.navyAccent.withValues(alpha: 0.07)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: includedCount > 0
                                ? AppTheme.navyAccent.withValues(alpha: 0.25)
                                : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              includedCount > 0
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 13,
                              color: includedCount > 0
                                  ? AppTheme.navyAccent
                                  : AppTheme.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                includedCount == 0
                                    ? 'Override will apply to this device only'
                                    : 'Override will apply to this device + $includedCount other${includedCount == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: includedCount > 0
                                      ? AppTheme.navyAccent
                                      : AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── Active override notice ─────────────────────────
                    if (hasExisting) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline, size: 13, color: Color(0xFFB45309)),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Manual override active — tap Clear Override to restore auto-pricing',
                                style: TextStyle(fontSize: 10, color: Color(0xFFB45309)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (hasExisting)
                TextButton.icon(
                  onPressed: () async {
                    await provider.clearDevicePriceOverride(record.serialNumber);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Override cleared for ${record.serialNumber}'),
                          backgroundColor: AppTheme.teal,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.undo, size: 14),
                  label: const Text('Clear Override'),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.red),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final cost = double.tryParse(
                      costCtrl.text.replaceAll('\$', '').trim()) ?? 0.0;
                  final price = double.tryParse(
                      priceCtrl.text.replaceAll('\$', '').trim()) ?? 0.0;
                  if (cost <= 0 && price <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Enter at least one value > 0')),
                    );
                    return;
                  }
                  final includedSerials = siblings
                      .where((s) => s['included'] == true)
                      .map((s) => (s['record'] as ActivationRecord).serialNumber)
                      .toList();
                  final count = await provider.setDevicePriceOverride(
                    record.serialNumber,
                    cost,
                    price,
                    extraSerials: includedSerials,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    final msg = count > 1
                        ? 'Override applied to $count devices on $planText'
                        : 'Price override saved for ${record.serialNumber}';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(msg),
                        backgroundColor: AppTheme.navyAccent,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.navyAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save Override'),
              ),
            ],
          );
        },
      ),
    );

    costCtrl.dispose();
    priceCtrl.dispose();
  }

  /// A small labelled section header for sibling groups.
  Widget _siblingHeader({
    required IconData icon,
    required Color color,
    required String label,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  /// A single sibling device row with a checkbox.
  Widget _siblingRow(
    ActivationRecord d,
    bool included, {
    required ValueChanged<bool> onChanged,
    required String subtext,
    Color? subColor,
    required Color checkColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: included,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: checkColor,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.serialNumber,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtext,
                  style: TextStyle(
                    fontSize: 10,
                    color: subColor ?? AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyRatePlan(BuildContext context) async {
    final planText = widget.record.ratePlan.isEmpty
        ? widget.record.planMode
        : widget.record.ratePlan;
    if (planText.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: planText));
    setState(() => _planCopied = true);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rate plan copied: "$planText"'),
          backgroundColor: AppTheme.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    await Future.delayed(const Duration(seconds: 3));
    if (mounted) setState(() => _planCopied = false);
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final completed = widget.completed;

    final daysInMonth = record.billingStart != null
        ? DateTime(record.billingStart!.year, record.billingStart!.month + 1, 0).day
        : 0;
    final daysRemaining = record.billingStart != null
        ? daysInMonth - record.billingStart!.day + 1
        : 0;

    final dotColor = widget.accentDotColor ??
        (completed ? const Color(0xFF16A34A) : AppTheme.teal);
    final costColor = completed ? const Color(0xFF16A34A) : AppTheme.green;

    final planText = record.ratePlan.isEmpty ? record.planMode : record.ratePlan;

    return Column(
      children: [
        Divider(
          height: 1,
          indent: 20,
          color: completed
              ? const Color(0xFF16A34A).withValues(alpha: 0.15)
              : AppTheme.divider,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Serial + plan
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6, top: 3),
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            record.serialNumber,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // ── Copy serial number button ────────────────
                        Tooltip(
                          message: 'Copy serial number',
                          child: InkWell(
                            onTap: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: record.serialNumber));
                              setState(() => _serialCopied = true);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Serial copied: "${record.serialNumber}"'),
                                    backgroundColor: AppTheme.teal,
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                              await Future.delayed(
                                  const Duration(seconds: 3));
                              if (mounted) {
                                setState(() => _serialCopied = false);
                              }
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: _serialCopied
                                    ? const Color(0xFF16A34A)
                                    : AppTheme.navyAccent
                                        .withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _serialCopied
                                      ? const Color(0xFF16A34A)
                                      : AppTheme.navyAccent
                                          .withValues(alpha: 0.20),
                                  width: 0.8,
                                ),
                              ),
                              child: Icon(
                                _serialCopied
                                    ? Icons.check
                                    : Icons.content_copy,
                                size: 10,
                                color: _serialCopied
                                    ? Colors.white
                                    : AppTheme.navyAccent,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Rate plan row with inline copy button
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              planText,
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppTheme.textSecondary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (planText.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Tooltip(
                              message: 'Copy rate plan name',
                              child: InkWell(
                                onTap: () => _copyRatePlan(context),
                                borderRadius: BorderRadius.circular(4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _planCopied
                                        ? const Color(0xFF16A34A)
                                        : AppTheme.navyAccent.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _planCopied
                                          ? const Color(0xFF16A34A)
                                          : AppTheme.navyAccent.withValues(alpha: 0.20),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Icon(
                                    _planCopied
                                        ? Icons.check
                                        : Icons.content_copy,
                                    size: 10,
                                    color: _planCopied
                                        ? Colors.white
                                        : AppTheme.navyAccent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Missing-code flag warning
                    // Only show when pricing genuinely has no rule match (not suppressed by standard rate)
              if (record.missingCodeFlag && !record.priceMatchedRule.startsWith('Standard plan') && !record.priceMatchedRule.startsWith('Manual'))
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.warning, size: 11, color: Color(0xFFB45309)),
                      const SizedBox(width: 4),
                      Text(
                        'No matching plan code',
                        style: TextStyle(
                          fontSize: 10,
                          color: const Color(0xFFB45309).withValues(alpha: 0.9),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                    // Manual override indicator
              if (record.priceMatchedRule == 'Manual override')
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.edit, size: 10, color: AppTheme.navyAccent),
                      const SizedBox(width: 3),
                      Text(
                        'Manual override',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.navyAccent.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              if (daysRemaining > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Text(
                          '$daysRemaining/$daysInMonth days',
                          style: TextStyle(
                            fontSize: 10,
                            color: dotColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Billing start
              SizedBox(
                width: 90,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    Formatters.date(record.billingStart),
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              // Monthly cost + manual override button
              SizedBox(
                width: 72,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Tooltip(
                    message: 'Pricing rule: ${record.priceMatchedRule}',
                    preferBelow: false,
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Price edit icon
                          Tooltip(
                            message: record.priceMatchedRule == 'Manual override'
                                ? 'Edit manual price override'
                                : 'Set manual price override',
                            child: InkWell(
                              onTap: () => _showPriceEditDialog(context),
                              borderRadius: BorderRadius.circular(3),
                              child: Padding(
                                padding: const EdgeInsets.only(right: 3),
                                child: Icon(
                                  record.priceMatchedRule == 'Manual override'
                                      ? Icons.edit
                                      : Icons.edit_outlined,
                                  size: 11,
                                  color: record.priceMatchedRule == 'Manual override'
                                      ? AppTheme.navyAccent
                                      : AppTheme.textSecondary.withValues(alpha: 0.45),
                                ),
                              ),
                            ),
                          ),
                          Text(
                            Formatters.currency(record.resolvedCustomerPrice),
                            style: TextStyle(
                                fontSize: 12,
                                color: record.resolvedCustomerPrice != record.monthlyCost
                                    ? AppTheme.teal
                                    : AppTheme.textSecondary,
                                fontWeight: record.resolvedCustomerPrice != record.monthlyCost
                                    ? FontWeight.w700
                                    : FontWeight.normal),
                            textAlign: TextAlign.right,
                          ),
                        ],
                      ),
                      if (record.resolvedCustomerPrice != record.monthlyCost)
                        Text(
                          'cost: ${Formatters.currency(record.monthlyCost)}',
                          style: const TextStyle(
                              fontSize: 9, color: AppTheme.textSecondary),
                          textAlign: TextAlign.right,
                        ),
                    ],
                  ),
                  ),
                ),
              ),
              // Prorated cost (using customer billing price)
              SizedBox(
                width: 80,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    Formatters.currency(record.customerProratedCost),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: costColor,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
