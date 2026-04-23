// QB Verify Screen
// Import a MyAdmin "Device Management - Full Report" CSV as the "Active" side
// and a QuickBooks "Sales by Customer Detail" CSV as the "Billed" side.
// Cross-references both to surface billing discrepancies before invoices are sent.

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js; // ignore: deprecated_member_use
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_provider.dart';
import '../services/cloud_sync_service.dart';
import '../services/csv_persist_service.dart';
import '../services/qb_customer_service.dart';
import '../services/qb_ignore_keyword_service.dart';
import '../services/plan_mapping_service.dart';
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
  final int suspendedGeotabCount;    // billable Geotab devices that are Suspended
  final int neverActivatedGeotabCount; // billable Geotab devices that are Never Activated
  // QB billed breakdown (derived from QB plan labels)
  final int qbGpsBilled;        // QB GPS/Geotab device count from billed lines
  final int qbCamBilled;        // QB Camera device count from billed lines
  final int qbSuspendedBilled;  // QB Suspended-SKU device count from billed lines
  final List<MyAdminDevice> activeDevices; // ALL devices (billable + unknown + hanover)

  /// Active (not suspended, not N/A) billable Geotab devices grouped by short plan label.
  /// e.g. {"GO": 28, "ProPlus": 6, "Pro": 3}
  /// Used to show a plan breakdown in the billing compare card.
  final Map<String, int> activePlanCounts;

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
    this.suspendedGeotabCount = 0,
    this.neverActivatedGeotabCount = 0,
    this.qbGpsBilled = 0,
    this.qbCamBilled = 0,
    this.qbSuspendedBilled = 0,
    required this.activeDevices,
    this.activePlanCounts = const {},
    this.isCua = false,
    this.jobType = '',
  });

  /// Billing comparison uses only billable devices (Active/Suspended/Never Activated).
  /// Unknown devices are visible in the list but excluded from the diff calculation.
  /// Standard is the default for all customers — CUA is set only via QB Customer List
  /// or a manual per-session override on the card.
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
      // Strip QB parent prefix for display:
      //   Colon format "Parent:Child" → keep Child
      //   Pipe format  "Parent | Location ST - 0140" → strip " ST - NNNN" store suffix
      String cleanDisplayName;
      final colonIdx = nameCell.indexOf(':');
      if (colonIdx > 0 && colonIdx < nameCell.length - 1) {
        cleanDisplayName = nameCell.substring(colonIdx + 1).trim();
      } else if (nameCell.contains(' | ')) {
        // Strip trailing " ST - NNNN" or " - NNNN" store-number suffix
        cleanDisplayName = nameCell
            .replaceFirst(RegExp(r'\s+[A-Z]{2}\s+-\s+\d+$'), '')
            .replaceFirst(RegExp(r'\s+-\s+\d+$'), '')
            .trim();
      } else {
        cleanDisplayName = nameCell;
      }
      displayNames.putIfAbsent(currentCustomerKey, () => cleanDisplayName);
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
        !isCameraSkuItem) { continue; }

    // Skip credit card fees, shipping, early termination, etc. (hard-coded safety net)
    if (itemLower.contains('credit card') ||
        itemLower.contains('shipping') ||
        itemLower.contains('early term') ||
        itemLower.contains('mkt-fee')) { continue; }

    // Qty column R — number of devices billed on this line
    final qtyRaw = gc(qtyIdx).replaceAll(',', '');
    final qty    = double.tryParse(qtyRaw) ?? 0.0;
    if (qty <= 0) { continue; } // skip lines with no devices

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

  // ── Phillips Connect ─────────────────────────────────────────────────────
  // Phillips Connect Service SKU in QB corresponds to EG-prefix devices in MyAdmin
  if (lower.contains('phillips connect') || lower.contains('phillips-connect') ||
      lower.contains('phillipsconnect')) { return 'Phillips Connect'; }

  // ── Camera product lines ──────────────────────────────────────────────────
  // Surfsight / SS camera lines
  if (lower.contains('surfsight') || lower.contains('ss service') ||
      lower.contains('ss camera')) { return 'Surfsight'; }

  // Go Focus Plus must be checked before Go Focus (longer match wins)
  if (lower.contains('go focus plus') || lower.contains('gofocus plus') ||
      lower.contains('focus plus')) { return 'Go Focus Plus'; }

  // Go Focus (standalone — not Plus)
  if (lower.contains('go focus') || lower.contains('gofocus')) { return 'Go Focus'; }

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
        il.startsWith('go')) { return 'GO'; }
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

/// Maps a raw MyAdmin billing plan string to a short QB SKU label.
/// If [serialNumber] is provided and starts with 'EG', returns 'Phillips Connect'
/// regardless of the billing plan — EG-prefix devices are Phillips Connect trackers
/// billed under the Phillips Connect Service SKU in QB.
/// Otherwise delegates to PlanMappingService (user-configurable in Settings → Plan Mapping).
String _shortPlanLabel(String billingPlan, [String serialNumber = '']) {
  if (serialNumber.toUpperCase().startsWith('EG')) return 'Phillips Connect';
  return PlanMappingService.resolve(billingPlan);
}

