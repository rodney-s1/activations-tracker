// Service for QB Customer list (Hive typeId=5)
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

  static Future<int> importFromCsv(String content) async {
    // QB CSV columns (0-indexed after stripping leading comma):
    // 0=blank, 1=Active Status, 2=Customer, 3=Balance, 4=Balance Total,
    // 5=Company, 6=Mr/Ms, 7=First, 8=MI, 9=Last, 10=Primary Contact,
    // 11=Main Phone, 12=Fax, 13=Alt Phone, 14=Secondary Contact,
    // 15=Job Title, 16=Main Email, 17=Bill to 1 ... 21=Bill to 5
    // 32=Account No.
    await _box!.clear();
    int count = 0;

    final lines = content
        .split('\n')
        .map((l) => l.replaceAll('\r', ''))
        .toList();

    bool headerSkipped = false;

    for (final raw in lines) {
      if (raw.trim().isEmpty) continue;
      if (!headerSkipped) {
        // Skip the header row (contains "Active Status")
        if (raw.contains('Active Status') || raw.contains('Customer')) {
          headerSkipped = true;
          continue;
        }
      }

      final cols = _splitCsv(raw);
      if (cols.length < 3) continue;

      // Col indices (QB export starts with a blank col 0)
      String get(int i) => i < cols.length ? cols[i].trim() : '';

      final status = get(1).toLowerCase();
      if (status != 'active') continue; // skip inactive

      final name = get(2);
      if (name.isEmpty || name.startsWith('**')) continue; // skip internal/QB accounts

      final phone = get(11).isNotEmpty ? get(11) : get(13);
      final email = get(16);
      final addr  = [get(17), get(18), get(19)].where((s) => s.isNotEmpty).join(', ');
      final acct  = get(33);

      await _box!.add(QbCustomer(
        name: name,
        accountNo: acct,
        email: email,
        phone: phone,
        address: addr,
      ));
      count++;
    }
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

  static Future<void> clear() => _box!.clear();
}
