// Customer card widget — always expanded, with completed checkbox

import 'package:flutter/material.dart';
import '../models/customer_group.dart';
import '../models/activation_record.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

class CustomerCard extends StatefulWidget {
  final CustomerGroup group;

  const CustomerCard({
    super.key,
    required this.group,
  });

  @override
  State<CustomerCard> createState() => _CustomerCardState();
}

class _CustomerCardState extends State<CustomerCard> {
  bool _completed = false;

  static const _completedBg   = Color(0xFFECFDF5); // very light green bg
  static const _completedBar  = Color(0xFF16A34A); // solid green accent bar
  static const _completedCard = Color(0xFFDCFCE7); // slightly deeper green for subtotal

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final accent = _completed ? _completedBar : AppTheme.navyAccent;

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
                      onChanged: (v) => setState(() => _completed = v ?? false),
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
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _badge(
                            '${g.deviceCount} device${g.deviceCount == 1 ? '' : 's'}',
                            _completed ? _completedBar : AppTheme.teal,
                          ),
                          const SizedBox(width: 8),
                          if (g.earliestBillingStart != null) ...[
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

                // Right: prorated total
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
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

          // ── Device rows ───────────────────────────────────────────
          ...g.devices.map((d) => _DeviceRow(
                record: d,
                completed: _completed,
              )),

          // ── Subtotal footer ───────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              color: _completed ? _completedCard : const Color(0xFFF8FAFC),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
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

// ── Device row (standalone stateless widget) ─────────────────────────────────

class _DeviceRow extends StatelessWidget {
  final ActivationRecord record;
  final bool completed;

  const _DeviceRow({required this.record, required this.completed});

  @override
  Widget build(BuildContext context) {
    final daysInMonth = record.billingStart != null
        ? DateTime(record.billingStart!.year, record.billingStart!.month + 1, 0).day
        : 0;
    final daysRemaining = record.billingStart != null
        ? daysInMonth - record.billingStart!.day + 1
        : 0;

    final dotColor = completed ? const Color(0xFF16A34A) : AppTheme.teal;
    final costColor = completed ? const Color(0xFF16A34A) : AppTheme.green;

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
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        record.ratePlan.isEmpty ? record.planMode : record.ratePlan,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Missing-code flag warning
              if (record.missingCodeFlag)
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
              // Monthly cost (show customer price if different)
              SizedBox(
                width: 72,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
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