/// Normalise a customer name for cross-source matching.
///
/// MyAdmin can append several types of suffix that QB names never have:
///   • Parenthetical location:  "Baker Roofing (Seth Hagen Raleigh NC)" → "baker roofing"
///   • Curly-brace device type: "Acme Corp {Cameras}" → "acme corp"
///   • Dash-location suffix:    "Berrett Pest Control - Austin TX" → "berrett pest control"
///     NOTE: intentionally NOT stripped here — locations like "- Austin" are
///     valid child-account differentiators in both QB and MyAdmin.
///     They ARE stripped for the parent-child roll-up separately.
///
/// Also normalises common text differences between QB and MyAdmin:
///   • "&" ↔ "and"
///   • Legal suffix variants: LLC / L.L.C. / Ltd / Co. / Corp / Inc → stripped
///   • Extra whitespace, commas, periods
String _normKey(String name) {
  String s = name;
  // 1. Strip curly-brace device-type suffix first, e.g. " {Cameras}"
  s = _stripCurlyBraceSuffix(s);
  // 2. Strip parenthetical location/contact suffix, e.g. " (City State)"
  s = _stripParenSuffix(s);
  // 3. Strip QB parent prefix — QB exports two formats:
  //    a) Colon:  "Parent:Child"              → keep Child
  //       e.g. "Berrett Pest Control:Berrett Pest Control - Dallas"
  //            → "Berrett Pest Control - Dallas"
  //    b) Pipe:   "Parent | Location ST - NNNN" → keep "Parent | Location"
  //       QB appends a state abbreviation + store number to pipe sub-customers
  //       that MyAdmin omits.  Strip " ST - NNNN" and " - NNNN" suffixes on the
  //       right side of the pipe so both sources normalise to the same key.
  //       e.g. QB  "G&W Equipment Inc. | Charlotte NC - 0140"
  //            MA  "G&W Equipment Inc. | Charlotte"
  //            both → "g&w equipment inc | charlotte"
  if (s.contains(' | ')) {
    // Strip trailing " ST - NNNN" (state abbrev + dash + store number)
    s = s.replaceFirst(
        RegExp(r'\s+[A-Z]{2}\s+-\s+\d+$'), '');
    // Also strip a bare " - NNNN" store-number suffix without state abbrev
    s = s.replaceFirst(
        RegExp(r'\s+-\s+\d+$'), '');
  } else {
    // Colon parent prefix
    final colonIdx = s.indexOf(':');
    if (colonIdx > 0 && colonIdx < s.length - 1) {
      s = s.substring(colonIdx + 1).trim();
    }
  }
  // 4. Lowercase and collapse whitespace
  s = s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  // 5. Normalise "&" ↔ "and" so "A & B" matches "A and B"
  s = s.replaceAll(RegExp(r'\s*&\s*'), ' and ');
  // 6. Strip punctuation characters that differ between sources
  //    e.g. "Cape Fear Regional Transport, Inc." vs "Cape Fear Regional Transport Inc"
  //    Remove commas, periods, apostrophes, and backticks.
  s = s.replaceAll(RegExp(r"[,.'`]"), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  // 7. Strip trailing legal-entity suffixes that vary between QB and MyAdmin.
  //    Only strip from the last segment (after pipe if present) so company
  //    names embedded in the parent portion are preserved.
  //    Order matters: check longer patterns first (llc before lc, etc.)
  final pipeIdx = s.lastIndexOf(' | ');
  if (pipeIdx >= 0) {
    // Strip legal suffix from the child/location segment only
    final parent = s.substring(0, pipeIdx);
    var   child  = s.substring(pipeIdx + 3);
    child = child.replaceFirst(
        RegExp(
            r'\s+(llc|llc|inc|incorporated|corp|corporation|'
            r'ltd|limited|co|company|lp|llp|pllc|pc|dba)$',
            caseSensitive: false),
        '').trim();
    s = '$parent | $child';
  } else {
    s = s.replaceFirst(
        RegExp(
            r'\s+(llc|l\.?l\.?c\.?|inc\.?|incorporated|corp\.?|corporation|'
            r'ltd\.?|limited|co\.?|company|lp|l\.?p\.?|llp|pllc|pc|'
            r'dba|d\.?b\.?a\.?)$',
            caseSensitive: false),
        '').trim();
  }
  // 8. Collapse any double-spaces introduced by suffix stripping
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
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

  /// Manual CUA overrides: customerName → true (CUA) / false (Standard).
  /// Per-session CUA overrides: customerName → true (CUA) / false (Standard).
  /// Applied when the user taps the Standard/CUA toggle on any card.
  final Map<String, bool> _cuaOverrides = {};

  /// True once the user has clicked "Run Audit" — gates the results view.
  /// Resets to false whenever a new file is imported so the user must
  /// confirm the inputs before seeing fresh results.
  bool _auditRan = false;

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

    // If both files were restored from persistence the audit was already
    // confirmed in a previous session — go straight to results.
    if (mounted && _myAdminLoaded && _qbLoaded) {
      setState(() => _auditRan = true);
    }
  }

  @override
  void dispose() {
    CloudSyncService.statusNotifier.removeListener(_onSyncStatusChanged);
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Import MyAdmin (file picker) ─────────────────────────────────────────

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
      await _processMyAdminContent(content, file.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import error: $e'), backgroundColor: AppTheme.red),
      );
    }
  }

  // ── Import QB (file picker) ───────────────────────────────────────────────

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
      await _processQbContent(content, file.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import error: $e'), backgroundColor: AppTheme.red),
      );
    }
  }

  // ── Drag-and-drop entry point ─────────────────────────────────────────────
  // Called by _ImportBar when files are dropped onto either slot.
  // Auto-detects which file is MyAdmin vs QB by sniffing the CSV header, so
  // the user can drop both at once or one at a time without caring which slot.
  Future<void> _processDroppedFiles(List<DropItem> files) async {
    for (final file in files) {
      try {
        final bytes = await file.readAsBytes();
        final content = decodeBytesToString(bytes);
        final fileName = file.name.isNotEmpty ? file.name : 'dropped_file';

        // ── Auto-detect file type ────────────────────────────────────────
        // MyAdmin full report always contains "Device Status" and "Billing Plan"
        // columns in the header row; QB CSVs contain "Memo/Description" or
        // "Sales Rep".
        final firstFewLines = content.split(RegExp(r'\r?\n')).take(6).join('\n').toLowerCase();
        final isMyAdmin = firstFewLines.contains('billing plan') ||
            firstFewLines.contains('device status') ||
            firstFewLines.contains('serial number') && firstFewLines.contains('account');
        final isQb = firstFewLines.contains('memo/description') ||
            firstFewLines.contains('sales rep') ||
            firstFewLines.contains('sales by customer');

        if (!isMyAdmin && !isQb) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    'Could not detect file type for "$fileName". '
                    'Please use the MyAdmin Device Management Full Report or '
                    'QuickBooks Sales by Customer Detail CSV.'),
                backgroundColor: AppTheme.red,
              ),
            );
          }
          continue;
        }

        if (isMyAdmin) {
          await _processMyAdminContent(content, fileName);
        } else {
          await _processQbContent(content, fileName);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error reading dropped file: $e'),
              backgroundColor: AppTheme.red,
            ),
          );
        }
      }
    }
  }

  // Shared logic extracted from _importMyAdmin so drag-drop can reuse it.
  Future<void> _processMyAdminContent(String content, String fileName) async {
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

    final totalDevices = parsed.values.fold(0, (s, list) => s + list.length);
    setState(() {
      _myAdminData       = parsed;
      _myAdminLoaded     = true;
      _myAdminFileName   = fileName;
      _myAdminReportDate = reportDate;
      _expanded.clear();
      _auditRan = false;
    });

    await CsvPersistService.saveMyAdmin(
      content:    content,
      fileName:   fileName,
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
  }

  // Shared logic extracted from _importQb so drag-drop can reuse it.
  Future<void> _processQbContent(String content, String fileName) async {
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
      _qbData             = qbParsed.lines;
      _qbDisplayNameCache = qbParsed.displayNames;
      _qbLoaded           = true;
      _qbFileName         = fileName;
      _expanded.clear();
      _auditRan = false;
    });

    await CsvPersistService.saveQb(content: content, fileName: fileName);

    final totalBilled = qbParsed.lines.values
        .fold(0.0, (s, list) => s + list.fold(0.0, (s2, l) => s2 + l.qty))
        .round();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'QB: $totalBilled devices billed across ${qbParsed.lines.length} customers'),
          backgroundColor: AppTheme.teal,
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
      // Check manual overrides first, then fall back to QB Customer List.
      final manualOverride = _cuaOverrides[displayName.isEmpty ? key : displayName] ??
          _cuaOverrides[key];
      final isCua = manualOverride ??
          cuaMap[displayName] ??
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
      //   NOTE on Suspended (Geotab): Suspended devices get their own SKU line
      //   in QB (e.g. "Suspended Service Fee"), so they ARE billable for both
      //   Standard and CUA customers.  We count them here so the billable count
      //   matches what QB invoices.
      //
      // CAMERA devices ({Cameras} sub-group in MyAdmin):
      //   Standard      → Active + Never Activated  (Suspended NOT billed for cameras)
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
        // Cameras: Suspended is NOT billed (no suspended camera SKU in QB)
        return s == 'active' || s == 'never activated' || s == 'never billed';
      }).toList();

      // ── Geotab billable count ────────────────────────────────────────────
      // Suspended Geotab devices ARE billable for ALL customer types because
      // QB invoices them on a separate "Suspended Service Fee" SKU line.
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

      // Count suspended Geotab separately so we can show it in the card breakdown
      final suspendedGeotabCount = billableGeotab
          .where((d) => d.billingStatus.toLowerCase() == 'suspended')
          .length;

      // Count Never Activated separately for display
      final neverActivatedGeotabCount = billableGeotab
          .where((d) {
            final s = d.billingStatus.toLowerCase();
            return s == 'never activated' || s == 'never billed';
          }).length;

      // ── Active plan breakdown (for card display) ────────────────────────
      // Group ACTIVE (not suspended, not N/A) billable Geotab devices by
      // a short plan label so the card can show e.g. "GO 28 · ProPlus 6 · Pro 3"
      final activePlanCounts = <String, int>{};
      for (final d in billableGeotab) {
        final st = d.billingStatus.toLowerCase();
        if (st == 'active') {
          final label = _shortPlanLabel(d.billingPlan, d.serialNumber);
          activePlanCounts[label] = (activePlanCounts[label] ?? 0) + 1;
        }
      }

      // Cost-share Hanover devices count toward billable (customer pays half)
      final hanoverBillableCount = hanoverCsQty.clamp(0, hanoverDevices.length);
      final totalBillable = billableGeotab.length + billableCameras.length + hanoverBillableCount;

      final unknownDeviceCount = devices
          .where((d) => d.billingStatus.toLowerCase() == 'unknown')
          .length;

      // ── Go Focus / Go Focus Plus sub-counts ─────────────────────────────
      final goFocusCount     = billableCameras.where((d) => d.isGoFocus).length;
      final goFocusPlusCount = billableCameras.where((d) => d.isGoFocusPlus).length;

      // ── Deduplicate prorated invoices ────────────────────────────────────
      // QB exports can contain two invoices for the same customer in the same
      // month: the standard recurring invoice and a prorated invoice for devices
      // that activated mid-cycle.  Summing both would double the billed count.
      //
      // Strategy: group lines by planLabel, find the most-recent invoice date
      // per group, then keep only lines from that invoice date.  If all lines
      // share the same invoice date there is nothing to deduplicate.
      final List<QbInvoiceLine> dedupedLines;
      if (qbLines.isEmpty) {
        dedupedLines = qbLines;
      } else {
        // Collect the latest date seen for each planLabel
        final latestDateByLabel = <String, String>{};
        for (final line in qbLines) {
          final lbl = line.planLabel.isEmpty ? '__other__' : line.planLabel;
          final existing = latestDateByLabel[lbl];
          if (existing == null || _compareDates(line.date, existing) > 0) {
            latestDateByLabel[lbl] = line.date;
          }
        }
        // If every label's latest date is the same, no prorated invoice exists
        final uniqueDates = latestDateByLabel.values.toSet();
        if (uniqueDates.length == 1) {
          // All lines share one date — check whether any older-dated lines exist
          final singleDate = uniqueDates.first;
          final hasOlderLines = qbLines.any((l) => l.date != singleDate && l.date.isNotEmpty);
          if (!hasOlderLines) {
            dedupedLines = qbLines; // nothing to drop
          } else {
            // Keep only lines from the most-recent date overall
            final latestOverall = qbLines
                .map((l) => l.date)
                .where((d) => d.isNotEmpty)
                .reduce((a, b) => _compareDates(a, b) >= 0 ? a : b);
            dedupedLines = qbLines.where((l) => l.date == latestOverall || l.date.isEmpty).toList();
          }
        } else {
          // Multiple dates exist — keep each planLabel's lines from its latest date only
          dedupedLines = qbLines.where((l) {
            final lbl = l.planLabel.isEmpty ? '__other__' : l.planLabel;
            return l.date == latestDateByLabel[lbl] || l.date.isEmpty;
          }).toList();
        }
      }

      // ── QB billed breakdown by category ─────────────────────────────────
      // Derive GPS vs Camera billed counts from QB plan labels for accurate
      // side-by-side comparison on the card.
      const cameraLabels = {'Surfsight', 'Go Focus', 'Go Focus Plus', 'Smarter AI'};
      int qbGpsBilled = 0;
      int qbCamBilled = 0;
      int qbSuspendedBilled = 0;
      for (final line in dedupedLines) {
        final lbl = line.planLabel;
        final lblLower = lbl.toLowerCase();
        if (cameraLabels.contains(lbl)) {
          qbCamBilled += line.qty.round();
        } else if (lblLower.contains('suspend')) {
          qbSuspendedBilled += line.qty.round();
        } else if (lblLower != 'hanover') {
          qbGpsBilled += line.qty.round();
        }
      }

      return QbCustomerSummary(
        customerName: displayName.isEmpty ? key : displayName,
        // billedCount = sum of Qty across deduped lines only (excludes prorated invoices)
        billedCount: dedupedLines.fold(0, (s, l) => s + l.qty.round()),
        totalBilled: dedupedLines.fold(0.0, (s, l) => s + l.amount),
        qbLines: dedupedLines,
        activeCount: totalBillable,
        unknownCount: unknownDeviceCount,
        hanoverCount: hanoverExcluded,
        hanoverCsQty: hanoverBillableCount,
        cameraCount:      billableCameras.length,
        goFocusCount:     goFocusCount,
        goFocusPlusCount: goFocusPlusCount,
        geotabCount:  billableGeotab.length,
        suspendedGeotabCount: suspendedGeotabCount,
        neverActivatedGeotabCount: neverActivatedGeotabCount,
        qbGpsBilled:  qbGpsBilled,
        qbCamBilled:  qbCamBilled,
        qbSuspendedBilled: qbSuspendedBilled,
        activeDevices: devices,
        activePlanCounts: activePlanCounts,
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
            suspendedGeotabCount: existing.suspendedGeotabCount,
            neverActivatedGeotabCount: existing.neverActivatedGeotabCount,
            qbGpsBilled:  existing.qbGpsBilled,
            qbCamBilled:  existing.qbCamBilled,
            qbSuspendedBilled: existing.qbSuspendedBilled,
            activeDevices: [...existing.activeDevices, ...newDevices],
            isCua:            existing.isCua,
            jobType:          existing.jobType,
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
          suspendedGeotabCount: 0,
          neverActivatedGeotabCount: 0,
          qbGpsBilled:  qbLines.fold(0, (s, l) => s + l.qty.round()),
          qbCamBilled:  0,
          qbSuspendedBilled: 0,
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

        // Look up in parentMap.  Try three progressively-stripped variants so
        // MyAdmin name differences don't block the match:
        //   1. Full normalised name           e.g. "amanah logistics - richard cooper"
        //   2. Dash-contact stripped           e.g. "amanah logistics"
        //      (MyAdmin appends " - Contact Name"; QB name never has this)
        //   3. Legal-suffix stripped of (2)    e.g. strip trailing llc/inc etc.
        String? parentNorm = parentMap[childNorm];
        if (parentNorm == null) {
          // Strip " - Contact Name" suffix (space-dash-space + anything)
          final dashIdx = childNorm.indexOf(' - ');
          if (dashIdx > 0) {
            final dashStripped = childNorm.substring(0, dashIdx).trim();
            parentNorm = parentMap[dashStripped];
            // Also try stripping legal suffix from the dash-stripped name
            if (parentNorm == null) {
              final noLegal = dashStripped.replaceFirst(
                  RegExp(r'\s+(llc|inc\.?|corp\.?|co\.?|ltd\.?|l\.l\.c\.?)$',
                      caseSensitive: false),
                  '').trim();
              if (noLegal != dashStripped) parentNorm = parentMap[noLegal];
            }
          }
        }
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
            suspendedGeotabCount: parent.suspendedGeotabCount + child.suspendedGeotabCount,
            neverActivatedGeotabCount: parent.neverActivatedGeotabCount + child.neverActivatedGeotabCount,
            qbGpsBilled:      parent.qbGpsBilled,
            qbCamBilled:      parent.qbCamBilled,
            qbSuspendedBilled: parent.qbSuspendedBilled,
            goFocusCount:     parent.goFocusCount     + child.goFocusCount,
            goFocusPlusCount: parent.goFocusPlusCount + child.goFocusPlusCount,
            activeDevices: [...parent.activeDevices, ...child.activeDevices],
            isCua:            parent.isCua,
            jobType:          parent.jobType,
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

    // ── Pipe-format auto parent-child roll-up ─────────────────────────────
    // QuickBooks sub-customers exported with a pipe separator
    // (e.g. "G&W Equipment Inc. | Charlotte") are automatically children of
    // the part before the pipe ("G&W Equipment Inc.").  We don't require a
    // manual parentMap entry for these — detect and merge them here.
    {
      // Build a lookup of norm-key → index ONCE before the loop (O(n), not O(n²))
      final normIdx = <String, int>{};
      for (int i = 0; i < summaries.length; i++) {
        normIdx[_normKey(summaries[i].customerName)] = i;
      }

      final toRemovePipe = <int>{};

      // Collect every summary whose customerName contains ' | '
      // (after stripping device-type suffixes like {Cameras})
      for (int ci = 0; ci < summaries.length; ci++) {
        final rawName = summaries[ci].customerName;
        // Strip {Cameras} / (location) suffixes before checking for pipe
        final strippedName = _stripLocation(rawName);
        if (!strippedName.contains(' | ')) continue;

        // The parent is everything before the pipe
        final parentRaw = strippedName.substring(0, strippedName.indexOf(' | ')).trim();
        final parentNorm = _normKey(parentRaw);

        // Find the parent summary (may or may not exist yet in our list)
        // normIndex is built once before the loop (see above) so this is O(1)
        final pi = normIdx[parentNorm];
        if (pi == null || pi == ci) continue; // no matching parent row, skip

        final child  = summaries[ci];
        final parent = summaries[pi];

        // Merge child device counts into the parent
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
          suspendedGeotabCount: parent.suspendedGeotabCount + child.suspendedGeotabCount,
          neverActivatedGeotabCount: parent.neverActivatedGeotabCount + child.neverActivatedGeotabCount,
          qbGpsBilled:      parent.qbGpsBilled,
          qbCamBilled:      parent.qbCamBilled,
          qbSuspendedBilled: parent.qbSuspendedBilled,
          goFocusCount:     parent.goFocusCount     + child.goFocusCount,
          goFocusPlusCount: parent.goFocusPlusCount + child.goFocusPlusCount,
          activeDevices: [...parent.activeDevices, ...child.activeDevices],
          isCua:            parent.isCua,
          jobType:          parent.jobType,
        );

        toRemovePipe.add(ci);
      }

      for (final idx in toRemovePipe.toList().reversed) {
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

  /// Compare two QB date strings (M/D/YYYY or MM/DD/YYYY).
  /// Returns negative if [a] is earlier, 0 if equal, positive if [a] is later.
  static int _compareDates(String a, String b) {
    DateTime? parseDate(String d) {
      if (d.isEmpty) return null;
      final parts = d.split('/');
      if (parts.length != 3) return null;
      final month = int.tryParse(parts[0]);
      final day   = int.tryParse(parts[1]);
      final year  = int.tryParse(parts[2]);
      if (month == null || day == null || year == null) return null;
      return DateTime(year, month, day);
    }
    final da = parseDate(a);
    final db = parseDate(b);
    if (da == null && db == null) return 0;
    if (da == null) return -1;
    if (db == null) return 1;
    return da.compareTo(db);
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
      case 3: // QB Only — in QB but no devices in MyAdmin
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
    final bothLoaded = _myAdminLoaded && _qbLoaded;
    // Only compute summaries once the user has clicked Run Audit
    final summaries  = (_auditRan && hasAnyData) ? _buildSummaries() : <QbCustomerSummary>[];

    final issueCount   = summaries.where((s) =>
        s.status == VerifyStatus.overbilled ||
        s.status == VerifyStatus.underbilled).length;
    final activeOnlyCount = summaries
        .where((s) => s.status == VerifyStatus.activeOnly).length;
    final qbOnlyCount = summaries
        .where((s) => s.status == VerifyStatus.qbOnly).length;
    final showTabs = _auditRan && summaries.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.verified_outlined, size: 20, color: AppTheme.tealLight),
            SizedBox(width: 8),
            Text('QB Verify'),
          ],
        ),
        bottom: showTabs
            ? TabBar(
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
              )
            : null,
      ),
      body: Column(
        children: [
          // ── Import action bar (always visible) ─────────────────────────
          _ImportBar(
            myAdminLoaded:   _myAdminLoaded,
            myAdminFileName: _myAdminFileName,
            myAdminDate:     _myAdminReportDate,
            qbLoaded:        _qbLoaded,
            qbFileName:      _qbFileName,
            onImportMyAdmin: _importMyAdmin,
            onImportQb:      _importQb,
            onDropFiles:     _processDroppedFiles,
          ),

          // ── State machine: empty → ready-to-run → results ──────────────
          if (!hasAnyData)
            _EmptyState(
                onImportMyAdmin: _importMyAdmin, onImportQb: _importQb)
          else if (!_auditRan)
            _ReadyToRunScreen(
              myAdminLoaded:   _myAdminLoaded,
              myAdminFileName: _myAdminFileName,
              myAdminDate:     _myAdminReportDate,
              qbLoaded:        _qbLoaded,
              qbFileName:      _qbFileName,
              bothReady:       bothLoaded,
              onImportMyAdmin: _importMyAdmin,
              onImportQb:      _importQb,
              onRun:           () => setState(() => _auditRan = true),
            )
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
                        onCuaOverride: (isCua) => setState(() {
                          _cuaOverrides[s.customerName] = isCua;
                        }),
                      );
                    },
                  );
                }),
              ),
            ),
          ],

          // ── Summary footer (results only) ────────────────────────────────
          if (summaries.isNotEmpty)
            _SummaryFooter(summaries: summaries),
        ],
      ),
    );
  }
}

