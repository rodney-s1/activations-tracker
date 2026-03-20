// QB Verify Screen
// Import a MyAdmin "Device Management - Full Report" CSV as the "Active" side
// and a QuickBooks "Sales by Customer Detail" CSV as the "Billed" side.
// Cross-references both to surface billing discrepancies before invoices are sent.

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js; // ignore: deprecated_member_use
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../services/cloud_sync_service.dart';
import '../services/csv_persist_service.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';

// ── Enums & Models ────────────────────────────────────────────────────────────

enum VerifyStatus { match, overbilled, underbilled, qbOnly, activeOnly }

/// A single device row parsed from the MyAdmin Full Report
class MyAdminDevice {
  final String serialNumber;
  final String customer;
  final String billingPlan;   // "Active billing plan" column
  final String ratePlanCode;  // "Rate Plan Code" column
  final String billingStatus; // "Billing status" column  (Active / Suspended / Never billed)
  final String account;

  /// True when this device belongs to a {Cameras} sub-group in MyAdmin.
  /// Camera devices have different billing rules from Geotab trackers:
  ///   • Standard customers: Active + Never Activated are billed (Suspended is NOT)
  ///   • CUA cameras: same as Standard UNLESS the customer is Hollywood Feed Corporate
  ///     (they are CUA for cameras too — Active only)
  final bool isCamera;

  const MyAdminDevice({
    required this.serialNumber,
    required this.customer,
    required this.billingPlan,
    required this.ratePlanCode,
    required this.billingStatus,
    required this.account,
    this.isCamera = false,
  });

  /// True when this device is on the Hanover Insurance rate plan.
  bool get isHanover => ratePlanCode.toLowerCase() == 'hanover';

  /// True for the most common billed statuses.
  bool get isBillable => billingStatus.toLowerCase() != 'unknown';

  /// Camera product sub-type, derived from serial number prefix (primary) or
  /// Active Billing Plan containing "GO Expand" (fallback for active devices).
  ///
  ///   Serial prefix GF  →  'Go Focus'
  ///   Serial prefix GE  →  'Go Focus Plus'
  ///   billingPlan contains "GO Expand" + GF prefix  →  'Go Focus'
  ///   billingPlan contains "GO Expand" + GE prefix  →  'Go Focus Plus'
  ///   billingPlan contains "GO Expand" (no clear prefix) → 'Go Focus'  (safe default)
  ///   Other camera  →  ''  (Surfsight, Smarter AI — no sub-type)
  ///
  /// Serial prefix is always checked first because Never Activated devices
  /// may have no billing plan at all.
  String get cameraType {
    if (!isCamera) return '';
    final sn = serialNumber.toUpperCase();
    if (sn.startsWith('GF')) return 'Go Focus';
    if (sn.startsWith('GE')) return 'Go Focus Plus';
    // Fallback: Active Billing Plan contains "GO Expand"
    final bp = billingPlan.toLowerCase();
    if (bp.contains('go expand')) return 'Go Focus'; // can't distinguish without GF/GE prefix
    return ''; // Surfsight, Smarter AI, etc.
  }

  /// Convenience: true when this is specifically a Go Focus camera.
  bool get isGoFocus => cameraType == 'Go Focus';

  /// Convenience: true when this is specifically a Go Focus Plus camera.
  bool get isGoFocusPlus => cameraType == 'Go Focus Plus';
}

/// A single line item from the QB Sales by Customer Detail CSV.
/// [qty] is the number of devices billed on this line (column R in the export).
/// [planLabel] is a short human-readable plan name extracted from [description].
class QbInvoiceLine {
  final String invoiceNumber;
  final String date;
  final String description;
  final double qty;        // column R — number of devices billed
  final double unitPrice;
  final double amount;
  final String planLabel;  // short plan name, e.g. "Pro", "GO", "HOS"

  const QbInvoiceLine({
    required this.invoiceNumber,
    required this.date,
    required this.description,
    required this.qty,
    required this.unitPrice,
    required this.amount,
    this.planLabel = '',
  });
}

/// Per-customer combined summary used for display.
/// [billedCount]   = sum of Qty across all QB invoice lines (not row count).
/// [activeCount]   = billable devices based on customer type:
///                   • Standard Geotab:  Active + Suspended + Never Activated (excl. Hanover-only)
///                   • CUA Geotab:       Active + Suspended (Never Activated excluded)
///                   • Standard Camera:  Active + Never Activated (Suspended NOT billed)
///                   • CUA Camera:       Active + Never Activated UNLESS Hollywood Feed → Active only
/// [unknownCount]  = devices with "Unknown" status (shown for review, not counted in billing diff).
/// [hanoverCount]  = devices whose ratePlanCode == 'hanover' with NO cost-share QB line.
///                   These are billed directly to Hanover Insurance, NOT to this customer.
/// [hanoverCsQty]  = QB HANOVER-CS (Cost Share) line quantity — customer pays half,
///                   Hanover Insurance pays half.  These devices ARE included in activeCount.
/// [cameraCount]     = total billable camera devices
/// [goFocusCount]    = billable Go Focus cameras  (serial prefix GF)
/// [goFocusPlusCount]= billable Go Focus Plus cameras (serial prefix GE)
/// [geotabCount]     = billable Geotab (non-camera) devices
class QbCustomerSummary {
  final String customerName;

  // QB (Billed) side
  final int billedCount;        // sum of Qty from QB — total devices invoiced
  final double totalBilled;
  final List<QbInvoiceLine> qbLines;

  // MyAdmin side
  final int activeCount;        // billable devices (see above — CUA + Hanover + Camera logic)
  final int unknownCount;       // Unknown-status devices (shown for review, excluded from diff)
  final int hanoverCount;       // Hanover-RPC devices excluded from billing (billed to Hanover direct)
  final int hanoverCsQty;       // HANOVER-CS QB lines qty (cost-share — customer pays half)
  final int cameraCount;        // total billable camera devices
  final int goFocusCount;       // billable Go Focus cameras (GF serial prefix)
  final int goFocusPlusCount;   // billable Go Focus Plus cameras (GE serial prefix)
  final int geotabCount;        // billable Geotab (non-camera) devices
  final List<MyAdminDevice> activeDevices; // ALL devices (billable + unknown + hanover)

  /// True = Charged Upon Activation.
  /// CUA customers only get billed for Active devices (not Suspended / Never Activated).
  final bool isCua;

  /// Raw jobType from Column AK of the QB Customer List (e.g. "Standard", "Charge Upon Activation:Hanover").
  /// Empty string if not found in QB Customer List.
  final String jobType;

  const QbCustomerSummary({
    required this.customerName,
    required this.billedCount,
    required this.totalBilled,
    required this.qbLines,
    required this.activeCount,
    this.unknownCount = 0,
    this.hanoverCount = 0,
    this.hanoverCsQty = 0,
    this.cameraCount = 0,
    this.goFocusCount = 0,
    this.goFocusPlusCount = 0,
    this.geotabCount = 0,
    required this.activeDevices,
    this.isCua = false,
    this.jobType = '',
  });

  /// Billing comparison uses only billable devices (Active/Suspended/Never Activated).
  /// Unknown devices are visible in the list but excluded from the diff calculation.
  VerifyStatus get status {
    if (billedCount == 0 && activeCount == 0) return VerifyStatus.match;
    if (billedCount > 0 && activeCount == 0) return VerifyStatus.qbOnly;
    if (billedCount == 0 && activeCount > 0) return VerifyStatus.activeOnly;
    if (billedCount > activeCount) return VerifyStatus.overbilled;
    if (billedCount < activeCount) return VerifyStatus.underbilled;
    return VerifyStatus.match;
  }

  int get diff => billedCount - activeCount; // positive = over, negative = under

  /// Group QB lines by plan label for the multi-plan display.
  Map<String, List<QbInvoiceLine>> get linesByPlan {
    final map = <String, List<QbInvoiceLine>>{};
    for (final line in qbLines) {
      final key = line.planLabel.isEmpty ? line.description : line.planLabel;
      map.putIfAbsent(key, () => []).add(line);
    }
    return map;
  }

  /// Total billed devices per plan — for the plan breakdown chips.
  Map<String, int> get billedPerPlan {
    final map = <String, int>{};
    for (final line in qbLines) {
      final key = line.planLabel.isEmpty ? line.description : line.planLabel;
      map[key] = (map[key] ?? 0) + line.qty.round();
    }
    return map;
  }
}

// ── Status badge helper ───────────────────────────────────────────────────────

/// Short label + colour for a MyAdmin billing status.
/// Active → no badge (normal).  All others get a coloured chip.
({String label, Color color})? statusBadge(String billingStatus) {
  switch (billingStatus.toLowerCase()) {
    case 'active':
      return null; // no badge needed
    case 'never activated':
    case 'never billed':
      return (label: 'N/A', color: AppTheme.amber);
    case 'suspended':
      return (label: 'SUSP', color: Colors.orange);
    case 'unknown':
      return (label: '???', color: Colors.grey);
    default:
      // Catch any other unexpected status
      return (label: billingStatus.toUpperCase().substring(0,
          billingStatus.length > 4 ? 4 : billingStatus.length), color: Colors.grey);
  }
}

// ── MyAdmin CSV Parser ────────────────────────────────────────────────────────

