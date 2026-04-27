// Rosco PDF Service
//
// Parses the monthly Rosco AR Invoice PDF (emailed by the vendor) and builds a
// per-QB-customer billable-unit map for use in the QB Verify audit.
//
// The PDF is a multi-invoice document (all invoices in one file).  Each invoice:
//   • SOLD TO:  Blue Arrow Telematics (always — the reseller)
//   • SHIP TO:  The end-customer name (e.g. "GUILFORD EMS")
//   • Lines:    Contract rows: "N  Contract: XXXX  Billing Period: …  QTY  $PRICE  $EXT"
//               followed by a plan description line: "RoscoLive Verizon 24 mos 1GB"
//
// QB SKU mapping (column L in QB Sales CSV):
//   $15.00 / $18.00 → "Service Fee Rosco Pro - Data Limit 1GB Track & Trace + Storage + Live Streaming for DV6"
//   $18.00 (Basic)  → "Service Fee Rosco (Basic)"
//   $25.00          → "Service Fee Rosco (Pro)"
//
// Name normalisation:
//   PDF "Ship To" names are often abbreviations (e.g. "GUILFORD EMS") while QB
//   uses full names (e.g. "Guilford County Emergency Services").  The service
//   uses the same multi-pass _normKey() as the rest of the audit so fuzzy matches
//   work automatically, PLUS a hard-coded alias table for known mismatches.
//
// Special handling:
//   • SPARTAN FIRE, Baker Roofing → IGNORED (terminated/irrelevant)
//   • Wake Med EMS → terminated contract, expect 0 QB billed — show as-is
//   • Wake Med Campus Police → annual billing, may be 0 in QB
//   • Randolph County EMS → semi-annual billing, may be 0 in QB
//   • CAROLINA AIRCARE → annual billing, QB name "Carolina Air Care"
//   • WASHINGTON COUNTY → split: 1 unit → Washington/Tyrell EMS, rest → Washington/Tyrell Transport
//     (this file's WASHINGTON COUNTY has 8 units → handled by normKey matching both QB sub-accounts)
//   • Braun Industries → split: 1 → Occoquan-Woodbridge-Lorton Volunteer Fire, 1 → Duke Life Flight

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js; // ignore: deprecated_member_use
import 'dart:async';

// ── Data classes ──────────────────────────────────────────────────────────────

/// A single end-customer entry parsed from the Rosco PDF.
class RoscoInvoiceLine {
  /// PDF "Ship To" name (raw, as printed on the invoice).
  final String shipToName;

  /// Total billable unit count for this ship-to across all contracts.
  final int qty;

  /// Invoice number(s) that contribute to this entry.
  final List<String> invoiceNumbers;

  const RoscoInvoiceLine({
    required this.shipToName,
    required this.qty,
    required this.invoiceNumbers,
  });
}

/// Result of parsing the Rosco PDF.
class RoscoPdfParseResult {
  /// One entry per end-customer (Ship To) in the PDF.
  final List<RoscoInvoiceLine> lines;

  /// Total unit count across all invoices (should be 429 for the March 2026 PDF).
  final int totalQty;

  /// Human-readable summary for the import snackbar.
  final int invoiceCount;