// ── Ready-to-Run Screen ───────────────────────────────────────────────────────
/// Shown after one or both files are loaded but before the user clicks Run.
/// Displays the loaded file cards and a prominent Run Audit button.
class _ReadyToRunScreen extends StatelessWidget {
  final bool myAdminLoaded;
  final String? myAdminFileName;
  final String? myAdminDate;
  final bool qbLoaded;
  final String? qbFileName;
  final bool bothReady;
  final VoidCallback onImportMyAdmin;
  final VoidCallback onImportQb;
  final VoidCallback onRun;

  const _ReadyToRunScreen({
    required this.myAdminLoaded,
    required this.myAdminFileName,
    required this.myAdminDate,
    required this.qbLoaded,
    required this.qbFileName,
    required this.bothReady,
    required this.onImportMyAdmin,
    required this.onImportQb,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title ──────────────────────────────────────────────────
            Row(
              children: [
                Icon(
                  bothReady
                      ? Icons.task_alt
                      : Icons.hourglass_top_rounded,
                  size: 22,
                  color: bothReady ? AppTheme.teal : AppTheme.amber,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bothReady
                            ? 'Ready to Run'
                            : 'Waiting for files…',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        bothReady
                            ? 'Both files loaded. Review below, then run the audit.'
                            : 'Import both files above to continue.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // ── File summary cards ──────────────────────────────────────
            _FileConfirmCard(
              step: 1,
              icon: Icons.devices,
              title: 'MyAdmin Report',
              subtitle: 'Device Management — Full Report',
              loaded: myAdminLoaded,
              fileName: myAdminFileName,
              detail: myAdminDate != null ? 'Report date: $myAdminDate' : null,
              loadedColor: AppTheme.teal,
              onReplace: onImportMyAdmin,
            ),

            const SizedBox(height: 12),

            _FileConfirmCard(
              step: 2,
              icon: Icons.receipt_long,
              title: 'QB Sales CSV',
              subtitle: 'Sales by Customer Detail',
              loaded: qbLoaded,
              fileName: qbFileName,
              detail: null,
              loadedColor: AppTheme.navyAccent,
              onReplace: onImportQb,
            ),

            const SizedBox(height: 32),

            // ── Run button ──────────────────────────────────────────────
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: bothReady ? onRun : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                label: const Text(
                  'Run Audit',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.teal.withValues(alpha: 0.25),
                  disabledForegroundColor: Colors.white38,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: bothReady ? 2 : 0,
                ),
              ),
            ),

            if (!bothReady) ...[
              const SizedBox(height: 10),
              Center(
                child: Text(
                  'Import ${!myAdminLoaded && !qbLoaded ? 'both files' : !myAdminLoaded ? 'the MyAdmin CSV' : 'the QB Sales CSV'} to enable',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Single file confirmation card used on the Ready-to-Run screen.
class _FileConfirmCard extends StatelessWidget {
  final int step;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool loaded;
  final String? fileName;
  final String? detail;
  final Color loadedColor;
  final VoidCallback onReplace;

  const _FileConfirmCard({
    required this.step,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.loaded,
    required this.fileName,
    required this.detail,
    required this.loadedColor,
    required this.onReplace,
  });

  @override
  Widget build(BuildContext context) {
    final color = loaded ? loadedColor : Colors.grey;

    return Container(
      decoration: BoxDecoration(
        color: loaded
            ? color.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: loaded
              ? color.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step badge
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: loaded
                  ? color.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.06),
              shape: BoxShape.circle,
              border: Border.all(
                  color: color.withValues(alpha: 0.4)),
            ),
            child: Center(
              child: loaded
                  ? Icon(Icons.check, size: 14, color: color)
                  : Text(
                      '$step',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color.withValues(alpha: 0.6),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),

          // Text info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 5),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: loaded ? color : AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (loaded && fileName != null) ...[
                  Text(
                    fileName!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        detail!,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                ] else
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),

          // Replace / Import button
          TextButton(
            onPressed: onReplace,
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              loaded ? 'Replace' : 'Import',
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Import Bar ────────────────────────────────────────────────────────────────

class _ImportBar extends StatefulWidget {
  final bool myAdminLoaded;
  final String? myAdminFileName;
  final String? myAdminDate;
  final bool qbLoaded;
  final String? qbFileName;
  final VoidCallback onImportMyAdmin;
  final VoidCallback onImportQb;
  final Future<void> Function(List<DropItem>) onDropFiles;

  const _ImportBar({
    required this.myAdminLoaded,
    required this.myAdminFileName,
    required this.myAdminDate,
    required this.qbLoaded,
    required this.qbFileName,
    required this.onImportMyAdmin,
    required this.onImportQb,
    required this.onDropFiles,
  });

  @override
  State<_ImportBar> createState() => _ImportBarState();
}

class _ImportBarState extends State<_ImportBar> {
  bool _myAdminHover = false;
  bool _qbHover      = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.navyDark,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          // ── MyAdmin drop slot ──────────────────────────────────────────
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _myAdminHover = true),
              onDragExited:  (_) => setState(() => _myAdminHover = false),
              onDragDone: (details) {
                setState(() => _myAdminHover = false);
                widget.onDropFiles(details.files);
              },
              child: _ImportSlot(
                icon: Icons.devices,
                label: 'MyAdmin Report',
                sublabel: widget.myAdminLoaded
                    ? (widget.myAdminDate ?? widget.myAdminFileName ?? 'Loaded')
                    : 'Drop CSV here or click to browse',
                loaded: widget.myAdminLoaded,
                color: AppTheme.teal,
                hovering: _myAdminHover,
                onTap: widget.onImportMyAdmin,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // VS divider
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
          const SizedBox(width: 8),
          // ── QB drop slot ───────────────────────────────────────────────
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _qbHover = true),
              onDragExited:  (_) => setState(() => _qbHover = false),
              onDragDone: (details) {
                setState(() => _qbHover = false);
                widget.onDropFiles(details.files);
              },
              child: _ImportSlot(
                icon: Icons.receipt_long,
                label: 'QB Sales CSV',
                sublabel: widget.qbLoaded
                    ? (widget.qbFileName ?? 'Loaded')
                    : 'Drop CSV here or click to browse',
                loaded: widget.qbLoaded,
                color: AppTheme.navyAccent,
                hovering: _qbHover,
                onTap: widget.onImportQb,
              ),
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
  final bool hovering;
  final Color color;
  final VoidCallback onTap;

  const _ImportSlot({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.loaded,
    required this.hovering,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = hovering
        ? color.withValues(alpha: 0.85)
        : loaded
            ? color.withValues(alpha: 0.4)
            : Colors.white.withValues(alpha: 0.1);
    final bgColor = hovering
        ? color.withValues(alpha: 0.18)
        : loaded
            ? color.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.04);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: borderColor,
            width: hovering ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hovering
                  ? Icons.file_download_outlined
                  : (loaded ? Icons.check_circle : icon),
              size: 18,
              color: hovering ? color : (loaded ? color : Colors.white38),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hovering ? 'Release to load' : label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: hovering
                          ? color
                          : (loaded ? color : Colors.white54),
                    ),
                  ),
                  Text(
                    sublabel,
                    style: TextStyle(
                        fontSize: 10,
                        color: hovering
                            ? color.withValues(alpha: 0.7)
                            : Colors.white38),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              hovering ? Icons.file_download_outlined : Icons.upload_file,
              size: 14,
              color: hovering
                  ? color.withValues(alpha: 0.9)
                  : (loaded ? color.withValues(alpha: 0.6) : Colors.white24),
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
  /// Called when user manually tags Standard (false) or CUA (true)
  final void Function(bool isCua)? onCuaOverride;

  const _CustomerVerifyCard({
    required this.summary,
    required this.expanded,
    required this.onToggle,
    this.onCuaOverride,
  });

  Color get _color {
    switch (summary.status) {
      case VerifyStatus.match:       return AppTheme.green;
      case VerifyStatus.overbilled:  return AppTheme.amber;
      case VerifyStatus.underbilled: return AppTheme.red;
      case VerifyStatus.qbOnly:      return Colors.grey;
      case VerifyStatus.activeOnly:  return AppTheme.red;
    }
  }

  IconData get _icon {
    switch (summary.status) {
      case VerifyStatus.match:       return Icons.check_circle;
      case VerifyStatus.overbilled:  return Icons.warning_amber;
      case VerifyStatus.underbilled: return Icons.error;
      case VerifyStatus.qbOnly:      return Icons.help_outline;
      case VerifyStatus.activeOnly:  return Icons.money_off;
    }
  }

  // Status word only — diff is already large & prominent in the compare block
  String get _label {
    switch (summary.status) {
      case VerifyStatus.match:       return 'Match';
      case VerifyStatus.overbilled:  return 'Overbilled';
      case VerifyStatus.underbilled: return 'Underbilled';
      case VerifyStatus.qbOnly:      return 'QB Only – No Devices';
      case VerifyStatus.activeOnly:  return 'Not Billed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── TOP ROW: icon · name · [tags] · status · expand ─
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(_icon, size: 20, color: _color),
                      const SizedBox(width: 9),

                      // Customer name (fills remaining space)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              summary.customerName,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Inline tags: CUA · jobType
                            if (summary.isCua || summary.jobType.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 2,
                                  children: [
                                    if (summary.isCua)
                                      _TagChip(
                                        label: 'CUA',
                                        icon: Icons.bolt,
                                        color: Colors.deepPurple,
                                      ),
                                    if (summary.jobType.isNotEmpty)
                                      _TagChip(
                                        label: summary.jobType,
                                        color: summary.isCua
                                            ? Colors.deepPurple
                                            : AppTheme.textSecondary,
                                        italic: true,
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 6),

                      // Status badge + amount stacked, then expand arrow
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Status badge + expand arrow on same line
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 9, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _color.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                      color: _color.withValues(alpha: 0.4),
                                      width: 1.5),
                                ),
                                child: Text(
                                  _label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: _color,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                                color: AppTheme.textSecondary,
                              ),
                            ],
                          ),
                          if (summary.totalBilled > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              Formatters.currency(summary.totalBilled),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),

                  // ── Alert chips (unknown / hanover) above compare row ─
                  if (summary.unknownCount > 0 || summary.hanoverCount > 0) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: [
                        if (summary.unknownCount > 0)
                          _TagChip(
                            label: '${summary.unknownCount} unknown',
                            icon: Icons.help_outline,
                            color: Colors.grey,
                          ),
                        if (summary.hanoverCount > 0)
                          _TagChip(
                            label: '${summary.hanoverCount} direct-bill',
                            icon: Icons.shield_outlined,
                            color: Colors.teal,
                          ),
                      ],
                    ),
                  ],

                  // ── Standard / CUA type toggle (shown for non-CUA cards) ─────
                  // Standard is the default. Tap CUA only for approved CUA accounts.
                  if (onCuaOverride != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => onCuaOverride!(false),
                            icon: const Icon(Icons.person, size: 14),
                            label: const Text('Standard', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.teal,
                              side: BorderSide(color: AppTheme.teal.withValues(alpha: 0.5)),
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => onCuaOverride!(true),
                            icon: const Icon(Icons.bolt, size: 14),
                            label: const Text('CUA', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.deepPurple,
                              side: BorderSide(color: Colors.deepPurple.withValues(alpha: 0.5)),
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],

                  // ── BOTTOM ROW: billing compare — full width ────────────
                  const SizedBox(height: 8),
                  _BillingCompareRow(summary: summary),
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
                    _MyAdminPlanTable(summary: summary),
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

/// Simple discriminated union for the grouped serial list:
/// either a plan-group header or a device row.
class _ListItem {
  final bool isHeader;
  final String? label;
  final int groupCount;
  final MyAdminDevice? device;

  const _ListItem._({
    required this.isHeader,
    this.label,
    this.groupCount = 0,
    this.device,
  });

  factory _ListItem.header(String label, int count) =>
      _ListItem._(isHeader: true, label: label, groupCount: count);

  factory _ListItem.device(MyAdminDevice d) =>
      _ListItem._(isHeader: false, device: d);
}

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
    // Sort: by status rank → short plan label → serial number
    // This groups all ProPlus together, then GO, etc.
    final sorted = [...devices]..sort((a, b) {
        final rankA = _statusSortRank(a.billingStatus);
        final rankB = _statusSortRank(b.billingStatus);
        if (rankA != rankB) return rankA - rankB;
        final labelA = _shortPlanLabel(a.billingPlan, a.serialNumber);
        final labelB = _shortPlanLabel(b.billingPlan, b.serialNumber);
        final planCmp = labelA.toLowerCase().compareTo(labelB.toLowerCase());
        if (planCmp != 0) return planCmp;
        return a.serialNumber.compareTo(b.serialNumber);
      });

    // Build flat list items: either a group header or a device row
    final items = <_ListItem>[];
    String? lastLabel;
    for (final d in sorted) {
      final label = _shortPlanLabel(d.billingPlan, d.serialNumber);
      if (label != lastLabel) {
        lastLabel = label;
        final groupCount = sorted
            .where((x) => _shortPlanLabel(x.billingPlan, x.serialNumber) == label &&
                _statusSortRank(x.billingStatus) == _statusSortRank(d.billingStatus))
            .length;
        items.add(_ListItem.header(label, groupCount));
      }
      items.add(_ListItem.device(d));
    }

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
                          '${devices.length} active device${devices.length == 1 ? '' : 's'}',
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

            // ── Column headers ────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              color: AppTheme.navyDark.withValues(alpha: 0.6),
              child: const Row(
                children: [
                  SizedBox(width: 22), // # column
                  Expanded(
                    flex: 5,
                    child: Text('Serial Number',
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.tealLight,
                            letterSpacing: 0.3)),
                  ),
                  SizedBox(
                    width: 50,
                    child: Text('Status',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white54,
                            letterSpacing: 0.3)),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text('RPC',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white54,
                            letterSpacing: 0.3)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppTheme.divider),

            // ── Grouped serial list ───────────────────────────────────
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 4),
                itemCount: items.length,
                itemBuilder: (ctx, i) {
                  final item = items[i];

                  // ── Plan group header ──────────────────────────────
                  if (item.isHeader) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      color: AppTheme.navyDark.withValues(alpha: 0.55),
                      child: Row(
                        children: [
                          Text(
                            item.label!,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.tealLight,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.teal.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${item.groupCount}',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.tealLight,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // ── Device row ─────────────────────────────────────
                  final d     = item.device!;
                  final badge = statusBadge(d.billingStatus);

                  // Row number among device rows only
                  final deviceIdx = items
                      .sublist(0, i)
                      .where((x) => !x.isHeader)
                      .length;

                  Color rowColor;
                  if (d.isHanover) {
                    rowColor = Colors.teal.withValues(alpha: 0.06);
                  } else if (badge?.label == 'N/A') {
                    rowColor = AppTheme.amber.withValues(alpha: 0.05);
                  } else if (badge?.label == 'SUSP') {
                    rowColor = Colors.orange.withValues(alpha: 0.05);
                  } else {
                    rowColor = deviceIdx.isEven
                        ? Colors.transparent
                        : AppTheme.navyDark.withValues(alpha: 0.03);
                  }

                  // Camera type pill
                  Widget? camPill;
                  if (d.isCamera && d.cameraType.isNotEmpty) {
                    final isPlus = d.isGoFocusPlus;
                    camPill = Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(
                        color: (isPlus ? Colors.deepPurple : Colors.indigo)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: (isPlus ? Colors.deepPurple : Colors.indigo)
                              .withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        isPlus ? 'GE' : 'GF',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: isPlus ? Colors.deepPurple : Colors.indigo,
                        ),
                      ),
                    );
                  }

                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 5),
                    color: rowColor,
                    child: Row(
                      children: [
                        // Row number
                        SizedBox(
                          width: 22,
                          child: Text(
                            '${deviceIdx + 1}.',
                            style: const TextStyle(
                                fontSize: 9, color: Colors.grey),
                          ),
                        ),
                        // Serial number
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              if (camPill != null) camPill,
                              Expanded(
                                child: Text(
                                  d.serialNumber,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: AppTheme.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Status badge
                        SizedBox(
                          width: 50,
                          child: badge != null
                              ? Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: badge.color
                                          .withValues(alpha: 0.15),
                                      borderRadius:
                                          BorderRadius.circular(4),
                                      border: Border.all(
                                          color: badge.color
                                              .withValues(alpha: 0.4)),
                                    ),
                                    child: Text(badge.label,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 8,
                                            fontWeight: FontWeight.w700,
                                            color: badge.color)),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        // RPC
                        SizedBox(
                          width: 60,
                          child: Text(
                            d.ratePlanCode,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 9,
                                color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
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

// ── MyAdmin Plan Table (MyAdmin side, grouped by plan — mirrors QB style) ─────

class _MyAdminPlanTable extends StatelessWidget {
  final QbCustomerSummary summary;
  const _MyAdminPlanTable({required this.summary});

  @override
  Widget build(BuildContext context) {
    // Build plan → count map from active billable devices only
    // (same source as activePlanCounts, but we recompute here so we can also
    //  add Suspended and N/A rows at the bottom, matching the QB table layout)
    final activeMap   = <String, int>{};
    final suspMap     = <String, int>{};
    final naMap       = <String, int>{};

    for (final d in summary.activeDevices) {
      final status = d.billingStatus.toLowerCase();
      final label  = _shortPlanLabel(d.billingPlan, d.serialNumber);
      // Camera devices appear in the CAM row, not the GPS plan table
      if (d.isCamera) continue;
      if (status == 'suspended') {
        suspMap[label] = (suspMap[label] ?? 0) + 1;
      } else if (status == 'never activated' || status == 'never billed') {
        if (!summary.isCua) {
          naMap[label] = (naMap[label] ?? 0) + 1;
        }
      } else if (status == 'active') {
        activeMap[label] = (activeMap[label] ?? 0) + 1;
      }
    }

    // Sort each group alphabetically
    List<MapEntry<String, int>> sorted(Map<String, int> m) =>
        m.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    final activeRows = sorted(activeMap);
    final suspRows   = sorted(suspMap);
    final naRows     = sorted(naMap);
    final allRows    = [...activeRows, ...suspRows, ...naRows];

    if (allRows.isEmpty) {
      return const SizedBox.shrink();
    }

    final totalQty = allRows.fold(0, (s, e) => s + e.value);

    Widget planRow(MapEntry<String, int> e, int idx, {bool isSusp = false, bool isNa = false}) {
      Color labelColor = AppTheme.textPrimary;
      if (isSusp) labelColor = Colors.orange.shade300;
      if (isNa)   labelColor = AppTheme.amber;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        color: idx.isOdd
            ? Colors.transparent
            : AppTheme.navyDark.withValues(alpha: 0.03),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                e.key,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${e.value}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.teal,
                ),
              ),
            ),
            // Spacers to mirror QB table column widths (no Rate/Amount for MyAdmin)
            const SizedBox(width: 120),
          ],
        ),
      );
    }

    int idx = 0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.teal.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: const Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text('Plan',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70)),
                ),
                SizedBox(
                  width: 44,
                  child: Text('Qty',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70)),
                ),
                SizedBox(width: 120),
              ],
            ),
          ),
          // Active rows
          ...activeRows.map((e) => planRow(e, idx++)),
          // Suspended rows (if any) — with divider
          if (suspRows.isNotEmpty) ...[
            const Divider(height: 1, color: AppTheme.divider),
            ...suspRows.map((e) => planRow(e, idx++, isSusp: true)),
          ],
          // N/A (Never Activated) rows — with divider
          if (naRows.isNotEmpty) ...[
            const Divider(height: 1, color: AppTheme.divider),
            ...naRows.map((e) => planRow(e, idx++, isNa: true)),
          ],
          // Total row if multiple plan lines
          if (allRows.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(7)),
                border: Border(top: BorderSide(color: AppTheme.divider)),
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
                      '$totalQty',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.teal),
                    ),
                  ),
                  const SizedBox(width: 120),
                ],
              ),
            ),
        ],
      ),
    );
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
                'with no matching devices in MyAdmin. '
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

  // ── Export audit results as a CSV file ────────────────────────────────────
  void _exportCsv() {
    final buf = StringBuffer();
    // Header
    buf.writeln('Customer,Status,Billable,Billed,Diff,GPS Billable,GPS Billed,'
        'CAM Billable,CAM Billed,SUSP Billable,SUSP Billed,N/A (Never Act.),'
        'CUA,Job Type,QB Total,Unknown Devices,Hanover Direct');

    for (final s in summaries) {
      String statusLabel;
      switch (s.status) {
        case VerifyStatus.match:       statusLabel = 'Match'; break;
        case VerifyStatus.overbilled:  statusLabel = 'Overbilled'; break;
        case VerifyStatus.underbilled: statusLabel = 'Underbilled'; break;
        case VerifyStatus.activeOnly:  statusLabel = 'Not Billed'; break;
        case VerifyStatus.qbOnly:      statusLabel = 'QB Only - No Devices'; break;
      }
      String csvEsc(String v) {
        if (v.contains(',') || v.contains('"') || v.contains('\n')) {
          return '"${v.replaceAll('"', '""')}"';
        }
        return v;
      }
      buf.writeln([
        csvEsc(s.customerName),
        statusLabel,
        s.activeCount,
        s.billedCount,
        s.diff,
        s.geotabCount,
        s.qbGpsBilled,
        s.cameraCount,
        s.qbCamBilled,
        s.suspendedGeotabCount,
        s.qbSuspendedBilled,
        s.neverActivatedGeotabCount,
        s.isCua ? 'CUA' : 'Standard',
        csvEsc(s.jobType),
        s.totalBilled.toStringAsFixed(2),
        s.unknownCount,
        s.hanoverCount,
      ].join(','));
    }

    final now = DateTime.now();
    final dateSuffix =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    _downloadText(buf.toString(), 'qb_audit_$dateSuffix.csv');
  }

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
          // ── Export button ─────────────────────────────────────────────
          InkWell(
            onTap: _exportCsv,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.teal.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: AppTheme.teal.withValues(alpha: 0.4)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download, size: 12, color: AppTheme.teal),
                  SizedBox(width: 4),
                  Text('Export CSV',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.teal,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
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

// ── Billing Compare Row ───────────────────────────────────────────────────────
/// Side-by-side "MyAdmin Billable" vs "QB Billed" layout.
/// Shows TOTAL | GPS | CAM | SUSP columns aligned so the user can scan
/// discrepancies at a glance without opening the expanded view.
// ── Billing Compare Row ───────────────────────────────────────────────────────
/// Horizontal table: header row (BILLABLE · diff · BILLED) then one detail
/// row per device type (GPS, Cam, Susp) — columns are aligned so values line
/// up vertically and the eye can scan down each column easily.
class _BillingCompareRow extends StatelessWidget {
  final QbCustomerSummary summary;
  const _BillingCompareRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = summary;

    // ── diff badge ──────────────────────────────────────────────────
    final Color diffColor;
    final String diffLabel;
    final IconData? diffIcon;
    if (s.status == VerifyStatus.match) {
      diffColor = AppTheme.green;
      diffLabel = '';
      diffIcon  = Icons.check;
    } else {
      final over = s.diff > 0;
      diffColor = over ? AppTheme.amber : AppTheme.red;
      diffLabel = over ? '+${s.diff}' : '${s.diff}';
      diffIcon  = null;
    }

    // ── which rows to show ──────────────────────────────────────────
    final showCam  = s.cameraCount > 0 || s.qbCamBilled > 0;
    final showSupp = s.suspendedGeotabCount > 0 || s.qbSuspendedBilled > 0;
    // N/A row: Standard customers only — CUA excludes Never Activated
    final showNa   = !s.isCua && s.neverActivatedGeotabCount > 0;

    // Camera detail suffix e.g. "55 GF12·GE3"
    String camDetail(int total, int gf, int ge) {
      if (gf > 0 && ge > 0) return '$total  GF$gf·GE$ge';
      if (gf > 0)            return '$total  GF$gf';
      if (ge > 0)            return '$total  GE$ge';
      return '$total';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [

        // ── HEADER ROW: BILLABLE  [diff badge]  BILLED ─────────────
        // Uses Expanded so both sides grow to fill the card width.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // BILLABLE side
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'BILLABLE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.teal.withValues(alpha: 0.75),
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${s.activeCount}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.teal,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),

            // Diff badge — centred, fixed width
            Container(
              width: 52,
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: diffColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: diffColor.withValues(alpha: 0.45), width: 1.5),
                ),
                child: diffIcon != null
                    ? Icon(diffIcon, size: 14, color: diffColor)
                    : Text(
                        diffLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: diffColor,
                        ),
                      ),
              ),
            ),

            // BILLED side
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'BILLED',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.navyAccent.withValues(alpha: 0.75),
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${s.billedCount}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.navyAccent,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── PLAN TABLES ─────────────────────────────────────────────
        // Side-by-side: MyAdmin plan breakdown (left) | QB billed plans (right)
        // Mirrors the QB Billed table layout for easy visual comparison.
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── LEFT: MyAdmin plan breakdown ──────────────────────
            Expanded(
              child: _CollapsedMyAdminPlanTable(summary: s),
            ),
            // ── centre gap with label pills for CAM / SUSP / N/A ──
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                if (showCam)
                  _CompareLabel(
                    icon: Icons.videocam_outlined,
                    label: 'CAM',
                    color: Colors.indigo,
                    left: camDetail(s.cameraCount, s.goFocusCount, s.goFocusPlusCount),
                    right: '${s.qbCamBilled}',
                  ),
                if (showSupp)
                  _CompareLabel(
                    icon: Icons.pause_circle_outline,
                    label: 'SUSP',
                    color: Colors.orange,
                    left: '${s.suspendedGeotabCount}',
                    right: '${s.qbSuspendedBilled}',
                  ),
                if (showNa)
                  _CompareLabel(
                    icon: Icons.new_releases_outlined,
                    label: 'N/A',
                    color: AppTheme.amber,
                    left: '${s.neverActivatedGeotabCount}',
                    right: '—',
                  ),
              ],
            ),
            // ── RIGHT: QB billed plan breakdown ───────────────────
            Expanded(
              child: _CollapsedQbPlanTable(summary: s),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Compact MyAdmin plan table for the collapsed billing-compare card ─────────
/// Shows Plan | Qty rows for all active (+ suspended + N/A) devices.
/// Mirrors the layout of _CollapsedQbPlanTable on the right side.
class _CollapsedMyAdminPlanTable extends StatelessWidget {
  final QbCustomerSummary summary;
  const _CollapsedMyAdminPlanTable({required this.summary});

  @override
  Widget build(BuildContext context) {
    final activeMap = <String, int>{};
    final suspMap   = <String, int>{};
    final naMap     = <String, int>{};

    for (final d in summary.activeDevices) {
      final status = d.billingStatus.toLowerCase();
      final label  = _shortPlanLabel(d.billingPlan, d.serialNumber);
      // skip camera devices — they appear in the CAM row, not the plan table
      if (d.isCamera) continue;
      if (status == 'active') {
        activeMap[label] = (activeMap[label] ?? 0) + 1;
      } else if (status == 'suspended') {
        suspMap[label] = (suspMap[label] ?? 0) + 1;
      } else if ((status == 'never activated' || status == 'never billed') && !summary.isCua) {
        naMap[label] = (naMap[label] ?? 0) + 1;
      }
    }

    List<MapEntry<String, int>> sorted(Map<String, int> m) =>
        m.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    final activeRows = sorted(activeMap);
    final suspRows   = sorted(suspMap);
    final naRows     = sorted(naMap);
    final allRows    = [...activeRows, ...suspRows, ...naRows];

    if (allRows.isEmpty) return const SizedBox.shrink();

    final totalQty = allRows.fold(0, (s, e) => s + e.value);

    Widget planRow(MapEntry<String, int> e, int idx,
        {bool isSusp = false, bool isNa = false}) {
      Color labelColor = AppTheme.textPrimary;
      if (isSusp) labelColor = Colors.orange.shade300;
      if (isNa)   labelColor = AppTheme.amber;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        color: idx.isOdd
            ? Colors.transparent
            : AppTheme.navyDark.withValues(alpha: 0.03),
        child: Row(
          children: [
            Expanded(
              child: Text(
                e.key,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${e.value}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.teal,
              ),
            ),
          ],
        ),
      );
    }

    int idx = 0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.teal.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: const Row(
              children: [
                Expanded(
                  child: Text('Plan',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70)),
                ),
                Text('Qty',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70)),
              ],
            ),
          ),
          // Active rows
          ...activeRows.map((e) => planRow(e, idx++)),
          // Suspended rows
          if (suspRows.isNotEmpty) ...[
            const Divider(height: 1, color: AppTheme.divider),
            ...suspRows.map((e) => planRow(e, idx++, isSusp: true)),
          ],
          // N/A rows
          if (naRows.isNotEmpty) ...[
            const Divider(height: 1, color: AppTheme.divider),
            ...naRows.map((e) => planRow(e, idx++, isNa: true)),
          ],
          // Total row
          if (allRows.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
                border: Border(top: BorderSide(color: AppTheme.divider)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('TOTAL',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white54)),
                  ),
                  Text(
                    '$totalQty',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.teal),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Compact QB plan table for the collapsed billing-compare card ──────────────