/// Parse a MyAdmin "Device Management - Full Report" CSV.
/// The file has a 2-line header (report name + date), a blank line, then
/// the column header row, then data rows.
/// Returns ALL devices regardless of billing status — Active, Never Activated,
/// Suspended, Unknown, etc. — so nothing is hidden from billing review.
/// Grouped by normalised customer name (strips parenthetical location suffixes
/// AND curly-brace device-type suffixes so sub-groups like "Customer {Cameras}"
/// and "Customer {OEM}" all merge under "Customer").
Map<String, List<MyAdminDevice>> parseMyAdminCsv(String content) {
  final lines = content.split(RegExp(r'\r?\n'));
  if (lines.length < 5) return {};

  // Find the header row — it contains "Serial number" and "Customer"
  int headerIdx = -1;
  List<String> headers = [];
  for (int i = 0; i < lines.length && i < 10; i++) {
    final cells = _splitCsv(lines[i]);
    final lower = cells.map((c) => c.toLowerCase().trim()).toList();
    if (lower.contains('serial number') && lower.contains('customer')) {
      headerIdx = i;
      headers = cells.map((c) => c.toLowerCase().trim()).toList();
      break;
    }
  }
  if (headerIdx < 0) return {};

  final serialIdx  = headers.indexOf('serial number');
  final custIdx    = headers.indexOf('customer');
  final planIdx    = headers.indexOf('active billing plan');
  final rpcIdx     = headers.indexOf('rate plan code');
  final statusIdx  = headers.indexOf('billing status');
  final accountIdx = headers.indexOf('account');

  if (serialIdx < 0 || custIdx < 0) return {};

  final Map<String, List<MyAdminDevice>> result = {};

  for (int i = headerIdx + 1; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty) continue;
    final cells = _splitCsv(raw);
    if (cells.length <= custIdx) continue;

    String g(int idx) =>
        (idx >= 0 && idx < cells.length) ? cells[idx].trim() : '';

    final serial  = g(serialIdx);
    final customer = g(custIdx);
    final status  = g(statusIdx);

    if (serial.isEmpty || customer.isEmpty) continue;
    // Include ALL statuses — Active, Suspended, Never Activated, Unknown, etc.
    // Nothing is filtered out; status badges in the UI distinguish each type.

    final normKey = _normKey(customer);
    // Detect camera sub-group: MyAdmin appends " {Cameras}" to the customer name
    // for camera devices (Surfsight, Go Focus, Smarter AI, etc.)
    final isCamera = customer.contains('{') &&
        customer.toLowerCase().contains('camera');
    result.putIfAbsent(normKey, () => []);
    result[normKey]!.add(MyAdminDevice(
      serialNumber: serial,
      customer: customer,
      billingPlan: g(planIdx),
      ratePlanCode: g(rpcIdx),
      billingStatus: status,
      account: g(accountIdx),
      isCamera: isCamera,
    ));
  }

  return result;
}

// ── QB Sales CSV Parser ───────────────────────────────────────────────────────

/// Return type carrying both the invoice-line map and a display-name cache.
class QbParseResult {
  final Map<String, List<QbInvoiceLine>> lines;
  /// normKey → original QB customer name (proper casing, no location suffix)
  final Map<String, String> displayNames;
  const QbParseResult({required this.lines, required this.displayNames});
}

/// Parse a QuickBooks "Sales by Customer Detail" CSV export.
///
/// The QB export uses interleaved blank columns — every data column has an
/// empty spacer beside it, so the actual column indices are:
///   F=5  Type  |  H=7  Date  |  J=9  Num  |  L=11 Memo  |  N=13 Name
///   P=15 Item  |  R=17 Qty   |  T=19 Sales Price  |  V=21 Amount
///
/// **[qty] (column R) is the number of devices billed on that line** — it is
/// NOT a row count.  billedCount = sum(qty) across all service lines.
///
/// Returns a [QbParseResult] with normalised customer-key maps.
QbParseResult parseQbSalesCsvWithNames(String content, {List<String> ignoreKeywords = const []}) {
  final rawLines = content.split(RegExp(r'\r?\n'));
  if (rawLines.isEmpty) return QbParseResult(lines: {}, displayNames: {});

  // Find the header row (must contain both 'qty' and 'name'/'customer')
  int headerIdx = -1;
  List<String> headers = [];
  for (int i = 0; i < rawLines.length; i++) {
    final row = _splitCsv(rawLines[i]);
    final lower = row.map((c) => c.toLowerCase().trim()).toList();
    if (lower.any((c) => c == 'name' || c == 'customer') &&
        lower.any((c) => c == 'qty' || c == 'quantity')) {
      headerIdx = i;
      headers = row.map((c) => c.trim().toLowerCase()).toList();
      break;
    }
  }
  if (headerIdx < 0) return QbParseResult(lines: {}, displayNames: {});

  // Column indices resolved from the header row.
  // QB exports have interleaved blank columns so we always resolve by name.
  final nameIdx = headers.indexWhere((h) => h == 'name' || h == 'customer');
  final typeIdx = headers.indexWhere((h) => h == 'type');
  final numIdx  = headers.indexWhere((h) => h == 'num' || h == 'invoice #' || h.startsWith('num'));
  final dateIdx = headers.indexWhere((h) => h == 'date');
  final itemIdx = headers.indexWhere((h) => h == 'item' || h == 'product/service' || h.startsWith('item'));
  // *** Column R (index 17) = Qty — devices billed per line ***
  final qtyIdx  = headers.indexWhere((h) => h == 'qty' || h == 'quantity');
  final rateIdx = headers.indexWhere((h) => h == 'sales price' || h == 'rate' || h.contains('unit price'));
  final amtIdx  = headers.indexWhere((h) => h == 'amount');
  // Column L = Memo/Description — used to skip "- New Activations" prorated lines
  final memoIdx = headers.indexWhere((h) => h == 'memo' || h == 'description' || h == 'class' || h == 'memo/description');

  if (nameIdx < 0 || qtyIdx < 0) return QbParseResult(lines: {}, displayNames: {});

  // Build a lowercase set of ignore keywords for fast matching
  final ignoreLower = ignoreKeywords.map((k) => k.toLowerCase()).toList();

  final Map<String, List<QbInvoiceLine>> result      = {};
  final Map<String, String>             displayNames = {};

  String currentCustomer    = '';
  String currentCustomerKey = '';
  String currentInvoice     = '';
  String currentDate        = '';

  for (int i = headerIdx + 1; i < rawLines.length; i++) {
    final raw = rawLines[i].trim();
    if (raw.isEmpty) continue;
    final cells = _splitCsv(raw);
    if (cells.length < 3) continue;

    String gc(int idx) =>
        (idx >= 0 && idx < cells.length) ? cells[idx].trim() : '';

    final rowType  = typeIdx >= 0 ? gc(typeIdx).toLowerCase() : '';
    final nameCell = gc(nameIdx);

    // Update customer/invoice context
    if (nameCell.isNotEmpty) {
      currentCustomer    = nameCell;
      currentCustomerKey = _normKey(nameCell);
      displayNames.putIfAbsent(currentCustomerKey, () => nameCell);
    }
    if (numIdx  >= 0 && gc(numIdx).isNotEmpty)  currentInvoice = gc(numIdx);
    if (dateIdx >= 0 && gc(dateIdx).isNotEmpty) currentDate    = gc(dateIdx);

    if (currentCustomer.isEmpty) continue;

    // Skip total/summary rows
    if (rowType.contains('total') || rowType.contains('balance')) continue;

    final item = gc(itemIdx);
    if (item.isEmpty) continue;

    // ── Skip lines where memo/description contains the configurable ignore text ─
    // Default: "- New Activations" — these are first-month charges, not recurring fees.
    final memo = memoIdx >= 0 ? gc(memoIdx).toLowerCase() : '';
    final ignoreText = QbIgnoreKeywordService.newActivationsIgnoreText.toLowerCase().trim();
    if (ignoreText.isNotEmpty && memo.contains(ignoreText)) continue;

    // ── Skip lines where Item/SKU matches any user-configured ignore keyword ─
    final itemLower = item.toLowerCase();
    if (ignoreLower.any((kw) => itemLower.contains(kw))) continue;

    // Skip non-Geotab/camera service items (after ignore-keyword check)
    // Camera SKUs: Surfsight, Go Focus, Go Focus Plus, Smarter AI
    final isCameraSkuItem = itemLower.contains('surfsight') ||
        itemLower.contains('ss service') ||
        itemLower.contains('ss camera') ||
        itemLower.contains('go focus') ||
        itemLower.contains('gofocus') ||
        itemLower.contains('smarter ai') ||
        itemLower.contains('smarterai');
    if (!itemLower.contains('geotab') &&
        !itemLower.contains('service fee') &&
        !isCameraSkuItem) continue;

    // Skip credit card fees, shipping, early termination, etc. (hard-coded safety net)
    if (itemLower.contains('credit card') ||
        itemLower.contains('shipping') ||
        itemLower.contains('early term') ||
        itemLower.contains('mkt-fee')) continue;

    // Qty column R — number of devices billed on this line
    final qtyRaw = gc(qtyIdx).replaceAll(',', '');
    final qty    = double.tryParse(qtyRaw) ?? 0.0;
    if (qty <= 0) continue; // skip lines with no devices

    final amount =
        amtIdx >= 0
            ? (double.tryParse(
                    gc(amtIdx).replaceAll(RegExp(r'[,\$]'), '')) ??
                0.0)
            : 0.0;
    final unitPrice =
        rateIdx >= 0
            ? (double.tryParse(
                    gc(rateIdx).replaceAll(RegExp(r'[,\$%]'), '')) ??
                0.0)
            : 0.0;

    // Extract a short plan label from the item description
    final planLabel = _extractPlanLabel(item);

    result.putIfAbsent(currentCustomerKey, () => []);
    result[currentCustomerKey]!.add(QbInvoiceLine(
      invoiceNumber: currentInvoice,
      date:          currentDate,
      description:   item,
      qty:           qty,
      unitPrice:     unitPrice,
      amount:        amount > 0 ? amount : qty * unitPrice,
      planLabel:     planLabel,
    ));
  }

  return QbParseResult(lines: result, displayNames: displayNames);
}