  const RoscoPdfParseResult({
    required this.lines,
    required this.totalQty,
    required this.invoiceCount,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class RoscoPdfService {
  // Singleton
  static final RoscoPdfService _instance = RoscoPdfService._();
  factory RoscoPdfService() => _instance;
  RoscoPdfService._();

  // In-memory map: normKey(shipToName) → billable qty
  // Also tracks special splits (Braun Industries, Washington County).
  final Map<String, int> _counts = {};

  // normKey → original Ship To display name
  final Map<String, String> _displayNames = {};

  bool get hasData => _counts.isNotEmpty;

  // ── Import ────────────────────────────────────────────────────────────────

  /// Parse [pdfText] (extracted by pdf.js) and replace the current in-memory data.
  RoscoPdfParseResult importFromText(String pdfText) {
    _counts.clear();
    _displayNames.clear();

    final result = parseRoscoPdfText(pdfText);

    for (final line in result.lines) {
      final key = _normKey(line.shipToName);
      _counts[key] = (_counts[key] ?? 0) + line.qty;
      _displayNames.putIfAbsent(key, () => line.shipToName);
    }

    return result;
  }

  /// Clear all loaded data.
  void clear() {
    _counts.clear();
    _displayNames.clear();
  }

  // ── Lookup ────────────────────────────────────────────────────────────────

  /// Returns the Rosco billable unit count for a given QB customer name.
  /// Uses multi-pass normalisation + alias table so PDF abbreviations match QB names.
  int countFor(String qbCustomerName) {
    // First: try direct normKey lookup
    final key = _normKey(qbCustomerName);
    if (_counts.containsKey(key)) return _counts[key]!;

    // Second: try alias table (PDF abbreviation → QB name normalised)
    final aliasKey = _aliasNormKey(qbCustomerName);
    if (aliasKey != null && _counts.containsKey(aliasKey)) {
      return _counts[aliasKey]!;
    }

    return 0;
  }

  /// Grand total across all customers.
  int get grandTotal => _counts.values.fold(0, (s, v) => s + v);

  /// All normalised keys with non-zero counts.
  List<String> get customerKeys => _counts.keys.toList()..sort();

  /// Returns the original Ship To name for a given normKey, or null.
  String? displayNameFor(String normKey) => _displayNames[normKey];

  // ── Alias table ───────────────────────────────────────────────────────────
  //
  // Maps QB customer name variations → the normKey used in _counts.
  // Each entry is:  qbNameFragment (lowercase, no punctuation) → pdfShipToNormKey
  //
  // When the direct normKey lookup fails, we check whether any alias pattern
  // is contained in the normalised QB name.

  static const Map<String, String> _aliasPatterns = {
    // QB name                           PDF ship-to normKey
    'guilford county emergency':         'guilford ems',
    'guilford ems':                      'guilford ems',
    'modot':                             'modots',
    'modots':                            'modots',
    'stockbridge area emergency':        'stockbridge area emergency',
    'danville life saving':              'danville life saving crew',
    'wake med ems':                      'wake med ems',
    'town of apex':                      'town of apex pw',
    'apex public works':                 'town of apex pw',
    'gemma':                             'gemma',
    'fuquay varina':                     'town of fuquayvarina',
    'fuquay-varina':                     'town of fuquayvarina',
    'fabricators supply':                'fabricators supply',
    'wake med campus police':            'wake med campus police',
    'cmj':                               'cmj',
    'city of greenville':                'city of greenville sc',
    'city of lenoir':                    'city of lenoir nc',
    'dare county':                       'dare county ems',
    'washington tyrell ems':             'washingtontyrell ems',
    'washington/tyrell ems':             'washingtontyrell ems',
    'carolina air care':                 'carolina aircare',
    'carolinaaircare':                   'carolina aircare',
    'arrow security':                    'arrow security',
    'rodney':                            'rodney l aurand',
    'charleston county':                 'charleston county sc',
    'duke patient transport':            'duke patient transport',
    'first health of carolinas':         'first health of carolinas',
    'duke life flight':                  'duke life flight',
    'occoquan':                          'occoquan',
    'woodbridge lorton':                 'occoquan',
    'washington tyrell transport':       'washington county',
    'washington/tyrell transport':       'washington county',
  };

  /// Try alias-based lookup: return the normKey in _counts that best matches
  /// [qbCustomerName] via the alias table, or null if no match.
  String? _aliasNormKey(String qbCustomerName) {
    final qbNorm = _normKey(qbCustomerName)
        .replaceAll(RegExp(r"[^a-z0-9\s]"), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    for (final pattern in _aliasPatterns.keys) {
      if (qbNorm.contains(pattern.replaceAll('-', '').replaceAll('/', ' '))) {
        final target = _aliasPatterns[pattern]!;
        // Find the key in _counts that best matches the target
        for (final countKey in _counts.keys) {
          if (countKey.contains(target) || target.contains(countKey)) {
            return countKey;
          }
        }
      }
    }
    return null;
  }
}

// ── PDF Text Parser ───────────────────────────────────────────────────────────

/// Parse the text extracted from the Rosco invoice PDF by pdf.js.
///
/// Text layout (per page):
///   Line containing "Invoice #: NNNNNN"            → start new invoice
///   Line: "Blue Arrow Telematics(…) CUSTOMER NAME" → ship-to name
///   Line: "N  Contract: XXXX  Billing Period: …  QTY  $PRICE  $EXT"  → add qty
///
/// Customers to IGNORE (terminated / not relevant):
///   SPARTAN FIRE, Baker Roofing
///
/// Special splits applied AFTER parsing:
///   Braun Industries (2 units) → 1 to "Occoquan-Woodbridge-Lorton Volunteer Fire",
///                                 1 to "Duke Life Flight" (added to Duke's total)
///   WASHINGTON COUNTY (8 units) → all go to "WASHINGTON COUNTY" as-is;
///     the QB matching handles splitting across Washington/Tyrell EMS and Transport
///     because the QB parser uses normKey matching.
RoscoPdfParseResult parseRoscoPdfText(String pdfText) {
  // ── Strip X-position annotations added by pdf.js extractor ────────────────
  // Each text item is annotated as "text~~X:NNN~~" so we can detect columns.
  // We need TWO versions of each line:
  //   • clean:  annotations removed  → used for regex matching
  //   • raw:    annotations kept     → used for column detection
  final rawLines   = pdfText.split(RegExp(r'\r?\n'));
  final cleanLines = rawLines
      .map((l) => l.replaceAll(RegExp(r'~~X:\d+~~'), '').trim())
      .toList();

  // Map: shipToName → total qty (accumulate across multi-page invoices)
  final Map<String, int> qtyByShipTo = {};
  final Map<String, List<String>> invoicesByShipTo = {};

  String? currentShipTo;
  String? currentInvoiceNum;
  final Set<String> seenInvoices = {}; // deduplicate multi-page invoices
  bool _expectShipToNextLine = false;  // fallback: name on line after "Blue Arrow"

  // Customers to ignore entirely
  const ignoreNames = {'spartan fire', 'baker roofing'};

  /// Strip X-annotations from a single raw line and split into (text, x) pairs.
  List<({String text, int x})> _parseAnnotations(String raw) {
    final result = <({String text, int x})>[];
    final pattern = RegExp(r'(.*?)~~X:(\d+)~~');
    for (final m in pattern.allMatches(raw)) {
      final txt = m.group(1)!;
      final x   = int.tryParse(m.group(2)!) ?? 0;
      if (txt.isNotEmpty) result.add((text: txt, x: x));
    }
    return result;
  }

  /// Extract the right-column (ship-to) name from a line that contains X annotations.
  /// Rosco invoices: left column ends ~x=300; right column (ship-to) starts ~x=320+.
  /// We look for a text chunk whose X > midpoint of the page (~300 pts for letter).
  String? _extractRightColumn(String raw) {
    final items = _parseAnnotations(raw);
    if (items.isEmpty) return null;
    // Find items clearly in the right half (x > 280 on a ~595pt wide page)
    final rightItems = items.where((e) => e.x > 280).toList();
    if (rightItems.isEmpty) return null;
    final name = rightItems.map((e) => e.text).join(' ').trim();
    // Reject if it looks like an address / label / email
    if (name.isEmpty) return null;
    final nl = name.toLowerCase();
    if (nl.contains('@') ||
        nl.contains('http') ||
        nl == 'shipping to:' ||
        nl == 'ship to:' ||
        RegExp(r'^\d').hasMatch(name) || // starts with a digit (address line)
        name.length < 2) return null;
    return name;
  }

  for (int i = 0; i < cleanLines.length; i++) {
    final line    = cleanLines[i];
    final rawLine = rawLines[i];
    if (line.isEmpty) continue;

    // ── New invoice header ─────────────────────────────────────────────────
    // "90-21 144th Place, Jamaica, New York 11435~~X:72~~ Invoice #: 895699~~X:430~~"
    final invMatch = RegExp(r'Invoice #:\s*(\d+)').firstMatch(line);
    if (invMatch != null) {
      final invNum = invMatch.group(1)!;
      if (!seenInvoices.contains(invNum)) {
        seenInvoices.add(invNum);
        currentInvoiceNum = invNum;
        currentShipTo = null;
        _expectShipToNextLine = false;
      }
      continue;
    }

    // ── "SHIPPING TO:" label line ──────────────────────────────────────────
    // When pdf.js splits header columns onto separate Y bands we may see a
    // standalone "SHIPPING TO:" line.  The ship-to name is the right-column
    // text on the SAME line, or on the very next non-empty line.
    if (line.toUpperCase().contains('SHIPPING TO:') ||
        line.toUpperCase().contains('SHIP TO:')) {
      // Try to get name from right column of THIS line
      final rightName = _extractRightColumn(rawLine);
      if (rightName != null && rightName.toUpperCase() != 'SHIPPING TO:' &&
          rightName.toUpperCase() != 'SHIP TO:') {
        final nl = rightName.toLowerCase();
        final shouldIgnore = ignoreNames.any((ign) => nl.contains(ign));
        if (!shouldIgnore) currentShipTo = rightName;
      }
      // Either way: if we didn't get a name, look at the next line
      if (currentShipTo == null) _expectShipToNextLine = true;
      continue;
    }

    // ── Fallback: line immediately after "SHIPPING TO:" ────────────────────
    if (_expectShipToNextLine) {
      _expectShipToNextLine = false;
      final nl = line.toLowerCase();
      // Skip address-looking lines, emails, or known labels
      if (!nl.contains('@') &&
          !nl.contains('http') &&
          !RegExp(r'^\d').hasMatch(line) &&
          line.length >= 2) {
        final shouldIgnore = ignoreNames.any((ign) => nl.contains(ign));
        if (!shouldIgnore) currentShipTo = line;
      }
      continue;
    }

    // ── Ship-To: same line as "Blue Arrow Telematics" ─────────────────────
    // Case A: single line  → "Blue Arrow Telematics(Was Gps Mobil Sol) GUILFORD EMS"
    // Case B: right column → Blue Arrow text left, ship-to right (X > 280)
    if (line.contains('Blue Arrow Telematics')) {
      // Case A: name follows the closing paren on the same clean line
      final shipMatch =
          RegExp(r'Blue Arrow Telematics\([^)]*\)\s+(.+)').firstMatch(line);
      if (shipMatch != null) {
        final name = shipMatch.group(1)!.trim();
        // Strip any trailing X-annotations that leaked into clean text
        final cleanName = name.replaceAll(RegExp(r'~~X:\d+~~'), '').trim();
        if (cleanName.isNotEmpty) {
          final nl = cleanName.toLowerCase();
          final shouldIgnore = ignoreNames.any((ign) => nl.contains(ign));
          currentShipTo = shouldIgnore ? null : cleanName;
          _expectShipToNextLine = false;
          continue;
        }
      }

      // Case B: ship-to is in the right column of the annotated raw line
      final rightName = _extractRightColumn(rawLine);
      if (rightName != null) {
        final nl = rightName.toLowerCase();
        final shouldIgnore = ignoreNames.any((ign) => nl.contains(ign));
        currentShipTo = shouldIgnore ? null : rightName;
        _expectShipToNextLine = false;
      } else {
        // Case C: ship-to may be on the very next line (different Y band)
        _expectShipToNextLine = true;
      }
      continue;
    }

    // ── Contract / billing line ────────────────────────────────────────────
    // "1  Contract: 3079  Billing Period: For the Month Ending - 03/31/2026  2  $15.00  $30.00"
    if (currentShipTo != null && line.contains('Contract:')) {
      final contractMatch = RegExp(
              r'Contract:\s*\d+\s+Billing Period:.*?(\d+)\s+\$[\d.]+\s+\$[\d.]+')
          .firstMatch(line);
      if (contractMatch != null) {
        final qty = int.tryParse(contractMatch.group(1) ?? '0') ?? 0;
        if (qty > 0) {
          final shipTo = currentShipTo;
          qtyByShipTo[shipTo] = (qtyByShipTo[shipTo] ?? 0) + qty;
          if (currentInvoiceNum != null) {
            final invNum = currentInvoiceNum;
            invoicesByShipTo.putIfAbsent(shipTo, () => []);
            if (!invoicesByShipTo[shipTo]!.contains(invNum)) {
              invoicesByShipTo[shipTo]!.add(invNum);
            }
          }
        }
      }
    }
  }

  // ── Post-processing: Braun Industries split ────────────────────────────
  // Braun Industries has 2 units:
  //   1 → Occoquan-Woodbridge-Lorton Volunteer Fire
  //   1 → Duke Life Flight (add to Duke Life Flight's total)
  if (qtyByShipTo.containsKey('Braun Industries')) {
    final braunQty = qtyByShipTo['Braun Industries']!;
    // Remove Braun entirely
    qtyByShipTo.remove('Braun Industries');
    invoicesByShipTo.remove('Braun Industries');

    // Add 1 to Occoquan
    const occoquan = 'Occoquan-Woodbridge-Lorton Volunteer Fire';
    qtyByShipTo[occoquan] = (qtyByShipTo[occoquan] ?? 0) + 1;
    invoicesByShipTo.putIfAbsent(occoquan, () => []);

    // Add the remainder to Duke Life Flight
    const duke = 'DUKE LIFE FLIGHT';
    final dukeSplit = braunQty - 1;
    if (dukeSplit > 0) {
      qtyByShipTo[duke] = (qtyByShipTo[duke] ?? 0) + dukeSplit;
    }
  }

  // ── Build result lines ─────────────────────────────────────────────────
  final resultLines = qtyByShipTo.entries.map((e) {
    return RoscoInvoiceLine(
      shipToName: e.key,
      qty: e.value,
      invoiceNumbers: invoicesByShipTo[e.key] ?? [],
    );
  }).toList()
    ..sort((a, b) => a.shipToName.compareTo(b.shipToName));

  final totalQty = resultLines.fold(0, (s, l) => s + l.qty);

  return RoscoPdfParseResult(
    lines: resultLines,
    totalQty: totalQty,
    invoiceCount: seenInvoices.length,
  );
}

// ── JS interop helper: extract text from PDF bytes via pdf.js ─────────────────

/// Extract all text from a PDF given its raw bytes.
/// Uses the window.extractPdfText() function defined in index.html.
/// Returns the concatenated text of all pages, or throws on error.
Future<String> extractPdfTextFromBytes(List<int> bytes) {
  final completer = Completer<String>();

  try {
    // Convert to JS Uint8Array
    final jsBytes = js.JsObject(
      js.context['Uint8Array'] as js.JsFunction,
      [js.JsArray.from(bytes)],
    );

    final promise = js.context.callMethod('extractPdfText', [jsBytes]);

    // Handle Promise via .then()/.catch()
    (promise as js.JsObject).callMethod('then', [
      js.allowInterop((result) {
        completer.complete(result.toString());
      }),
    ]).callMethod('catch', [
      js.allowInterop((error) {
        completer.completeError('PDF extraction failed: $error');
      }),
    ]);
  } catch (e) {
    completer.completeError('PDF.js not available: $e');
  }

  return completer.future;
}

// ── Name normaliser (mirrors _normKey in qb_invoice_screen.dart) ─────────────

String _normKey(String name) {
  var s = name.trim();
  s = s.replaceAll(RegExp(r'\{[^}]*\}'), '').trim();
  s = s.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
  if (s.contains('|')) {
    s = s.split('|').last.trim();
    s = s.replaceAll(RegExp(r'[A-Z]{2}\s*-\s*\d+$'), '').trim();
  } else if (s.contains(':')) {
    s = s.split(':').last.trim();
  }
  s = s.toLowerCase();
  s = s.replaceAll('&', 'and');
  s = s.replaceAll(RegExp(r"[^a-z0-9\s]"), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  const suffixes = {
    'inc', 'llc', 'ltd', 'corp', 'co', 'company', 'group', 'enterprises',
    'enterprise', 'holdings', 'international', 'national', 'systems',
    'technologies', 'technology', 'tech', 'industries', 'industry',
    'partners', 'partnership', 'solutions', 'associates', 'consulting',
    'services', 'service', 'plc', 'lp', 'llp', 'pllc', 'lllp',
    'wholesale', 'distribution', 'logistics', 'transport', 'transportation',
  };

  bool changed = true;
  while (changed) {
    changed = false;
    for (final suffix in suffixes) {
      if (s.endsWith(' $suffix') && s.length > suffix.length + 1) {
        s = s.substring(0, s.length - suffix.length - 1).trim();
        changed = true;
      }
    }
  }

  return s;
}