/// Shows Plan | Qty rows from the QB invoice lines.
/// Mirrors the layout of _CollapsedMyAdminPlanTable on the left side.
class _CollapsedQbPlanTable extends StatelessWidget {
  final QbCustomerSummary summary;
  const _CollapsedQbPlanTable({required this.summary});

  @override
  Widget build(BuildContext context) {
    final byPlan = summary.linesByPlan;
    if (byPlan.isEmpty) return const SizedBox.shrink();

    final plans = byPlan.keys.toList()
      ..sort((a, b) {
        int rank(String p) {
          final pl = p.toLowerCase();
          if (pl.contains('suspend')) return 2;
          if (pl.contains('never') || pl.contains('n/a')) return 3;
          return 0;
        }
        final ra = rank(a), rb = rank(b);
        if (ra != rb) return ra - rb;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    Widget planRow(String plan, int idx) {
      final lines   = byPlan[plan]!;
      final totalQty = lines.fold(0.0, (s, l) => s + l.qty);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        color: idx.isOdd
            ? Colors.transparent
            : AppTheme.navyDark.withValues(alpha: 0.03),
        child: Row(
          children: [
            Expanded(
              child: Text(
                plan,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              totalQty == totalQty.roundToDouble()
                  ? totalQty.toInt().toString()
                  : totalQty.toStringAsFixed(1),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.navyAccent,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.navyAccent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: const BoxDecoration(
              color: AppTheme.navyDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: const Row(
              children: [
                Expanded(
                  child: Text('Plan',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white70)),
                ),
                Text('Qty',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70)),
              ],
            ),
          ),
          // Plan rows
          ...plans.asMap().entries.map((e) => planRow(e.value, e.key)),
          // Total row
          if (plans.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: const BoxDecoration(
                color: AppTheme.navyDark,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
                border: Border(top: BorderSide(color: AppTheme.divider)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('TOTAL',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white54)),
                  ),
                  Text(
                    '${summary.billedCount}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.navyAccent),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Compact compare label pill (CAM / SUSP / N/A) between the two plan tables ─
/// Shows a small row: left count | icon + label | right count
/// Used between the MyAdmin and QB plan tables for non-GPS device types.
class _CompareLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final String left;
  final String right;
  const _CompareLabel({
    required this.icon,
    required this.label,
    required this.color,
    required this.left,
    required this.right,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color.withValues(alpha: 0.7)),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: color.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 4),
          Text(left,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: 0.9))),
          Text('/',
              style: TextStyle(
                  fontSize: 9, color: AppTheme.textSecondary.withValues(alpha: 0.5))),
          Text(right,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: 0.9))),
        ],
      ),
    );
  }
}

// ── Tag Chip (metadata labels) ────────────────────────────────────────────────
/// Small inline label used for CUA, jobType, unknown, Hanover badges.
class _TagChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final bool italic;

  const _TagChip({
    required this.label,
    required this.color,
    this.icon,
    this.italic = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9, color: color.withValues(alpha: 0.8)),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: color.withValues(alpha: 0.85),
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            ),
          ),
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