/// Extract a short plan label from a QB item description.
/// Examples:
///   "Geotab Service:Service Fee Geotab (HOS V2) (Service Fee Geotab (HOS))" → "HOS"
///   "Geotab Service:Geotab Service (GO Plan) (...)" → "GO"
///   "Geotab Service:Service Fee Geotab (Pro V2) (...)" → "Pro"
///   "Geotab Service:SS Service Fee (...)" → "Surfsight"
///   "Geotab Service:Hanover (...)" → "Hanover"
///   "Service (GO Focus)" → "Go Focus"
///   "Service (GO Focus Plus)" → "Go Focus Plus"
///   "Smarter AI Service Fee" → "Smarter AI"
String _extractPlanLabel(String item) {
  final lower = item.toLowerCase();

  // ── Camera product lines ──────────────────────────────────────────────────
  // Surfsight / SS camera lines
  if (lower.contains('surfsight') || lower.contains('ss service') ||
      lower.contains('ss camera')) return 'Surfsight';

  // Go Focus Plus must be checked before Go Focus (longer match wins)
  if (lower.contains('go focus plus') || lower.contains('gofocus plus') ||
      lower.contains('focus plus')) return 'Go Focus Plus';

  // Go Focus (standalone — not Plus)
  if (lower.contains('go focus') || lower.contains('gofocus')) return 'Go Focus';

  // Smarter AI
  if (lower.contains('smarter ai') || lower.contains('smarterai')) return 'Smarter AI';

  // ── Geotab / Hanover lines ────────────────────────────────────────────────
  // Hanover rate plan
  if (lower.contains('hanover')) return 'Hanover';

  // Extract from innermost parenthetical e.g. "(Service Fee Geotab (HOS))"
  // Try last paren group first
  final allParens = RegExp(r'\(([^()]+)\)').allMatches(item);
  for (final m in allParens.toList().reversed) {
    final inside = m.group(1)!.trim();
    // look for known plan keywords inside
    final il = inside.toLowerCase();
    if (il.contains('hanover')) return 'Hanover';
    if (il.contains('proplus') || il.contains('pro plus')) return 'ProPlus';
    if (il.contains('pro')) return 'Pro';
    if (il.contains('hos')) return 'HOS';
    if (il.contains('go plan') || il == 'go' || il.endsWith('(go)') ||
        il.startsWith('go')) return 'GO';
    if (il.contains('regulatory')) return 'Regulatory';
    if (il.contains('base')) return 'Base';
    if (il.contains('suspend')) return 'Suspend';
    if (il.contains('predictive')) return 'Predictive Coach';
  }

  // Fallback: scan item string directly
  final il = lower;
  if (il.contains('hanover')) return 'Hanover';
  if (il.contains('proplus') || il.contains('pro plus')) return 'ProPlus';
  if (il.contains('pro')) return 'Pro';
  if (il.contains('hos')) return 'HOS';
  if (il.contains('go plan') || RegExp(r'\bgo\b').hasMatch(il)) return 'GO';
  if (il.contains('regulatory')) return 'Regulatory';
  if (il.contains('base')) return 'Base';
  if (il.contains('suspend')) return 'Suspend';
  if (il.contains('predictive')) return 'Predictive Coach';

  return item.length > 30 ? '${item.substring(0, 30)}…' : item;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Normalise a customer name for cross-source matching.
///
/// MyAdmin can append two types of suffix that QB names never have:
///   • Parenthetical location:  "Baker Roofing (Seth Hagen Raleigh NC)" → "baker roofing"
///   • Curly-brace device type: "Acme Corp {Cameras}" → "acme corp"
///     (same QB customer, just different device-type sub-groups)
///
/// Both are stripped before lowercasing so all sub-groups merge to one key.
String _normKey(String name) {
  String s = name;
  // 1. Strip curly-brace device-type suffix first, e.g. " {Cameras}"
  s = _stripCurlyBraceSuffix(s);
  // 2. Strip parenthetical location/contact suffix, e.g. " (City State)"
  s = _stripParenSuffix(s);
  // 3. Collapse whitespace and lowercase
  return s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Remove a trailing curly-brace suffix, e.g. " {Cameras}" or " {OEM}".
String _stripCurlyBraceSuffix(String name) {
  final idx = name.indexOf('{');
  return idx > 0 ? name.substring(0, idx).trim() : name.trim();
}

/// Remove a trailing parenthetical suffix, e.g. " (City  State  Country)".
String _stripParenSuffix(String name) {
  final idx = name.indexOf('(');
  return idx > 0 ? name.substring(0, idx).trim() : name.trim();
}

List<String> _splitCsv(String row) {
  final cells = <String>[];
  bool inQuotes = false;
  final buf = StringBuffer();
  for (int i = 0; i < row.length; i++) {
    final ch = row[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  return cells;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class QbInvoiceScreen extends StatefulWidget {
  const QbInvoiceScreen({super.key});

  @override
  State<QbInvoiceScreen> createState() => _QbInvoiceScreenState();
}

class _QbInvoiceScreenState extends State<QbInvoiceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();

  // MyAdmin data
  Map<String, List<MyAdminDevice>> _myAdminData = {};
  bool _myAdminLoaded = false;
  String? _myAdminFileName;
  String? _myAdminReportDate;

  // QB data
  Map<String, List<QbInvoiceLine>> _qbData = {};
  // Cache of normKey → original QB display name (for QB-only rows)
  Map<String, String> _qbDisplayNameCache = {};
  bool _qbLoaded = false;
  String? _qbFileName;

  String _search = '';
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _searchCtrl.addListener(() {
      setState(() => _search = _searchCtrl.text.toLowerCase());
    });
    // Restore previously imported CSVs so data survives page refresh / reopen
    WidgetsBinding.instance.addPostFrameCallback((_) => _restorePersistedCsvs());
    // Re-run restore after any cloud pull completes so MyAdmin + QB CSVs
    // are refreshed even if the pull happened after initState fired.
    CloudSyncService.statusNotifier.addListener(_onSyncStatusChanged);
  }

  // Re-load CSVs from SharedPreferences whenever a cloud pull finishes.
  // This ensures MyAdmin + QB data is current after a sync.
  void _onSyncStatusChanged() {
    if (CloudSyncService.status == SyncStatus.success ||
        CloudSyncService.status == SyncStatus.idle) {
      _restorePersistedCsvs();
    }
  }

  // ── Restore persisted CSV data on startup ──────────────────────────────────

  Future<void> _restorePersistedCsvs() async {
    // Restore MyAdmin CSV
    final ma = await CsvPersistService.loadMyAdmin();
    if (ma != null && ma.content.isNotEmpty) {
      final parsed = parseMyAdminCsv(ma.content);
      if (parsed.isNotEmpty && mounted) {
        setState(() {
          _myAdminData      = parsed;
          _myAdminLoaded    = true;
          _myAdminFileName  = ma.fileName;
          _myAdminReportDate = ma.reportDate;
        });
      }
    }

    // Restore QB CSV
    final qb = await CsvPersistService.loadQb();
    if (qb != null && qb.content.isNotEmpty) {
      final qbParsed = parseQbSalesCsvWithNames(qb.content,
          ignoreKeywords: QbIgnoreKeywordService.getAllKeywords());
      if (qbParsed.lines.isNotEmpty && mounted) {
        setState(() {
          _qbData             = qbParsed.lines;
          _qbDisplayNameCache = qbParsed.displayNames;
          _qbLoaded           = true;
          _qbFileName         = qb.fileName;
        });
      }
    }
  }

  @override
  void dispose() {
    CloudSyncService.statusNotifier.removeListener(_onSyncStatusChanged);
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Import MyAdmin ────────────────────────────────────────────────────────

  Future<void> _importMyAdmin() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        content = decodeBytesToString(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }

      // Extract report date from line 2
      String? reportDate;
      final firstLines = content.split(RegExp(r'\r?\n'));
      if (firstLines.length > 1) {
        final dateLine = firstLines[1].trim();
        if (dateLine.startsWith('Report Date:')) {
          reportDate = dateLine.replaceFirst('Report Date:', '').trim();
        }
      }

      final parsed = parseMyAdminCsv(content);
      if (!mounted) return;

      if (parsed.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not parse MyAdmin report. Make sure this is the '
                '"Device Management - Full Report" CSV from MyAdmin.'),
            backgroundColor: AppTheme.red,
          ),
        );
        return;
      }

      final totalDevices =
          parsed.values.fold(0, (s, list) => s + list.length);

      setState(() {
        _myAdminData    = parsed;
        _myAdminLoaded  = true;
        _myAdminFileName = file.name;
        _myAdminReportDate = reportDate;
        _expanded.clear();
      });

      // Persist so the data survives page refresh / app reopen
      await CsvPersistService.saveMyAdmin(
        content:    content,
        fileName:   file.name,
        reportDate: reportDate,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'MyAdmin: $totalDevices devices across ${parsed.length} customers'),
            backgroundColor: AppTheme.teal,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import error: $e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }

  // ── Import QB ─────────────────────────────────────────────────────────────

  Future<void> _importQb() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        content = decodeBytesToString(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }

      final qbParsed = parseQbSalesCsvWithNames(content,
          ignoreKeywords: QbIgnoreKeywordService.getAllKeywords());
      if (!mounted) return;

      if (qbParsed.lines.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not find invoice data. Make sure this is a '
                '"Sales by Customer Detail" CSV export from QuickBooks.'),
            backgroundColor: AppTheme.red,
          ),
        );
        return;
      }

      setState(() {
        _qbData              = qbParsed.lines;
        _qbDisplayNameCache  = qbParsed.displayNames;
        _qbLoaded            = true;
        _qbFileName          = file.name;
        _expanded.clear();
      });

      // Persist so the data survives page refresh / app reopen
      await CsvPersistService.saveQb(
        content:  content,
        fileName: file.name,
      );

      final totalDevicesBilled = qbParsed.lines.values
          .fold(0.0, (s, list) => s + list.fold(0.0, (s2, l) => s2 + l.qty))
          .round();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'QB: $totalDevicesBilled devices billed across ${qbParsed.lines.length} customers'),
            backgroundColor: AppTheme.teal,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import error: $e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }

  // ── Build Summaries ───────────────────────────────────────────────────────

  List<QbCustomerSummary> _buildSummaries() {
    // Collect all customer keys from both sides
    final allKeys = {
      ..._myAdminData.keys,
      ..._qbData.keys,
    };

    // Load the CUA flags once (name → isCua).
    // Use normalized map so slight name differences still match
    // (e.g. "Cyprus Air" in MyAdmin vs "Cyprus Air, Inc" in QB).
    final cuaMap     = QbCustomerService.getCuaMapNormalized();
    final jobTypeMap = QbCustomerService.getJobTypeMapNormalized();

    final List<QbCustomerSummary> summaries = allKeys.map((key) {
      final devices = _myAdminData[key] ?? [];
      final qbLines = _qbData[key] ?? [];

      // Build display name:
      //  1. Prefer stripped MyAdmin name (proper casing, no location suffix)
      //  2. Fall back to QB display-name cache (preserves QB casing)
      //  3. Last resort: the normalised key itself
      String displayName;
      if (devices.isNotEmpty) {
        displayName = _stripLocation(devices.first.customer);
      } else {
        displayName = _qbDisplayNameCache[key] ?? key;
      }

      // Look up CUA flag using normalised key first, then display name, then QB cache name.
      // _normKey() already normalizes (strips parens/curlies, lowercase, collapse whitespace)
      // so it doubles as the normalization function for the cuaMap lookup.
      final normDisplay = _normKey(displayName);
      final isCua = cuaMap[displayName] ??
          cuaMap[normDisplay] ??
          cuaMap[_qbDisplayNameCache[key] ?? key] ??
          cuaMap[key] ??
          false;
      final jobType = jobTypeMap[displayName] ??
          jobTypeMap[normDisplay] ??
          jobTypeMap[_qbDisplayNameCache[key] ?? key] ??
          jobTypeMap[key] ??
          '';

      // ── Billing rules ──────────────────────────────────────────────────────
      //
      // GEOTAB devices:
      //   Standard → Active + Suspended + Never Activated
      //   CUA      → Active + Suspended  (Never Activated excluded)
      //
      // CAMERA devices ({Cameras} sub-group in MyAdmin):
      //   Standard      → Active + Never Activated  (Suspended NOT billed)
      //   CUA (general) → Active + Never Activated  (CUA rule does NOT apply to cameras)
      //   CUA + Hollywood Feed Corporate → Active only (they are CUA for cameras too)
      //
      // Hollywood Feed Corporate exception detected via isCua + name match.
      // Unknown devices are always excluded from billing diff (shown for review only).
      // Hanover-RPC devices: excluded unless covered by a HANOVER-CS QB line (cost share).

      // Is this the Hollywood Feed Corporate account (CUA for cameras too)?
      final isHollywoodFeed = displayName.toLowerCase().contains('hollywood feed');

      // How many HANOVER-CS QB lines are there for this customer?
      final hanoverCsQty = qbLines
          .where((l) => l.planLabel.toLowerCase() == 'hanover')
          .fold(0, (s, l) => s + l.qty.round());

      // Hanover-RPC devices billed direct to Hanover (not this customer)
      final hanoverDevices = devices.where((d) => d.isHanover).toList();
      final hanoverExcluded = (hanoverDevices.length - hanoverCsQty).clamp(0, hanoverDevices.length);

      // ── Camera billable count ────────────────────────────────────────────
      final cameraDevices = devices.where((d) => d.isCamera).toList();
      final billableCameras = cameraDevices.where((d) {
        final s = d.billingStatus.toLowerCase();
        if (s == 'unknown') return false;
        if (d.isHanover) return false;
        if (isCua && isHollywoodFeed) {
          // Hollywood Feed: CUA applies to cameras → Active only
          return s == 'active';
        }
        // All other customers (Standard or CUA): Active + Never Activated/Billed
        return s == 'active' || s == 'never activated' || s == 'never billed';
      }).toList();

      // ── Geotab billable count ────────────────────────────────────────────
      final geotabDevices = devices.where((d) => !d.isCamera).toList();
      final billableGeotab = geotabDevices.where((d) {
        final s = d.billingStatus.toLowerCase();
        if (s == 'unknown') return false;
        if (d.isHanover) return false; // handled via hanoverCsQty
        if (isCua) {
          // CUA: Active + Suspended (Never Activated excluded)
          return s == 'active' || s == 'suspended';
        }
        // Standard: Active + Suspended + Never Activated/Billed
        return s == 'active' || s == 'suspended' || s == 'never activated' || s == 'never billed';
      }).toList();

      // Cost-share Hanover devices count toward billable (customer pays half)
      final hanoverBillableCount = hanoverCsQty.clamp(0, hanoverDevices.length);
      final totalBillable = billableGeotab.length + billableCameras.length + hanoverBillableCount;

      final unknownDeviceCount = devices
          .where((d) => d.billingStatus.toLowerCase() == 'unknown')
          .length;

      // ── Go Focus / Go Focus Plus sub-counts ─────────────────────────────
      final goFocusCount     = billableCameras.where((d) => d.isGoFocus).length;
      final goFocusPlusCount = billableCameras.where((d) => d.isGoFocusPlus).length;

      return QbCustomerSummary(
        customerName: displayName.isEmpty ? key : displayName,
        // billedCount = sum of Qty across all QB lines (devices invoiced, not row count)
        billedCount: qbLines.fold(0, (s, l) => s + l.qty.round()),
        totalBilled: qbLines.fold(0.0, (s, l) => s + l.amount),
        qbLines: qbLines,
        activeCount: totalBillable,
        unknownCount: unknownDeviceCount,
        hanoverCount: hanoverExcluded,
        hanoverCsQty: hanoverBillableCount,
        cameraCount:      billableCameras.length,
        goFocusCount:     goFocusCount,
        goFocusPlusCount: goFocusPlusCount,
        geotabCount:  billableGeotab.length,
        activeDevices: devices,
        isCua: isCua,
        jobType: jobType,
      );
    }).toList();

    // ── Hanover Insurance Company roll-up ─────────────────────────────────
    // Any device across ANY customer that has ratePlanCode == 'hanover' AND
    // a billing plan containing 'GO' (case-insensitive) is billed directly
    // to Hanover Insurance Company — not to the device's own customer.
    // Collect those devices and inject them into Hanover's summary so they
    // appear as billable devices under "Hanover Insurance Company" in QB Verify.
    final hanoverGoDevices = <MyAdminDevice>[];
    for (final deviceList in _myAdminData.values) {
      for (final d in deviceList) {
        if (d.isHanover &&
            d.billingPlan.toLowerCase().contains('go') &&
            d.billingStatus.toLowerCase() == 'active') {
          hanoverGoDevices.add(d);
        }
      }
    }

    if (hanoverGoDevices.isNotEmpty) {
      const hanoverKey = 'hanover insurance company';
      final existingIdx = summaries.indexWhere(
          (s) => s.customerName.toLowerCase().contains('hanover insurance'));

      if (existingIdx >= 0) {
        // Hanover Insurance Company already has a QB entry — merge GO devices in
        final existing = summaries[existingIdx];
        // Avoid double-counting devices already listed under Hanover's own key
        final existingSerials =
            existing.activeDevices.map((d) => d.serialNumber).toSet();
        final newDevices = hanoverGoDevices
            .where((d) => !existingSerials.contains(d.serialNumber))
            .toList();
        if (newDevices.isNotEmpty) {
          summaries[existingIdx] = QbCustomerSummary(
            customerName: existing.customerName,
            billedCount:  existing.billedCount,
            totalBilled:  existing.totalBilled,
            qbLines:      existing.qbLines,
            activeCount:  existing.activeCount + newDevices.length,
            unknownCount: existing.unknownCount,
            hanoverCount: existing.hanoverCount,
            hanoverCsQty: existing.hanoverCsQty,
            cameraCount:  existing.cameraCount,
            geotabCount:  existing.geotabCount + newDevices.length,
            activeDevices: [...existing.activeDevices, ...newDevices],
            isCua:         existing.isCua,
            jobType:       existing.jobType,
          );
        }
      } else {
        // No QB entry yet for Hanover Insurance Company — create one from
        // MyAdmin data alone so it surfaces as "Not Billed" if missing from QB.
        final qbLines = _qbData[hanoverKey] ?? [];
        summaries.add(QbCustomerSummary(
          customerName: 'Hanover Insurance Company',
          billedCount:  qbLines.fold(0, (s, l) => s + l.qty.round()),
          totalBilled:  qbLines.fold(0.0, (s, l) => s + l.amount),
          qbLines:      qbLines,
          activeCount:  hanoverGoDevices.length,
          unknownCount: 0,
          hanoverCount: 0,
          hanoverCsQty: 0,
          cameraCount:  0,
          geotabCount:  hanoverGoDevices.length,
          activeDevices: hanoverGoDevices,
          isCua:         false,
          jobType:       '',
        ));
      }
    }

    // ── Parent-child account roll-up ──────────────────────────────────────────
    // Child accounts have devices in MyAdmin but the monthly invoice goes to the
    // parent.  Roll each child's activeCount into its parent's summary row,
    // then remove the child row so it never surfaces as a false "activeOnly" alarm.
    final parentMap = QbCustomerService.getParentMapNormalized();
    if (parentMap.isNotEmpty) {
      final toRemove = <int>{}; // indices of child summaries to drop

      for (int ci = 0; ci < summaries.length; ci++) {
        final childNorm = _normKey(summaries[ci].customerName);
        final parentNorm = parentMap[childNorm];
        if (parentNorm == null) continue; // not a child account

        // Find the parent summary by normKey
        final pi = summaries.indexWhere(
            (s) => _normKey(s.customerName) == parentNorm);

        if (pi >= 0) {
          final child  = summaries[ci];
          final parent = summaries[pi];

          // Merge child's billable device count + device list into the parent.
          // The parent's CUA rule was already applied when its own summary was
          // built, so we add the child's activeCount as-is (child falls under
          // the parent's CUA umbrella per business rule).
          summaries[pi] = QbCustomerSummary(
            customerName:  parent.customerName,
            billedCount:   parent.billedCount,
            totalBilled:   parent.totalBilled,
            qbLines:       parent.qbLines,
            activeCount:   parent.activeCount + child.activeCount,
            unknownCount:  parent.unknownCount + child.unknownCount,
            hanoverCount:  parent.hanoverCount + child.hanoverCount,
            hanoverCsQty:  parent.hanoverCsQty + child.hanoverCsQty,
            cameraCount:   parent.cameraCount  + child.cameraCount,
            geotabCount:   parent.geotabCount  + child.geotabCount,
            goFocusCount:     parent.goFocusCount     + child.goFocusCount,
            goFocusPlusCount: parent.goFocusPlusCount + child.goFocusPlusCount,
            activeDevices: [...parent.activeDevices, ...child.activeDevices],
            isCua:    parent.isCua,
            jobType:  parent.jobType,
          );
        }
        // Whether or not the parent was found in the list, always remove the
        // child row — it should never surface as a standalone verify entry.
        toRemove.add(ci);
      }

      // Remove child rows in reverse order so indices stay valid
      for (final idx in toRemove.toList().reversed) {
        summaries.removeAt(idx);
      }
    }

    // Sort: issues first, then alphabetically
    summaries.sort((a, b) {
      final aOk = a.status == VerifyStatus.match ? 1 : 0;
      final bOk = b.status == VerifyStatus.match ? 1 : 0;
      if (aOk != bOk) return aOk - bOk;
      return a.customerName.compareTo(b.customerName);
    });

    return summaries;
  }

  /// Strip the location/contact suffix AND device-type suffix from MyAdmin names.
  /// e.g. "Baker Roofing (Seth Hagen  Raleigh  NC)" → "Baker Roofing"
  ///      "Acme Corp {Cameras}"                    → "Acme Corp"
  String _stripLocation(String name) {
    String s = _stripCurlyBraceSuffix(name); // strip {Cameras} etc first
    s = _stripParenSuffix(s);                // then strip (location) suffix
    return s;
  }

  // ── Filter for tab ────────────────────────────────────────────────────────

  List<QbCustomerSummary> _filterForTab(
      List<QbCustomerSummary> all, int tabIndex) {
    List<QbCustomerSummary> list;
    switch (tabIndex) {
      case 1: // Issues: overbilled + underbilled
        list = all
            .where((s) =>
                s.status == VerifyStatus.overbilled ||
                s.status == VerifyStatus.underbilled)
            .toList();
        break;
      case 2: // Active Only — in MyAdmin but not in QB (not invoiced!)
        list = all
            .where((s) => s.status == VerifyStatus.activeOnly)
            .toList();
        break;
      case 3: // QB Only — in QB but not in MyAdmin
        list = all
            .where((s) => s.status == VerifyStatus.qbOnly)
            .toList();
        break;
      default:
        list = all;
    }
    if (_search.isEmpty) return list;
    return list
        .where((s) => s.customerName.toLowerCase().contains(_search))
        .toList();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // We still watch AppProvider for any future integration
    context.watch<AppProvider>();

    final hasAnyData = _myAdminLoaded || _qbLoaded;
    final summaries  = hasAnyData ? _buildSummaries() : <QbCustomerSummary>[];

    final issueCount   = summaries.where((s) =>
        s.status == VerifyStatus.overbilled ||
        s.status == VerifyStatus.underbilled).length;
    final activeOnlyCount = summaries
        .where((s) => s.status == VerifyStatus.activeOnly).length;
    final qbOnlyCount = summaries
        .where((s) => s.status == VerifyStatus.qbOnly).length;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.verified_outlined, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('QB Verify'),
          ],
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          labelStyle:
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          tabs: [
            const Tab(text: 'All'),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Issues'),
                if (issueCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(issueCount, AppTheme.amber),
                ],
              ]),
            ),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Not Billed'),
                if (activeOnlyCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(activeOnlyCount, AppTheme.red),
                ],
              ]),
            ),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('QB Only'),
                if (qbOnlyCount > 0) ...[
                  const SizedBox(width: 4),
                  _CountBadge(qbOnlyCount, Colors.grey),
                ],
              ]),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Import action bar ───────────────────────────────────────────
          _ImportBar(
            myAdminLoaded:   _myAdminLoaded,
            myAdminFileName: _myAdminFileName,
            myAdminDate:     _myAdminReportDate,
            qbLoaded:        _qbLoaded,
            qbFileName:      _qbFileName,
            onImportMyAdmin: _importMyAdmin,
            onImportQb:      _importQb,
          ),

          if (!hasAnyData)
            _EmptyState(
                onImportMyAdmin: _importMyAdmin, onImportQb: _importQb)
          else ...[
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search customers…',
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  isDense: true,
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        )
                      : null,
                ),
              ),
            ),

            // Tab views
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: List.generate(4, (tabIdx) {
                  final filtered = _filterForTab(summaries, tabIdx);
                  if (filtered.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            tabIdx == 0
                                ? Icons.inbox
                                : Icons.check_circle_outline,
                            size: 48,
                            color: AppTheme.green.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tabIdx == 0
                                ? 'No customers to display'
                                : 'No issues in this category ✓',
                            style: const TextStyle(
                                color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final s = filtered[i];
                      final key = s.customerName.toLowerCase();
                      return _CustomerVerifyCard(
                        summary: s,
                        expanded: _expanded.contains(key),
                        onToggle: () => setState(() {
                          if (_expanded.contains(key)) {
                            _expanded.remove(key);
                          } else {
                            _expanded.add(key);
                          }
                        }),
                      );
                    },
                  );
                }),
              ),
            ),
          ],

          // ── Summary footer ───────────────────────────────────────────────
          if (summaries.isNotEmpty)
            _SummaryFooter(summaries: summaries),
        ],
      ),
    );
  }
}

