// Predictive Coach PDF Invoice Service
//
// Parses a Predictive Coach "AR Invoice Form" PDF (INV-xxxx) to extract
// the per-customer billable unit count.  Mirrors the pattern used by
// RoscoPdfService so the rest of the app can treat both identically.
//
// Known SKU in QB CSV (column P):
//   "Predictive Coach:Predictive Coach Service Fee"
//
// Known customers (as of initial implementation):
//   PDF name                  → QB normalised key
//   "Tidy Services"           → "tidy services"
//   "Enterprise Electrical"   → "cmj technologies"  (alias)
//
// The alias table below mirrors the alias logic in qb_invoice_screen.dart
// so that _normKey() produces the same keys as the QB CSV parser.

class PredictiveCoachService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  PredictiveCoachService._();
  static final PredictiveCoachService _instance = PredictiveCoachService._();
  factory PredictiveCoachService() => _instance;

  // ── Internal state ─────────────────────────────────────────────────────────
  // Map from normalised QB customer key → billable unit count from PDF.
  final Map<String, int> _counts = {};
  bool _hasData = false;
  String? _invoiceNumber;

  bool   get hasData       => _hasData;
  String? get invoiceNumber => _invoiceNumber;

  // ── Alias table ───────────────────────────────────────────────────────────
  // PDF "Ship To" name → normalised QB key.
  // Add new mappings here as new customers are added to Predictive Coach billing.
  static const Map<String, String> _aliases = {
    // "Enterprise Electrical" in PDF → "CMJ Technologies" in QB
    'enterprise electrical': 'cmj technologies',
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Count of Predictive Coach billable units for [qbCustomerName].
  /// Returns 0 if no data has been loaded or the customer is not in the invoice.
  int countFor(String qbCustomerName) {
    if (!_hasData) return 0;
    final key = _normKey(qbCustomerName);
    return _counts[key] ?? 0;
  }

  /// Import from raw PDF text (extracted via pdf.js in the browser).
  /// Returns the number of customer rows parsed.
  int importFromText(String pdfText) {
    final result = parsePredictiveCoachPdfText(pdfText);
    _counts.clear();
    _counts.addAll(result.counts);
    _invoiceNumber = result.invoiceNumber;
    _hasData = _counts.isNotEmpty;
    return _counts.length;
  }

  void clear() {
    _counts.clear();
    _hasData = false;
    _invoiceNumber = null;
  }
}

// ── Parse result ───────────────────────────────────────────────────────────

class _PcParseResult {
  final Map<String, int> counts;
  final String? invoiceNumber;
  const _PcParseResult({required this.counts, this.invoiceNumber});
}

// ── PDF parser ────────────────────────────────────────────────────────────

/// Parse raw PDF text from a Predictive Coach AR Invoice Form (INV-xxxx).
///
/// The PDF layout has a customer table with rows like:
///   "CustomerName   qty   unit price   amount"
///
/// Two-phase approach:
///   1. Extract invoice number from "Invoice#: INV-xxxx" or "Invoice #INV-xxxx"
///   2. Walk lines to find customer rows (lines that start with a name, followed
///      by a numeric quantity, unit price, and amount).
_PcParseResult parsePredictiveCoachPdfText(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // ── Phase 1: Invoice number ──────────────────────────────────────────────
  String? invoiceNumber;
  final invRe = RegExp(r'Invoice\s*#?\s*:?\s*(INV[-\s]?\d+)', caseSensitive: false);
  for (final line in lines) {
    final m = invRe.firstMatch(line);
    if (m != null) {
      invoiceNumber = m.group(1)!.replaceAll(RegExp(r'\s+'), '-').toUpperCase();
      break;
    }
  }

  // ── Phase 2: Customer table rows ─────────────────────────────────────────
  // A customer row matches: some text followed by integer qty, price, amount.
  // We look for lines containing a dollar amount pattern and work backwards
  // to extract the customer name and quantity.
  //
  // Common PDF text extraction patterns:
  //   "Tidy Services  5  $45.00  $225.00"
  //   "Enterprise Electrical 3 $45.00 $135.00"
  //   "Tidy Services\t5\t$45.00\t$225.00"
  //
  // The regex captures:
  //   group(1) = customer name (everything before the first standalone integer)
  //   group(2) = quantity
  final rowRe = RegExp(
    r"^([A-Za-z][A-Za-z0-9 &\.,'-]+?)\s+(\d+)\s+\$?[\d,]+\.?\d*\s+\$?[\d,]+\.?\d*",
  );

  // Fallback: lines where quantity appears as a standalone token after name
  final simpleRowRe = RegExp(
    r"^([A-Za-z][A-Za-z0-9 &\.,'-]+?)\s{2,}(\d+)",
  );

  final counts = <String, int>{};

  // Keywords that signal header/footer rows — skip these
  const skipKeywords = [
    'description', 'quantity', 'unit price', 'amount', 'total',
    'invoice', 'bill to', 'ship to', 'date', 'due', 'balance',
    'predictive coach', 'service fee', 'subtotal', 'tax', 'thank you',
    'page', 'customer', 'item', 'rate',
  ];

  for (final line in lines) {
    final ll = line.toLowerCase();
    if (skipKeywords.any((kw) => ll.startsWith(kw))) continue;
    if (ll.contains('service fee') || ll.contains('predictive coach')) continue;

    final m = rowRe.firstMatch(line) ?? simpleRowRe.firstMatch(line);
    if (m == null) continue;

    final rawName = m.group(1)!.trim();
    final qty     = int.tryParse(m.group(2)!.trim()) ?? 0;

    if (rawName.isEmpty || qty <= 0) continue;
    // Skip lines where the "name" looks like a number or date
    if (RegExp(r'^\d').hasMatch(rawName)) continue;

    final key = _normKey(rawName);

    // Apply alias table
    final resolvedKey = PredictiveCoachService._aliases[key] ?? key;

    counts[resolvedKey] = (counts[resolvedKey] ?? 0) + qty;
  }

  return _PcParseResult(counts: counts, invoiceNumber: invoiceNumber);
}

// ── Normalisation helper ───────────────────────────────────────────────────

/// Mirrors the _normKey() function in qb_invoice_screen.dart so that PDF
/// customer names produce the same keys as QB CSV customer names.
String _normKey(String name) {
  String s = name.toLowerCase();
  // Strip paren suffix: "Name (Location)" → "Name"
  final parenIdx = s.indexOf('(');
  if (parenIdx > 0) s = s.substring(0, parenIdx);
  // Strip curly brace suffix: "Name {Cameras}" → "Name"
  final curlyIdx = s.indexOf('{');
  if (curlyIdx > 0) s = s.substring(0, curlyIdx);
  // Strip common legal suffixes
  s = s
      .replaceAll(RegExp(r'\b(inc\.?|llc\.?|ltd\.?|corp\.?|co\.?)\b'), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ') // punctuation → space
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s;
}
