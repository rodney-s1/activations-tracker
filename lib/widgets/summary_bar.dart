// Reusable summary stat chip widget — collapsible

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_theme.dart';

class SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const SummaryChip({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 15),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SummaryBar extends StatefulWidget {
  final List<SummaryChip> chips;

  const SummaryBar({super.key, required this.chips});

  @override
  State<SummaryBar> createState() => _SummaryBarState();
}

class _SummaryBarState extends State<SummaryBar> {
  static const _prefKey = 'summary_bar_expanded';
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _expanded = prefs.getBool(_prefKey) ?? false);
      }
    });
  }

  void _toggle() {
    final next = !_expanded;
    setState(() => _expanded = next);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool(_prefKey, next));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        color: AppTheme.navyMid,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Chips row (collapsible) ─────────────────────────────
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: _expanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              firstChild: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: widget.chips
                        .expand((c) => [c, const SizedBox(width: 8)])
                        .toList()
                      ..removeLast(),
                  ),
                ),
              ),
              secondChild: const SizedBox(width: double.infinity, height: 0),
            ),

            // ── Collapse / expand handle ────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.navyDark.withValues(alpha: 0.25),
              ),
              child: Center(
                child: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14,
                  color: Colors.white54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