// ── Import Bar ────────────────────────────────────────────────────────────────

class _ImportBar extends StatelessWidget {
  final bool myAdminLoaded;
  final String? myAdminFileName;
  final String? myAdminDate;
  final bool qbLoaded;
  final String? qbFileName;
  final VoidCallback onImportMyAdmin;
  final VoidCallback onImportQb;

  const _ImportBar({
    required this.myAdminLoaded,
    required this.myAdminFileName,
    required this.myAdminDate,
    required this.qbLoaded,
    required this.qbFileName,
    required this.onImportMyAdmin,
    required this.onImportQb,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.navyDark,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          // MyAdmin side
          Expanded(
            child: _ImportSlot(
              icon: Icons.devices,
              label: 'MyAdmin Report',
              sublabel: myAdminLoaded
                  ? (myAdminDate ?? myAdminFileName ?? 'Loaded')
                  : 'Device Management Full Report',
              loaded: myAdminLoaded,
              color: AppTheme.teal,
              onTap: onImportMyAdmin,
            ),
          ),
          const SizedBox(width: 8),
          // VS divider
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppTheme.navyMid,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12),
                ),
                child: const Center(
                  child: Text('VS',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white38)),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          // QB side
          Expanded(
            child: _ImportSlot(
              icon: Icons.receipt_long,
              label: 'QB Sales CSV',
              sublabel: qbLoaded
                  ? (qbFileName ?? 'Loaded')
                  : 'Sales by Customer Detail',
              loaded: qbLoaded,
              color: AppTheme.navyAccent,
              onTap: onImportQb,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportSlot extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final bool loaded;
  final Color color;
  final VoidCallback onTap;

  const _ImportSlot({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.loaded,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: loaded
              ? color.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: loaded
                ? color.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          children: [
            Icon(
              loaded ? Icons.check_circle : icon,
              size: 18,
              color: loaded ? color : Colors.white38,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: loaded ? color : Colors.white54,
                    ),
                  ),
                  Text(
                    sublabel,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.white38),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.upload_file,
              size: 14,
              color: loaded ? color.withValues(alpha: 0.6) : Colors.white24,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onImportMyAdmin;
  final VoidCallback onImportQb;

  const _EmptyState({
    required this.onImportMyAdmin,
    required this.onImportQb,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Icon(Icons.compare_arrows,
                size: 64,
                color: AppTheme.navyAccent.withValues(alpha: 0.3)),
            const SizedBox(height: 20),
            const Text(
              'Invoice Audit — Before You Send',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Compare your MyAdmin active devices against QuickBooks '
              'invoices to catch discrepancies before billing goes out.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 28),

            // Two-card import instructions
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _StepCard(
                    step: '1',
                    color: AppTheme.teal,
                    icon: Icons.devices,
                    title: 'MyAdmin Report',
                    body:
                        'MyAdmin → Reports → Device Management → Full Report → Export CSV',
                    buttonLabel: 'Import MyAdmin CSV',
                    onTap: onImportMyAdmin,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StepCard(
                    step: '2',
                    color: AppTheme.navyAccent,
                    icon: Icons.receipt_long,
                    title: 'QB Sales Report',
                    body:
                        'QuickBooks → Reports → Sales → Sales by Customer Detail → Export CSV',
                    buttonLabel: 'Import QB CSV',
                    onTap: onImportQb,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Legend
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Status Legend',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70)),
                  const SizedBox(height: 8),
                  ..._legendItems.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          children: [
                            Icon(item.$1, size: 14, color: item.$2),
                            const SizedBox(width: 8),
                            Text(item.$3,
                                style: TextStyle(
                                    fontSize: 11, color: item.$2,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(item.$4,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white38)),
                            ),
                          ],
                        ),
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _legendItems = [
    (Icons.check_circle, AppTheme.green, 'Match',
        'Billed count = billable device count'),
    (Icons.warning_amber, AppTheme.amber, 'Overbilled',
        'More QB lines than billable MyAdmin devices'),
    (Icons.error, AppTheme.red, 'Underbilled',
        'Fewer QB lines than billable MyAdmin devices — revenue leak'),
    (Icons.money_off, AppTheme.red, 'Not Billed',
        'Billable devices in MyAdmin but no QB invoice'),
    (Icons.help_outline, Colors.grey, 'QB Only',
        'In QB but not in MyAdmin — possibly a closed account'),
    (Icons.shield_outlined, Colors.teal, 'Hanover-direct',
        'Devices on Hanover Insurance rate plan — billed direct to Hanover, not this customer. '
        'HANOVER-CS (Cost Share) lines split billing 50/50 and are included in the billable count.'),
    (Icons.videocam_outlined, Colors.indigo, 'Camera devices',
        'Billed: Active + Never Activated (Suspended excluded). '
        'Exception: Hollywood Feed Corporate cameras are CUA → Active only.'),
    (Icons.gps_fixed, AppTheme.navyAccent, 'GPS/Geotab devices',
        'Standard: Active + Suspended + Never Activated. '
        'CUA: Active + Suspended (Never Activated excluded).'),
  ];
}

class _StepCard extends StatelessWidget {
  final String step;
  final Color color;
  final IconData icon;
  final String title;
  final String body;
  final String buttonLabel;
  final VoidCallback onTap;

  const _StepCard({
    required this.step,
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
    required this.buttonLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                    color: color, shape: BoxShape.circle),
                child: Center(
                  child: Text(step,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
              ),
              child: Text(buttonLabel),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Customer Verify Card ──────────────────────────────────────────────────────

class _CustomerVerifyCard extends StatelessWidget {
  final QbCustomerSummary summary;
  final bool expanded;
  final VoidCallback onToggle;

  const _CustomerVerifyCard({
    required this.summary,
    required this.expanded,
    required this.onToggle,
  });

  Color get _color {
    switch (summary.status) {
      case VerifyStatus.match:      return AppTheme.green;
      case VerifyStatus.overbilled: return AppTheme.amber;
      case VerifyStatus.underbilled:return AppTheme.red;
      case VerifyStatus.qbOnly:     return Colors.grey;
      case VerifyStatus.activeOnly: return AppTheme.red;
    }
  }

  IconData get _icon {
    switch (summary.status) {
      case VerifyStatus.match:      return Icons.check_circle;
      case VerifyStatus.overbilled: return Icons.warning_amber;
      case VerifyStatus.underbilled:return Icons.error;
      case VerifyStatus.qbOnly:     return Icons.help_outline;
      case VerifyStatus.activeOnly: return Icons.money_off;
    }
  }

  String get _label {
    switch (summary.status) {
      case VerifyStatus.match:      return 'Match';
      case VerifyStatus.overbilled: return 'Overbilled +${summary.diff}';
      case VerifyStatus.underbilled:return 'Underbilled ${summary.diff}';
      case VerifyStatus.qbOnly:     return 'QB Only';
      case VerifyStatus.activeOnly: return 'Not Billed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          // ── Header row ──────────────────────────────────────────────
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Icon(_icon, size: 20, color: _color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.customerName,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        if (summary.jobType.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Text(
                            summary.jobType,
                            style: TextStyle(
                              fontSize: 9,
                              color: summary.isCua
                                  ? Colors.deepPurple.withValues(alpha: 0.75)
                                  : AppTheme.textSecondary.withValues(alpha: 0.65),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (summary.isCua) ...[
                              _MiniChip(
                                icon: Icons.bolt,
                                label: 'CUA',
                                color: Colors.deepPurple,
                              ),
                              const SizedBox(width: 4),
                            ],
                            // Show combined billable count
                            _MiniChip(
                              icon: Icons.devices,
                              label: 'Billable: ${summary.activeCount}',
                              color: AppTheme.teal,
                            ),
                            // Show Geotab + Camera breakdown when both present
                            if (summary.cameraCount > 0 && summary.geotabCount > 0) ...[
                              const SizedBox(width: 4),
                              _MiniChip(
                                icon: Icons.gps_fixed,
                                label: 'GPS ${summary.geotabCount}',
                                color: AppTheme.navyAccent,
                              ),
                              const SizedBox(width: 4),
                              // Show GF/GE sub-type chips if available, else total cameras
                              if (summary.goFocusCount > 0 || summary.goFocusPlusCount > 0) ...[
                                if (summary.goFocusCount > 0) ...[
                                  _MiniChip(
                                    icon: Icons.videocam_outlined,
                                    label: 'Cam-GF ${summary.goFocusCount}',
                                    color: Colors.indigo,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (summary.goFocusPlusCount > 0)
                                  _MiniChip(
                                    icon: Icons.videocam,
                                    label: 'Cam-GE ${summary.goFocusPlusCount}',
                                    color: Colors.deepPurple,
                                  ),
                              ] else
                                _MiniChip(
                                  icon: Icons.videocam_outlined,
                                  label: 'Cam ${summary.cameraCount}',
                                  color: Colors.indigo,
                                ),
                            ] else if (summary.cameraCount > 0) ...[
                              const SizedBox(width: 4),
                              // Camera-only customer: show GF/GE if available
                              if (summary.goFocusCount > 0 || summary.goFocusPlusCount > 0) ...[
                                if (summary.goFocusCount > 0) ...[
                                  _MiniChip(
                                    icon: Icons.videocam_outlined,
                                    label: 'Cam-GF ${summary.goFocusCount}',
                                    color: Colors.indigo,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (summary.goFocusPlusCount > 0)
                                  _MiniChip(
                                    icon: Icons.videocam,
                                    label: 'Cam-GE ${summary.goFocusPlusCount}',
                                    color: Colors.deepPurple,
                                  ),
                              ] else
                                _MiniChip(
                                  icon: Icons.videocam_outlined,
                                  label: 'Cam ${summary.cameraCount}',
                                  color: Colors.indigo,
                                ),
                            ],
                            if (summary.unknownCount > 0) ...[
                              const SizedBox(width: 4),
                              _MiniChip(
                                icon: Icons.help_outline,
                                label: '??? ${summary.unknownCount}',
                                color: Colors.grey,
                              ),
                            ],
                            if (summary.hanoverCount > 0) ...[
                              const SizedBox(width: 4),
                              _MiniChip(
                                icon: Icons.shield_outlined,
                                label: 'HNV ${summary.hanoverCount}',
                                color: Colors.teal,
                              ),
                            ],
                            const SizedBox(width: 6),
                            _MiniChip(
                              icon: Icons.receipt,
                              label: 'Billed: ${summary.billedCount}',
                              color: AppTheme.navyAccent,
                            ),
                            if (summary.totalBilled > 0) ...[
                              const SizedBox(width: 6),
                              Text(
                                Formatters.currency(summary.totalBilled),
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _color.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      _label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),

          // ── Expanded detail ─────────────────────────────────────────
          if (expanded) ...[
            const Divider(height: 1, color: AppTheme.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── MyAdmin active devices section ─────────────────
                  _SideHeader(
                    icon: Icons.devices,
                    label: _buildDeviceHeaderLabel(summary),
                    color: AppTheme.teal,
                  ),
                  // ── Hanover callout (if applicable) ────────────────
                  if (summary.hanoverCount > 0 || summary.hanoverCsQty > 0)
                    _HanoverCallout(summary: summary),
                  const SizedBox(height: 6),
                  if (summary.activeDevices.isNotEmpty) ...[
                    _DeviceTable(devices: summary.activeDevices),
                    const SizedBox(height: 4),
                    // "View All" button
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _showAllSerials(context),
                        icon: const Icon(Icons.list_alt, size: 14),
                        label: Text(
                          'View All ${summary.activeDevices.length} Serials',
                          style: const TextStyle(fontSize: 11),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.teal,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'No MyAdmin devices for this customer.',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            fontStyle: FontStyle.italic),
                      ),
                    ),

                  const SizedBox(height: 12),

                  // ── QB billed section (grouped by plan) ───────────
                  _SideHeader(
                    icon: Icons.receipt_long,
                    label: 'QB Billed (${summary.billedCount} devices)',
                    color: AppTheme.navyAccent,
                  ),
                  const SizedBox(height: 6),
                  if (summary.qbLines.isNotEmpty)
                    _PlanGroupTable(summary: summary)
                  else
                    const Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        'No QB invoice lines for this customer.',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            fontStyle: FontStyle.italic),
                      ),
                    ),

                  // Diff callout
                  if (summary.status != VerifyStatus.match) ...[
                    const SizedBox(height: 10),
                    _DiffCallout(summary: summary),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Full serial-number list dialog with CSV download.
  void _showAllSerials(BuildContext context) {
    final devices = summary.activeDevices;
    final serials = devices.map((d) => d.serialNumber).toList()..sort();

    showDialog(
      context: context,
      builder: (_) => _SerialListDialog(
        customerName: summary.customerName,
        devices: devices,
        serials: serials,
      ),
    );
  }
}

// ── Serial List Dialog ────────────────────────────────────────────────────────

class _SerialListDialog extends StatelessWidget {
  final String customerName;
  final List<MyAdminDevice> devices;
  final List<String> serials;

  const _SerialListDialog({
    required this.customerName,
    required this.devices,
    required this.serials,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.list_alt, size: 18, color: AppTheme.tealLight),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customerName,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                        Text(
                          '${serials.length} active device${serials.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.tealLight),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            // ── Serial list ───────────────────────────────────────────
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: serials.length,
                itemBuilder: (ctx, i) {
                  final d = devices.firstWhere(
                      (dev) => dev.serialNumber == serials[i],
                      orElse: () => devices[i]);
                  final plan = d.billingPlan
                      .replaceAll(' Mode: Live', '')
                      .replaceAll(' Mode:', '')
                      .replaceAll(': Live', '');
                  final badge = statusBadge(d.billingStatus);
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    color: i.isEven
                        ? Colors.transparent
                        : AppTheme.navyDark.withValues(alpha: 0.03),
                    child: Row(
                      children: [
                        Text(
                          '${i + 1}.',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          flex: 2,
                          child: Text(
                            serials[i],
                            style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: AppTheme.textPrimary),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            plan,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Camera sub-type chip (Go Focus / Go Focus Plus)
                        if (d.isCamera && d.cameraType.isNotEmpty) ...[
                          const SizedBox(width: 3),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            margin: const EdgeInsets.only(right: 2),
                            decoration: BoxDecoration(
                              color: d.isGoFocusPlus
                                  ? Colors.deepPurple.withValues(alpha: 0.15)
                                  : Colors.indigo.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: d.isGoFocusPlus
                                    ? Colors.deepPurple.withValues(alpha: 0.45)
                                    : Colors.indigo.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Text(
                              d.isGoFocusPlus ? 'GF+' : 'GF',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                                color: d.isGoFocusPlus
                                    ? Colors.deepPurple
                                    : Colors.indigo,
                              ),
                            ),
                          ),
                        ],
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color: badge.color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: badge.color.withValues(alpha: 0.4)),
                            ),
                            child: Text(badge.label,
                                style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w700,
                                    color: badge.color)),
                          ),
                        SizedBox(
                          width: 60,
                          child: Text(
                            d.ratePlanCode,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // ── Actions ───────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(12)),
                border: Border(top: BorderSide(color: AppTheme.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copySerials(context),
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy List',
                          style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.tealLight,
                        side: const BorderSide(color: AppTheme.teal),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _downloadCsv(context),
                      icon: const Icon(Icons.download, size: 14),
                      label: const Text('Download CSV',
                          style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copySerials(BuildContext context) {
    final text = serials.join('\n');
    _clipboardWrite(text).then((_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${serials.length} serial numbers copied to clipboard'),
            backgroundColor: AppTheme.teal,
          ),
        );
      }
    });
  }

  void _downloadCsv(BuildContext context) {
    // Build CSV with header — includes Status column so N/A devices are flagged
    final buf = StringBuffer();
    buf.writeln('Serial Number,Plan,Rate Plan Code,Status,Customer');
    for (final d in devices) {
      final plan = d.billingPlan
          .replaceAll(' Mode: Live', '')
          .replaceAll(': Live', '');
      final cleanCustomer =
          _stripParenSuffix(_stripCurlyBraceSuffix(d.customer));
      buf.writeln(
          '"${d.serialNumber}","$plan","${d.ratePlanCode}","${d.billingStatus}","$cleanCustomer"');
    }
    _downloadText(buf.toString(),
        '${customerName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}_serials.csv');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${serials.length} devices exported to CSV'),
        backgroundColor: AppTheme.teal,
      ),
    );
  }
}

// ── Platform helpers for clipboard/download ───────────────────────────────────

/// Copy [text] to the clipboard (works on web + mobile/desktop).
Future<void> _clipboardWrite(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}

/// Trigger a browser file download via a data URI (web only).
void _downloadText(String content, String filename) {
  try {
    final uri = 'data:text/csv;charset=utf-8,${Uri.encodeComponent(content)}';
    // Use dart:js to call window.open / anchor click on web
    js.context.callMethod('eval', [
      '''
      (function(){
        var a = document.createElement('a');
        a.href = '$uri';
        a.download = '${filename.replaceAll("'", "\\'")}';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
      })();
      '''
    ]);
  } catch (e) {
    // Non-web platform: silently ignore
  }
}

// ── Plan Group Table (QB side, grouped by plan) ───────────────────────────────

class _PlanGroupTable extends StatelessWidget {
  final QbCustomerSummary summary;
  const _PlanGroupTable({required this.summary});

  @override
  Widget build(BuildContext context) {
    final byPlan = summary.linesByPlan;
    // Sort plans: alphabetical, but 'Suspend' at bottom and never-activated-related last.
    final plans = byPlan.keys.toList()
      ..sort((a, b) {
        int planRank(String p) {
          final pl = p.toLowerCase();
          if (pl.contains('suspend')) return 2;
          if (pl.contains('never') || pl.contains('n/a')) return 3;
          return 0;
        }
        final ra = planRank(a);
        final rb = planRank(b);
        if (ra != rb) return ra - rb;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
            color: AppTheme.navyAccent.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: const Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text('Plan',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 44,
                    child: Text('Qty',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 56,
                    child: Text('Rate',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
                SizedBox(
                    width: 64,
                    child: Text('Amount',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70))),
              ],
            ),
          ),
          // One row per plan group
          ...plans.asMap().entries.map((e) {
            final odd   = e.key.isOdd;
            final plan  = e.value;
            final lines = byPlan[plan]!;
            // Sum qty and amount across all lines for this plan
            final totalQty = lines.fold(0.0, (s, l) => s + l.qty);
            final totalAmt = lines.fold(0.0, (s, l) => s + l.amount);
            // Use first line's unit price as representative rate
            final rate = lines.first.unitPrice;

            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: odd
                  ? Colors.transparent
                  : AppTheme.navyDark.withValues(alpha: 0.03),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(plan,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary),
                        overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      totalQty == totalQty.roundToDouble()
                          ? totalQty.toInt().toString()
                          : totalQty.toStringAsFixed(1),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.navyAccent),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      rate > 0 ? Formatters.currency(rate) : '—',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      Formatters.currency(totalAmt),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            );
          }),
          // Total row if multiple plans
          if (plans.length > 1)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(7)),
                border:
                    Border(top: BorderSide(color: AppTheme.divider)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    flex: 3,
                    child: Text('TOTAL',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white54)),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      summary.billedCount.toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.navyAccent),
                    ),
                  ),
                  const SizedBox(width: 56),
                  SizedBox(
                    width: 64,
                    child: Text(
                      Formatters.currency(summary.totalBilled),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Device header label helper ────────────────────────────────────────────────

/// Build the label for the MyAdmin devices section header, including
/// CUA, camera/geotab split, unknown, and Hanover-excluded counts where relevant.
String _buildDeviceHeaderLabel(QbCustomerSummary s) {
  final parts = <String>[];

  // Show GPS + Camera split when both present; otherwise just total
  if (s.cameraCount > 0 && s.geotabCount > 0) {
    parts.add('${s.geotabCount} GPS');
    // Camera sub-type breakdown if GF/GE known
    if (s.goFocusCount > 0 && s.goFocusPlusCount > 0) {
      parts.add('${s.goFocusCount} GF + ${s.goFocusPlusCount} GF+ cameras');
    } else if (s.goFocusCount > 0) {
      parts.add('${s.goFocusCount} GF cameras');
    } else if (s.goFocusPlusCount > 0) {
      parts.add('${s.goFocusPlusCount} GF+ cameras');
    } else {
      parts.add('${s.cameraCount} cameras');
    }
  } else if (s.cameraCount > 0) {
    // Camera-only customer
    if (s.goFocusCount > 0 && s.goFocusPlusCount > 0) {
      parts.add('${s.goFocusCount} GF + ${s.goFocusPlusCount} GF+ cameras');
    } else if (s.goFocusCount > 0) {
      parts.add('${s.goFocusCount} GF cameras');
    } else if (s.goFocusPlusCount > 0) {
      parts.add('${s.goFocusPlusCount} GF+ cameras');
    } else {
      parts.add('${s.cameraCount} cameras');
    }
  } else {
    parts.add('${s.activeCount} billable');
  }
  if (s.hanoverCount > 0) {
    parts.add('${s.hanoverCount} Hanover-direct');
  }
  if (s.hanoverCsQty > 0) {
    parts.add('${s.hanoverCsQty} Hanover-CS');
  }
  if (s.unknownCount > 0) {
    parts.add('${s.unknownCount} unknown');
  }
  return 'MyAdmin Devices (${parts.join(' + ')})';
}

// ── Hanover callout banner ────────────────────────────────────────────────────

/// Shown whenever a customer has devices on the Hanover Insurance rate plan.
/// Explains the direct-bill vs cost-share split.
class _HanoverCallout extends StatelessWidget {
  final QbCustomerSummary summary;
  const _HanoverCallout({required this.summary});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];

    if (summary.hanoverCount > 0) {
      lines.add(
        '${summary.hanoverCount} device${summary.hanoverCount == 1 ? '' : 's'} '
        'billed directly to Hanover Insurance — excluded from this customer\'s count.',
      );
    }
    if (summary.hanoverCsQty > 0) {
      lines.add(
        '${summary.hanoverCsQty} HANOVER-CS (Cost Share): customer pays half, '
        'Hanover Insurance pays half — included in billable count.',
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.teal.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.teal.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, size: 15, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Hanover Insurance Rate Plan',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.teal,
                  ),
                ),
                const SizedBox(height: 3),
                ...lines.map(
                  (l) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l,
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textSecondary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Device Table (MyAdmin side) ───────────────────────────────────────────────

/// Sort rank for billing status within the device table.
/// Lower = shown earlier.
/// Active devices first, then other plans alphabetically, then Suspended, then Never Activated.
int _statusSortRank(String billingStatus) {
  switch (billingStatus.toLowerCase()) {
    case 'active':          return 0;
    case 'suspended':       return 2;
    case 'never activated':
    case 'never billed': return 3;
    case 'unknown':         return 4;
    default:                return 1;
  }
}

class _DeviceTable extends StatelessWidget {
  final List<MyAdminDevice> devices;
  const _DeviceTable({required this.devices});

  @override
  Widget build(BuildContext context) {
    // Sort: active devices alphabetically by plan first, then by plan for other
    // statuses, but always put Suspended at the bottom and Never Activated last.
    final sorted = [...devices]..sort((a, b) {
        final rankA = _statusSortRank(a.billingStatus);
        final rankB = _statusSortRank(b.billingStatus);
        if (rankA != rankB) return rankA - rankB;
        // Within same status group: sort alphabetically by billing plan
        final planCmp = a.billingPlan.toLowerCase().compareTo(b.billingPlan.toLowerCase());
        if (planCmp != 0) return planCmp;
        return a.serialNumber.compareTo(b.serialNumber);
      });

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.teal.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: const Row(
              children: [
                Expanded(
                    flex: 2,
                    child: Text('Serial #',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.tealLight))),
                Expanded(
                    flex: 3,
                    child: Text('Plan',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.tealLight))),
                SizedBox(
                    width: 50,
                    child: Text('RPC',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.tealLight))),
              ],
            ),
          ),
          // Rows (cap at 20 for performance — use View All for the rest)
          ...sorted.take(20).toList().asMap().entries.map((e) {
            final odd = e.key.isOdd;
            final d   = e.value;
            final plan = d.billingPlan
                .replaceAll(' Mode: Live', '')
                .replaceAll(' Mode:', '')
                .replaceAll(': Live', '');
            final badge = statusBadge(d.billingStatus);
            // Hanover-plan rows get a distinct teal-tinted background
            final isHanover = d.isHanover;
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: isHanover
                  ? Colors.teal.withValues(alpha: 0.08)
                  : odd
                      ? Colors.transparent
                      : AppTheme.teal.withValues(alpha: 0.03),
              child: Row(
                children: [
                  Expanded(
                      flex: 2,
                      child: Text(d.serialNumber,
                          style: const TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: AppTheme.textPrimary))),
                  Expanded(
                      flex: 3,
                      child: Text(plan,
                          style: const TextStyle(
                              fontSize: 10,
                              color: AppTheme.textSecondary),
                          overflow: TextOverflow.ellipsis)),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 1),
                      margin: const EdgeInsets.only(right: 2),
                      decoration: BoxDecoration(
                        color: badge.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: badge.color.withValues(alpha: 0.35)),
                      ),
                      child: Text(badge.label,
                          style: TextStyle(
                              fontSize: 7,
                              fontWeight: FontWeight.w700,
                              color: badge.color)),
                    ),
                  SizedBox(
                    width: 50,
                    child: isHanover
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.teal.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                  color: Colors.teal.withValues(alpha: 0.5)),
                            ),
                            child: Text(
                              d.ratePlanCode,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.teal),
                              overflow: TextOverflow.ellipsis,
                            ),
                          )
                        : Text(d.ratePlanCode,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            );
          }),
          if (sorted.length > 20)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '… and ${sorted.length - 20} more — tap View All',
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Diff Callout ──────────────────────────────────────────────────────────────

class _DiffCallout extends StatelessWidget {
  final QbCustomerSummary summary;
  const _DiffCallout({required this.summary});

  @override
  Widget build(BuildContext context) {
    String msg;
    Color color;
    IconData icon;

    final unknownNote = summary.unknownCount > 0
        ? ' (${summary.unknownCount} Unknown-status device'
          '${summary.unknownCount == 1 ? '' : 's'} shown in list, excluded from billing count.)'
        : '';

    switch (summary.status) {
      case VerifyStatus.overbilled:
        color = AppTheme.amber;
        icon  = Icons.warning_amber;
        msg   = '${summary.billedCount} billed vs ${summary.activeCount} billable in MyAdmin — '
                '${summary.diff} extra line${summary.diff == 1 ? '' : 's'} in QB. '
                'Possible duplicate invoice or closed device still being billed.$unknownNote';
        break;
      case VerifyStatus.underbilled:
        color = AppTheme.red;
        icon  = Icons.error;
        msg   = '${summary.activeCount} billable in MyAdmin vs ${summary.billedCount} billed — '
                '${-summary.diff} device${-summary.diff == 1 ? '' : 's'} not fully invoiced. '
                'Revenue leak — add missing line items to QB invoice.$unknownNote';
        break;
      case VerifyStatus.activeOnly:
        color = AppTheme.red;
        icon  = Icons.money_off;
        msg   = '${summary.activeCount} billable device${summary.activeCount == 1 ? '' : 's'} '
                'in MyAdmin with NO QB invoice. '
                'This customer is not being billed at all.$unknownNote';
        break;
      case VerifyStatus.qbOnly:
        color = Colors.grey;
        icon  = Icons.help_outline;
        msg   = '${summary.billedCount} QB line${summary.billedCount == 1 ? '' : 's'} '
                'but no active devices in MyAdmin. '
                'Account may be closed — verify before sending invoice.';
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg,
                style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

// ── Summary Footer ────────────────────────────────────────────────────────────

class _SummaryFooter extends StatelessWidget {
  final List<QbCustomerSummary> summaries;
  const _SummaryFooter({required this.summaries});

  @override
  Widget build(BuildContext context) {
    final total       = summaries.length;
    final issues      = summaries
        .where((s) =>
            s.status == VerifyStatus.overbilled ||
            s.status == VerifyStatus.underbilled)
        .length;
    final notBilled   = summaries
        .where((s) => s.status == VerifyStatus.activeOnly)
        .length;
    final totalBilled   = summaries.fold(0.0, (s, c) => s + c.totalBilled);
    final totalActive   = summaries.fold(0, (s, c) => s + c.activeCount);
    final totalCameras  = summaries.fold(0, (s, c) => s + c.cameraCount);
    final totalUnknown  = summaries.fold(0, (s, c) => s + c.unknownCount);
    final totalHanover  = summaries.fold(0, (s, c) => s + c.hanoverCount);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: AppTheme.navyDark,
        border: Border(top: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('$total customers',
              style:
                  const TextStyle(fontSize: 11, color: Colors.white54)),
          Text('$totalActive billable',
              style:
                  const TextStyle(fontSize: 11, color: AppTheme.tealLight)),
          if (totalCameras > 0)
            Text('$totalCameras cameras',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.indigo)),
          if (totalUnknown > 0)
            Text('$totalUnknown unknown',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey)),
          if (totalHanover > 0)
            Text('$totalHanover Hanover-direct',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.teal)),
          if (issues > 0)
            Text('$issues issue${issues > 1 ? 's' : ''}',
                style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.amber,
                    fontWeight: FontWeight.w600)),
          if (notBilled > 0)
            Text('$notBilled unbilled',
                style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.red,
                    fontWeight: FontWeight.w600)),
          Text(
            totalBilled > 0
                ? 'QB: ${Formatters.currency(totalBilled)}'
                : 'No QB data',
            style: const TextStyle(
                fontSize: 11,
                color: Colors.white70,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Small Helpers ─────────────────────────────────────────────────────────────

class _SideHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _SideHeader(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ),
      ],
    );
  }
}

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MiniChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _CountBadge(this.count, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Text('$count',
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }
}
