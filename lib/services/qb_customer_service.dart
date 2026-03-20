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

    // ── Preserve parent-account assignments across re-imports ─────────────────
    // importFromCsv clears the box, which would destroy any parentAccountName
    // values the user set via the UI.  Snapshot them first (keyed by normalised
    // name) and re-apply them after the new records have been written.
    final savedParents = <String, String>{};
    for (final c in _box!.values) {
      if (c.parentAccountName.trim().isNotEmpty) {
        savedParents[_normalizeName(c.name)] = c.parentAccountName;
        // Also save under the short name (after colon) so both QB and MyAdmin
        // variant names are covered after the re-import.
        final colonIdx = c.name.lastIndexOf(':');
        if (colonIdx >= 0 && colonIdx < c.name.length - 1) {
          final shortName = c.name.substring(colonIdx + 1).trim();
          savedParents[_normalizeName(shortName)] = c.parentAccountName;
        }
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

    await _box!.clear();
    int count = 0;

    // Normalise line endings
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    // QB CSV columns (0-indexed, first col is blank):
    //  0=blank  1=Active Status  2=Customer  3=Balance  4=Balance Total
    //  5=Company  6=Mr/Ms  7=First  8=MI  9=Last  10=Primary Contact
    // 11=Main Phone  12=Fax  13=Alt Phone  14=Secondary Contact
    // 15=Job Title  16=Main Email  17-21=Bill to 1-5  22-26=Ship to 1-5
    // 27=Customer Type  28=Terms  29=Rep  30=Sales Tax Code  31=Tax Item
    // 32=Resale Num  33=Account No.  34=Credit Limit  35=Job Status
    // 36=Job Type (AK) ← CUA / Standard determination
    // 37=Job Description  38=Start Date  39=Projected End  40=End Date

    // Find the header row (contains "Active Status" column) and resolve
    // column indices dynamically so we're not hard-coded to a column order.
    int dataStart = 0;
    int activeStatusIdx = 1;
    int customerIdx     = 2;
    int phoneIdx        = 11;
    int altPhoneIdx     = 13;
    int emailIdx        = 16;
    int billTo1Idx      = 17;
    int billTo2Idx      = 18;
    int billTo3Idx      = 19;
    int accountNoIdx    = 33;
    int jobTypeIdx      = 36; // Column AK

    for (int i = 0; i < lines.length && i < 5; i++) {
      if (lines[i].contains('Active Status')) {
        dataStart = i + 1;
        // Resolve indices from header row
        final hdr = _splitCsv(lines[i]);
        for (int j = 0; j < hdr.length; j++) {
          final h = hdr[j].trim().toLowerCase();
          if (h == 'active status')           activeStatusIdx = j;
          else if (h == 'customer')            customerIdx     = j;
          else if (h == 'main phone')          phoneIdx        = j;
          else if (h == 'alt. phone')          altPhoneIdx     = j;
          else if (h == 'main email')          emailIdx        = j;
          else if (h == 'bill to 1')           billTo1Idx      = j;
          else if (h == 'bill to 2')           billTo2Idx      = j;
          else if (h == 'bill to 3')           billTo3Idx      = j;
          else if (h == 'account no.')         accountNoIdx    = j;
          else if (h == 'job type')            jobTypeIdx      = j;
        }
        break;
      }
    }
    if (dataStart == 0) dataStart = 1;

    if (kDebugMode) {
      debugPrint('[QbCustomerService] dataStart=$dataStart, '
          'jobTypeIdx=$jobTypeIdx, total lines=${lines.length}');
    }

    for (int i = dataStart; i < lines.length; i++) {
      final raw = lines[i].trim();
      if (raw.isEmpty) continue;

      final cols = _splitCsv(raw);
      if (cols.length < 3) continue;

      String get(int idx) => idx < cols.length ? cols[idx].trim() : '';

      final status = get(activeStatusIdx).toLowerCase();
      if (status != 'active') continue;

      final name = get(customerIdx);
      if (name.isEmpty || name.startsWith('**')) continue;

      final phone   = get(phoneIdx).isNotEmpty ? get(phoneIdx) : get(altPhoneIdx);
      final email   = get(emailIdx);
      final addr    = [get(billTo1Idx), get(billTo2Idx), get(billTo3Idx)]
          .where((s) => s.isNotEmpty)
          .join(', ');
      final acct    = get(accountNoIdx);
      final jobType = get(jobTypeIdx);

      // Auto-detect CUA from Column AK (Job Type):
      //   "Charge Upon Activation" (and any variant like "Charge Upon Activation:Hanover")
      //   → isCua = true
      //   Everything else (Standard, blank, Reseller, etc.) → isCua = false
      final isCua = jobType.toLowerCase().contains('charge upon activation');

      await _box!.add(QbCustomer(
        name:      name,
        accountNo: acct,
        email:     email,
        phone:     phone,
        address:   addr,
        isCua:     isCua,
        jobType:   jobType,
      ));
      count++;
    }

    // ── Restore preserved parent assignments ──────────────────────────────────
    if (savedParents.isNotEmpty) {
      for (final c in _box!.values) {
        // Try to match the freshly-imported record against the snapshot.
        // We check both the full name and the short name (after colon).
        String? restoredParent = savedParents[_normalizeName(c.name)];
        if (restoredParent == null) {
          final colonIdx = c.name.lastIndexOf(':');
          if (colonIdx >= 0 && colonIdx < c.name.length - 1) {
            final shortName = c.name.substring(colonIdx + 1).trim();
            restoredParent = savedParents[_normalizeName(shortName)];
          }
        }
        if (restoredParent != null && restoredParent.trim().isNotEmpty) {
          c.parentAccountName = restoredParent;
          await c.save();
        }
      }
      if (kDebugMode) {
        debugPrint('[QbCustomerService] Restored ${savedParents.length} '
            'parent-account assignment(s) after re-import');
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

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
  /// Note: manual toggle overrides the auto-imported value from Column AK.
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

  /// Return a map of customerName → isCua keyed by NORMALISED name (lowercase, no paren suffix).
  /// This allows fuzzy matching when MyAdmin customer names differ slightly from QB names.
  static Map<String, bool> getCuaMapNormalized() {
    final result = <String, bool>{};
    for (final c in _box!.values) {
      // exact name
      result[c.name] = c.isCua;
      // normalised: lowercase, strip trailing parenthetical suffix, collapse whitespace
      final norm = _normalizeName(c.name);
      result[norm] = c.isCua;
    }
    return result;
  }

  /// Return a map of customerName → jobType keyed by NORMALISED name.
  static Map<String, String> getJobTypeMapNormalized() {
    final result = <String, String>{};
    for (final c in _box!.values) {
      result[c.name] = c.jobType;
      final norm = _normalizeName(c.name);
      result[norm] = c.jobType;
    }
    return result;
  }

  /// Normalise a customer name for fuzzy matching:
  /// lowercase, strip trailing parenthetical suffix, collapse whitespace.
  static String _normalizeName(String name) {
    String s = name;
    final parenIdx = s.indexOf('(');
    if (parenIdx > 0) s = s.substring(0, parenIdx);
    final curlyIdx = s.indexOf('{');
    if (curlyIdx > 0) s = s.substring(0, curlyIdx);
    return s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static Future<void> clear() => _box!.clear();

  // ── Parent account assignment ───────────────────────────────────────────────

  /// Set [childName]'s parent to [parentName].
  /// Pass an empty string for [parentName] to clear the relationship.
  static Future<void> setParent(String childName, String parentName) async {
    for (final c in _box!.values) {
      if (c.name == childName) {
        c.parentAccountName = parentName;
        await c.save();
        return;
      }
    }
  }

  /// Remove the parent assignment from [childName] (makes it a top-level account).
  static Future<void> clearParent(String childName) => setParent(childName, '');

  /// Return a map of  normKey(childName) → normKey(parentName)
  /// for every customer that has a parent set.
  /// Used by QB Verify to merge child device counts into the parent row.
  ///
  /// Three keys are registered per child so the lookup succeeds regardless of
  /// whether the summary customerName came from:
  ///   (a) the full QB name   e.g. "Firgos Trucking Insurance:Amanah Logistics LLC"
  ///   (b) the short QB name  e.g. "Amanah Logistics LLC"  (part after the last colon)
  ///   (c) the MyAdmin name   e.g. "Amanah Logistics"      (may differ slightly)
  ///
  /// QB often prefixes child account names with "ParentName:" — stripping that
  /// prefix gives the short name that MyAdmin and the verify-screen display name
  /// are likely to match.
  static Map<String, String> getParentMapNormalized() {
    final result = <String, String>{};
    for (final c in _box!.values) {
      if (c.parentAccountName.trim().isEmpty) continue;
      final parentNorm = _normalizeName(c.parentAccountName);

      // (a) full QB name
      result[_normalizeName(c.name)] = parentNorm;

      // (b) short name — everything after the LAST colon, if one exists
      final colonIdx = c.name.lastIndexOf(':');
      if (colonIdx >= 0 && colonIdx < c.name.length - 1) {
        final shortName = c.name.substring(colonIdx + 1).trim();
        result[_normalizeName(shortName)] = parentNorm;
      }
    }
    return result;
  }
}
