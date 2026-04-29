// Rosco PDF Service
//
// Parses the monthly Rosco AR Invoice PDF (emailed by the vendor) and builds a
// per-QB-customer billable-unit map for use in the QB Verify audit.
//
// The PDF is a multi-invoice document (all invoices in one file).  Each invoice:
//   • SOLD TO:   Blue Arrow Telematics (always the reseller — IGNORED by parser)
//   • SHIPPING TO: The end-customer name (e.g. "GUILFORD EMS") — this is the
//                  name used for QB matching.
//   • Lines:     Contract rows: "N  Contract: XXXX  Billing Period: …  QTY  $PRICE  $EXT"
//                followed by a plan description line: "RoscoLive Verizon 24 mos 1GB"
//
// Parsing strategy:
//   The parser looks ONLY at the "SHIPPING TO:" label to find the customer name.
//   The "SOLD TO:" / "Blue Arrow Telematics" side is completely ignored.
//   pdf.js annotates each text item with "~~X:NNN~~" (X position) — these are
//   stripped before regex matching.  The "SHIPPING TO:" name may appear on the
//   same line as the label or on the very next non-junk line (when pdf.js splits
//   the two-column header table across different Y bands).
//
// QB SKU mapping (column L in QB Sales CSV):
//   $15.00 / $18.00 → "Service Fee Rosco Pro - Data Limit 1GB Track & Trace + Storage + Live Streaming for DV6"
//   $18.00 (Basic)  → "Service Fee Rosco (Basic)"
//   $25.00          → "Service Fee Rosco (Pro)"
//
// Name normalisation:
//   PDF "SHIPPING TO" names are often abbreviations (e.g. "GUILFORD EMS") while
//   QB uses full names (e.g. "Guilford County Emergency Services").  The service
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

  /// Total BILLABLE unit count (excludes ignored customers: Spartan Fire, Baker Roofing).
  /// March 2026 PDF: 429 gross units − 2 ignored = 427 billable units.
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
    'town of fuquay varina':             'town of fuquayvarina',
    'town of fuquayvarina':              'town of fuquayvarina',
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
  // Each text item is annotated as "text~~X:NNN~~" — strip them for clean matching.
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

  // State machine for reading SHIPPING TO name
  // The PDF has a two-column header table:
  //   SOLD TO: Blue Arrow Telematics ...  |  SHIPPING TO: GUILFORD EMS
  // pdf.js may split these onto separate Y-band lines.
  // Strategy: when we see "SHIPPING TO:" we capture the name that follows
  // on the same line or the very next non-empty, non-junk line.
  bool expectShipToNextLine = false;

  // Customers to ignore entirely
  const ignoreNames = {'spartan fire', 'baker roofing'};

  /// Returns true if a line looks like junk to skip when reading the ship-to name.
  /// Junk = empty, email, street address, header labels, or a salesperson name.
  bool isJunkLine(String line) {
    if (line.isEmpty) return true;
    final ll = line.toLowerCase();
    if (ll.contains('@')) return true;
    if (ll.contains('http')) return true;
    if (RegExp(r'^\d').hasMatch(line)) return true; // street address / line number

    // Label-only lines (with or without spaces — pdf.js may strip spaces)
    if (RegExp(r'^(SHIPPING\s*TO:|SHIP\s*TO:|SOLD\s*TO:|SELL\s*TO:)$',
            caseSensitive: false)
        .hasMatch(line.trim())) {
      return true;
    }
    // Header keyword prefixes (also handle no-space variants)
    if (RegExp(
            r'^(sales\s*person|ship\s*date|ship\s*via|pack\s*slip)',
            caseSensitive: false)
        .hasMatch(ll)) {
      return true;
    }
    if (ll.startsWith('line') &&
        (ll.contains('part number') || ll.contains('partnumber'))) {
      return true;
    }

    const customerKeywords = {
      'EMS', 'VFD', 'FIRE', 'COUNTY', 'CITY', 'TOWN', 'POLICE', 'RESCUE',
      'TRANSPORT', 'TRANSIT', 'FLIGHT', 'AIR', 'CARE', 'HEALTH', 'MEDICAL',
      'SHERIFF', 'EMERGENCY', 'SERVICES', 'DEPT', 'DEPARTMENT', 'INC', 'LLC',
    };

    // Reject salesperson names in two forms:
    //
    // Form A — spaced:  "Ross Braddock"
    //   Exactly two space-separated words, both title-case, no customer keyword.
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length == 2 &&
        words.every((w) => RegExp(r'^[A-Z][a-z]').hasMatch(w)) &&
        !words.any((w) => customerKeywords.contains(w.toUpperCase()))) {
      return true;
    }

    // Form B — concatenated (pdfplumber strips spaces): "RossBraddock"
    //   One word that looks like two title-case words run together,
    //   e.g. matches /^[A-Z][a-z]+[A-Z][a-z]+$/ and contains no customer keyword.
    if (words.length == 1) {
      final w = words[0];
      // Must be entirely letters and match CamelCase two-word pattern
      if (RegExp(r'^[A-Z][a-z]+[A-Z][a-z]+$').hasMatch(w)) {
        // Check neither "half" is a customer keyword
        final splitMatch = RegExp(r'^([A-Z][a-z]+)([A-Z][a-z]+)$').firstMatch(w);
        if (splitMatch != null) {
          final first = splitMatch.group(1)!;
          final last  = splitMatch.group(2)!;
          if (!customerKeywords.contains(first.toUpperCase()) &&
              !customerKeywords.contains(last.toUpperCase())) {
            return true;
          }
        }
      }
    }

    return false;
  }

  /// Extract the ship-to customer name from a line that contains "Blue Arrow Telematics".
  ///
  /// pdfplumber/pdf.js collapses adjacent words without spaces, so visually
  /// two-column content becomes one run-together string:
  ///   "GUILFORDEMSBlueArrowTelematics(WasGpsMobilSol)"
  ///   "DanvilleLifeSavingCrewBlueArrowTelematics(WasGpsMobilSol)"
  ///   "Blue Arrow Telematics(...) GUILFORD EMS"  (older stream-order format)
  ///
  /// Returns the customer name, or the original line if Blue Arrow is absent.
  String extractShipToName(String line) {
    // Case 1 (Y-sorted / no-space): CUSTOMER before Blue Arrow
    // e.g. "GUILFORDEMSBlueArrowTelematics(...)"
    final mBefore = RegExp(r'^(.+?)Blue\s*Arrow\s*Telematics',
            caseSensitive: false)
        .firstMatch(line);
    if (mBefore != null) {
      var candidate = mBefore.group(1)!.trim();
      // Strip any header labels merged in ("SHIPPINGTO:", "SOLDTO:", etc.)
      candidate = candidate
          .replaceAll(RegExp(r'SHIPPING\s*TO:\s*', caseSensitive: false), '')
          .replaceAll(RegExp(r'SOLD\s*TO:[^A-Z]*', caseSensitive: false), '')
          .trim();
      if (candidate.isNotEmpty) return candidate;
    }
    // Case 2 (stream-order / spaced): CUSTOMER after Blue Arrow paren
    // e.g. "Blue Arrow Telematics(...) GUILFORD EMS"
    final mAfter = RegExp(r'Blue\s*Arrow\s*Telematics\([^)]*\)\s*(.+)',
            caseSensitive: false)
        .firstMatch(line);
    return mAfter != null ? mAfter.group(1)!.trim() : line;
  }

  for (int i = 0; i < cleanLines.length; i++) {
    final line = cleanLines[i];

    // ── New invoice header ─────────────────────────────────────────────────
    // pdf.js may emit the invoice number in several formats:
    //   (a) Number before label (Y-sorted):  "895699Invoice #: ..."
    //   (b) Number after label (stream-order): "... Invoice #: 895699"
    //   (c) Number on next line:  "Invoice #:" / "895699"
    // Match (a) and (b) with a regex that finds a 5-7 digit number on any
    // line that also contains "Invoice #:".
    // NOTE: pdfplumber/pdf.js may strip spaces: "Invoice #:" → "Invoice#:"
    //       Use regex with \s* to match both spaced and unspaced variants.
    if (RegExp(r'Invoice\s*#:', caseSensitive: false).hasMatch(line)) {
      // Extract the invoice number — always exactly 6 digits in this PDF.
      //
      // The raw line (after pdf.js strips spaces) looks like:
      //   "Invoice#:89569990-21144thPlace,Jamaica,NewYork11435"
      // where "895699" is the invoice number and "90-211..." is the street address.
      // Using \d{5,7} (old) grabs "8956999" (7 digits) because "90" from the street
      // address follows immediately. Fixed-width \d{6} takes ONLY the first 6 digits
      // and stops, correctly returning "895699".
      //
      // Pattern A (Y-sorted / no-space): digits appear after "Invoice#:"
      //   e.g. "Invoice#:895699<street>"
      // Pattern B (stream-order):        digits appear before "Invoice#:"
      //   e.g. "895699Invoice#:<street>"
      String? invNum;
      final mAfter  = RegExp(r'Invoice\s*#:\s*(\d{6})').firstMatch(line);
      final mBefore = RegExp(r'(\d{6})\s*Invoice\s*#:').firstMatch(line);
      if (mAfter != null) {
        invNum = mAfter.group(1)!;
      } else if (mBefore != null) {
        invNum = mBefore.group(1)!;
      }
      if (invNum != null) {
        if (!seenInvoices.contains(invNum)) {
          // Truly new invoice: reset ship-to so we re-read the header
          seenInvoices.add(invNum);
          currentInvoiceNum = invNum;
          currentShipTo = null;
          expectShipToNextLine = false;
        }
        // If already seen (continuation page of same invoice) keep currentShipTo
        // so contracts on page 2+ still accumulate to the same customer.
        else {
          currentInvoiceNum = invNum; // update tracking invoice# but keep shipTo
        }
        continue;
      }
      // No 6-digit number on the label line — peek at next line
      if (i + 1 < cleanLines.length) {
        final nextLine = cleanLines[i + 1];
        final numMatch = RegExp(r'^(\d{4,7})$').firstMatch(nextLine.trim());
        if (numMatch != null) {
          final inv = numMatch.group(1)!;
          if (!seenInvoices.contains(inv)) {
            seenInvoices.add(inv);
            currentInvoiceNum = inv;
            currentShipTo = null;
            expectShipToNextLine = false;
          } else {
            currentInvoiceNum = inv;
          }
        }
      }
      continue;
    }

    // ── SHIPPING TO: label ─────────────────────────────────────────────────
    // The label and name may appear on the same line:
    //   "SHIPPING TO: GUILFORD EMS"
    // Or the name may be on the very next non-junk line:
    //   "SHIPPING TO:"
    //   "GUILFORD EMS"
    // NOTE: pdfplumber/pdf.js strips spaces: "SHIPPING TO:" → "SHIPPINGTO:"
    //       Use regex with \s* to match both variants.
    //       In this Rosco PDF layout the customer name is ALWAYS on the next
    //       line (merged with "Blue Arrow Telematics(...)"), never on the
    //       same line as the label — so always set expectShipToNextLine.
    if (RegExp(r'SHIPPING\s*TO:|SHIP\s*TO:', caseSensitive: false).hasMatch(line)) {
      expectShipToNextLine = true;
      continue;
    }

    // ── Line immediately after "SHIPPING TO:" (if name wasn't on label line) ─
    if (expectShipToNextLine) {
      if (!isJunkLine(line)) {
        expectShipToNextLine = false;
        // If this line is "Blue Arrow Telematics(...) CUSTOMER NAME",
        // extract only the customer name after the closing paren.
        final name = extractShipToName(line);
        // Ignore check: compare normalised (no-space, lowercase) so that
        // space-stripped names like "SPARTANFIRE" still match "spartan fire".
        final nlNoSpace = name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
        final shouldIgnore = ignoreNames.any(
          (ign) => nlNoSpace.contains(ign.replaceAll(' ', ''))
        );
        currentShipTo = shouldIgnore ? null : name;
      }
      // if it IS junk, stay in _expectShipToNextLine=true and try the next line
      continue;
    }

    // ── Contract / billing line ────────────────────────────────────────────
    // pdf.js (browser) preserves word spaces, so lines arrive as readable text:
    //   "1 Contract: 3079 Billing Period: For the Month Ending - 03/31/2026 2 $15.00 $30.00"
    //
    // The ONLY reliable quantity method is back-calculation:
    //   qty = ceil(ext_price / unit_price)
    // Directly reading the qty digit fails because the year "2026" runs into
    // the qty digit before regex can anchor (e.g. "2026 2" → greedy reads "20262").
    // Back-calculation is immune to this and handles pro-rated partial-month
    // lines (e.g. $62.90 / $15.00 → ceil = 5).
    //
    // Price format:
    //   pdf.js  (browser app): "$15.00 $30.00"  — space between unit and ext prices
    //   pdfplumber (Python validation): "$15.00$30.00" — no space (space-stripped)
    // The regex tries the spaced variant first, then no-space as fallback, so
    // both extraction paths continue to work.
    //
    // Verified against all 82 contract lines in the March 2026 PDF: grand total
    // = 429 units, of which 2 are ignored (Spartan Fire, Baker Roofing),
    // leaving 427 billable units.
    if (currentShipTo != null &&
        RegExp(r'Contract\s*:', caseSensitive: false).hasMatch(line) &&
        // Exclude "Previous Contract #..." cross-reference lines
        !RegExp(r'Previous\s*Contract', caseSensitive: false).hasMatch(line)) {

      // Find the first $unit $ext pair on the line.
      // pdf.js (browser) preserves spaces → "$15.00 $30.00"  (space between prices)
      // pdfplumber (Python validation) strips spaces → "$15.00$30.00" (no space)
      // Try spaced variant first, then no-space variant as fallback.
      final matchPrices =
          RegExp(r'\$(\d+\.?\d*)\s+\$(\d[\d,]*\.?\d*)').firstMatch(line) ??
          RegExp(r'\$(\d+\.?\d*)\$(\d[\d,]*\.?\d*)').firstMatch(line);
      if (matchPrices != null) {
        final unit = double.tryParse(matchPrices.group(1)!.replaceAll(',', ''));
        final ext  = double.tryParse(matchPrices.group(2)!.replaceAll(',', ''));
        if (unit != null && ext != null && unit > 0) {
          final qty = (ext / unit).ceil(); // ceil handles pro-rated lines
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
  }

  // ── Post-processing: Braun Industries split ────────────────────────────
  // Braun Industries has 2 units:
  //   1 → Occoquan-Woodbridge-Lorton Volunteer Fire
  //   1 → Duke Life Flight (add to Duke Life Flight's total)
  //
  // NOTE: pdfplumber strips spaces so the key in the map may be
  //   "BraunIndustries" (no space) rather than "Braun Industries".
  //   Find the Braun key by normalised lookup.
  final braunKey = qtyByShipTo.keys.firstWhere(
    (k) => k.toLowerCase().replaceAll(RegExp(r'\s+'), '') == 'braunindustries',
    orElse: () => '',
  );
  if (braunKey.isNotEmpty) {
    final braunQty = qtyByShipTo[braunKey]!;
    qtyByShipTo.remove(braunKey);
    invoicesByShipTo.remove(braunKey);

    // Add 1 to Occoquan
    const occoquan = 'Occoquan-Woodbridge-Lorton Volunteer Fire';
    qtyByShipTo[occoquan] = (qtyByShipTo[occoquan] ?? 0) + 1;
    invoicesByShipTo.putIfAbsent(occoquan, () => []);

    // Add the remainder to the Duke Life Flight entry already in the map.
    // The key may be "DUKELIFEFLIGHT" (space-stripped) — find it by norm.
    final dukeSplit = braunQty - 1;
    if (dukeSplit > 0) {
      final dukeKey = qtyByShipTo.keys.firstWhere(
        (k) => k.toLowerCase().replaceAll(RegExp(r'\s+'), '') == 'dukelifeflight',
        orElse: () => 'DUKE LIFE FLIGHT',
      );
      qtyByShipTo[dukeKey] = (qtyByShipTo[dukeKey] ?? 0) + dukeSplit;
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
    'inc', 'llc', 'ltd', 'corp', 'co', 'company', 'companies', 'group', 'enterprises',
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
