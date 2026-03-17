// Utility formatting helpers

import 'package:intl/intl.dart';
import 'package:flutter/material.dart';

class Formatters {
  static final _currency = NumberFormat('\$#,##0.00', 'en_US');
  static final _currencyLong = NumberFormat('\$#,##0.00000', 'en_US');
  static final _date = DateFormat('MMM d, yyyy');
  static final _dateTime = DateFormat('MMM d, yyyy h:mm a');
  static final _dateShort = DateFormat('M/d/yy');

  static String currency(double v) => _currency.format(v);
  static String currencyLong(double v) => _currencyLong.format(v);
  static String date(DateTime? d) => d == null ? 'N/A' : _date.format(d);
  static String dateTime(DateTime? d) =>
      d == null ? 'N/A' : _dateTime.format(d);
  static String dateShort(DateTime? d) =>
      d == null ? 'N/A' : _dateShort.format(d);

  /// Returns color for a cost amount
  static Color costColor(double v) {
    if (v <= 0) return Colors.grey;
    return const Color(0xFF16A34A);
  }
}
