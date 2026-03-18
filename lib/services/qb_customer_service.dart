// Service for QB Customer list (Hive typeId=5)
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/qb_customer.dart';

class QbCustomerService {
  static const _boxName = 'qb_customers';
  static Box<QbCustomer>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(5)) {
      Hive.registerAdapter(QbCustomerAdapter());
    }
    _box = await Hive.openBox<QbCustomer>(_boxName);
  }

  static Box<QbCustomer> get box => _box!;

  static List<QbCustomer> getAll() {
    final list = _box!.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  static List<String> getAllNames() => getAll().map((c) => c.name).toList();

  /// Import from a QuickBooks Customer List CSV.
  /// Accepts the raw bytes directly (preferred — avoids web encoding issues)
  /// or a pre-decoded string.
  static Future<int> importFromBytes(List<int> bytes) async {
    // Decode bytes properly: try UTF-8 first, fall back to Latin-1.
    // This avoids the String.fromCharCodes() corruption on web.
    String content;
    try {
      content = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      content = latin1.decode(bytes);
    }
    // Strip BOM if present
    if (content.startsWith('\uFEFF')) content = content.substring(1);
    return importFromCsv(content);
  }

  static Future<int> importFromCsv(String content) async {
    // Strip BOM if present
    if (content.startsWith('\uFEFF')) content = content.substring(1);

    await _box!.clear();
    int count = 0;

    // Normalise line endings
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    // QB CSV columns (0-indexed, first col is blank):
    // 0=blank  1=Active Status  2=Customer  3=Balance  4=Balance Total
    // 5=Company  6=Mr/Ms  7=First  8=MI  9=Last  10=Primary Contact
    // 11=Main Phone  12=Fax  13=Alt Phone  14=Secondary Contact
    // 15=Job Title  16=Main Email  17-21=Bill to 1-5  22-26=Ship to 1-5
    // 27=Customer Type  28=Terms  29=Rep  30=Sales Tax Code  31=Tax Item
    // 32=Resale Num  33=Account No.  34=Credit Limit  35=Job Status ...

    // Find the header row (contains "Active Status" column)
    int dataStart = 0;
    for (int i = 0; i < lines.length && i < 5; i++) {
      if (lines[i].contains('Active Status')) {
        dataStart = i + 1; // data starts on the line after the header
        break;
      }
    }
    // If header not found in first 5 lines, assume line 0 is header
    if (dataStart == 0) dataStart = 1;

    if (kDebugMode) {
      debugPrint('[QbCustomerService] dataStart=$dataStart, total lines=${lines.length}');
    }

    for (int i = dataStart; i < lines.length; i++) {
      final raw = lines[i].trim();
      if (raw.isEmpty) continue;

      final cols = _splitCsv(raw);
      if (cols.length < 3) continue;

      String get(int idx) => idx < cols.length ? cols[idx].trim() : '';

      final status = get(1).toLowerCase();
      if (status != 'active') continue;

      final name = get(2);
      if (name.isEmpty || name.startsWith('**')) continue;

      final phone = get(11).isNotEmpty ? get(11) : get(13);
      final email = get(16);
      final addr  = [get(17), get(18), get(19)]
          .where((s) => s.isNotEmpty)
          .join(', ');
      final acct  = get(33);

      await _box!.add(QbCustomer(
        name:      name,
        accountNo: acct,
        email:     email,
        phone:     phone,
        address:   addr,
      ));
      count++;
    }

    if (kDebugMode) debugPrint('[QbCustomerService] Imported $count customers');
    return count;
  }

  static List<String> _splitCsv(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQ = false;
    for (final ch in line.split('')) {
      if (ch == '"') {
        inQ = !inQ;
      } else if (ch == ',' && !inQ) {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString());
    return result;
  }

  /// Toggle the CUA flag for the customer at the given box index.
  static Future<void> toggleCua(int boxIndex) async {
    final key = _box!.keyAt(boxIndex);
    final customer = _box!.get(key);
    if (customer == null) return;
    customer.isCua = !customer.isCua;
    await customer.save();
  }

  /// Set CUA flag by customer name (used for cloud sync restore).
  static Future<void> setCuaByName(String name, bool isCua) async {
    for (final c in _box!.values) {
      if (c.name == name) {
        c.isCua = isCua;
        await c.save();
        return;
      }
    }
  }

  /// Return a map of customerName → isCua for all customers.
  static Map<String, bool> getCuaMap() {
    return {for (final c in _box!.values) c.name: c.isCua};
  }

  static Future<void> clear() => _box!.clear();
}
