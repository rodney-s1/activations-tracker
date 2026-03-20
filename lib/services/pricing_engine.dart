// 3-Tier Pricing Engine
//
// Resolution order for a given device:
//   Tier 0 — Rate Plan Overrides  (customer name + plan substring → exact cost + price)
//   Tier 1 — Customer Plan Codes  (customer name + plan code → customer price)
//   Tier 2 — Standard Plan Rates  (keyword match on rate plan name → your cost)
//   Tier 3 — CSV fallback
//
// Rate Plan Overrides take highest priority — they let you set both "your cost"
// and "customer price" for a specific customer + rate-plan combination,
// bypassing all other tiers entirely.
//
// requiredRpc: if set on a CustomerPlanCode, the discounted price only applies
// when the device's Rate Plan column contains that RPC substring (case-insensitive).
// If the device is MISSING that RPC, the device is flagged and billed at full price.
//
// "Missing code" flag: if a customer has ANY CustomerPlanCode entries AND
// none of them match a device's rate plan, that device is flagged so you
// know to add/fix the special code in MyAdmin.

import '../models/activation_record.dart';
import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';
import '../models/customer_rate_plan_override.dart';

enum PriceSource { ratePlanOverride, customerCode, standardPlan, csvFallback }

class PriceResult {
  final double yourCost;       // what Geotab charges you (used for proration math)
  final double customerPrice;  // what YOU charge the customer
  final PriceSource source;
  final String matchedRule;    // human-readable description of what matched
  final bool missingCode;      // true when customer has codes but none matched
  final bool missingRpc;       // true when plan code matched but requiredRpc is absent

  const PriceResult({
    required this.yourCost,
    required this.customerPrice,
    required this.source,
    required this.matchedRule,
    this.missingCode = false,
    this.missingRpc = false,
  });
}

class PricingEngine {
  final List<StandardPlanRate> standardRates;
  final List<CustomerPlanCode> customerCodes;
  final List<CustomerRatePlanOverride> ratePlanOverrides;

  PricingEngine({
    required this.standardRates,
    required this.customerCodes,
    this.ratePlanOverrides = const [],
  });

  /// Resolve pricing for a single device record.
  PriceResult resolve(ActivationRecord record) {
    // Strip everything from the first `{` or `|` in the customer name so that
    // names like "ACME Corp {12345}" or "ACME Corp | Branch" match the override
    // rule stored as "ACME Corp".
    final rawCustomer = record.customer.trim();
    final cleanCustomer = _stripCustomerSuffix(rawCustomer);
    final customerNameNorm = cleanCustomer.toLowerCase();
    final ratePlanNorm = record.ratePlan.trim().toLowerCase();

    // ── Tier 0: Rate Plan Overrides (highest priority) ────────────
    // Matches customer name (exact, after stripping) + rate plan substring.
    if (ratePlanOverrides.isNotEmpty) {
      for (final ov in ratePlanOverrides) {
        final ovCustomerNorm = _stripCustomerSuffix(ov.customerName.trim()).toLowerCase();
        final ovPlanNorm = ov.ratePlan.trim().toLowerCase();
        final nameMatches = ovCustomerNorm == customerNameNorm;
        final planMatches = ovPlanNorm.isNotEmpty && ratePlanNorm.contains(ovPlanNorm);

        if (nameMatches && planMatches) {
          // Use override yourCost if set (> 0), else fall back to standard cost
          final stdCost = _resolveStandardCost(ratePlanNorm, record.monthlyCost);
          final resolvedCost = (ov.yourCost > 0) ? ov.yourCost : stdCost;
          return PriceResult(
            yourCost: resolvedCost,
            customerPrice: ov.customerPrice,
            source: PriceSource.ratePlanOverride,
            matchedRule: 'Rate plan override: "${ov.ratePlan}"'
                '${ov.notes.isNotEmpty ? ' (${ov.notes})' : ''}',
          );
        }
      }
    }

    // ── Tier 1: Customer-specific plan codes ─────────────────────
    final customerSpecificCodes = customerCodes
        .where((c) =>
            c.customerName.trim().toLowerCase() == customerNameNorm)
        .toList();

    if (customerSpecificCodes.isNotEmpty) {
      // Try to find a matching code
      CustomerPlanCode? matched;
      for (final code in customerSpecificCodes) {
        final codeNorm = code.planCode.trim().toLowerCase();
        if (codeNorm.isNotEmpty && ratePlanNorm.contains(codeNorm)) {
          matched = code;
          break;
        }
      }

      if (matched != null) {
        final stdCost = _resolveStandardCost(ratePlanNorm, record.monthlyCost);

        // ── Check requiredRpc ────────────────────────────────────────────
        final rpcRequired = matched.requiredRpc.trim();
        if (rpcRequired.isNotEmpty &&
            !ratePlanNorm.contains(rpcRequired.toLowerCase())) {
          return PriceResult(
            yourCost: stdCost,
            customerPrice: stdCost, // can't give discount — RPC missing
            source: PriceSource.standardPlan,
            matchedRule:
                'MISSING RPC "${matched.requiredRpc}" — device not on discounted plan; billed at full rate',
            missingRpc: true,
          );
        }

        // RPC present (or not required) — apply customer price
        return PriceResult(
          yourCost: stdCost,
          customerPrice: matched.customerPrice,
          source: PriceSource.customerCode,
          matchedRule: 'Customer code: "${matched.planCode}"'
              '${rpcRequired.isNotEmpty ? ' (RPC: $rpcRequired ✓)' : ''}',
        );
      } else {
        // Customer has codes configured but NONE matched this particular plan.
        //
        // Only raise the missingCode flag when there is NO standard rate covering
        // this plan either — i.e., pricing would genuinely fall through to the
        // raw CSV value.  If a standard rate DOES match, the device is priced
        // correctly; the warning would just be noise (and confusing).
        final missedRate = _matchedStandardRate(ratePlanNorm);
        final stdCost = missedRate?.yourCost ?? record.monthlyCost;
        final stdCustomerPrice = (missedRate != null && missedRate.customerPrice > 0)
            ? missedRate.customerPrice
            : stdCost;

        // Only flag as missingCode when no standard rate covers this plan
        final shouldFlag = missedRate == null;

        return PriceResult(
          yourCost: stdCost,
          customerPrice: stdCustomerPrice,
          source: PriceSource.standardPlan,
          matchedRule: shouldFlag
              ? 'MISSING CODE — no plan code matched "${record.ratePlan}"'
              : 'Standard plan: ${missedRate.planKey} (no custom code for this plan)',
          missingCode: shouldFlag,
        );
      }
    }

    // ── Tier 2: Standard plan keyword match ───────────────────────
    // Always prefer the stored standard rate over the raw CSV value.
    // If customerPrice is set (> 0) on the rate, use it; otherwise charge
    // the same as yourCost (cost-pass-through).
    final matched2 = _matchedStandardRate(ratePlanNorm);
    if (matched2 != null) {
      final resolvedCost = matched2.yourCost > 0
          ? matched2.yourCost
          : record.monthlyCost;
      final resolvedCustomerPrice = matched2.customerPrice > 0
          ? matched2.customerPrice
          : resolvedCost;
      return PriceResult(
        yourCost: resolvedCost,
        customerPrice: resolvedCustomerPrice,
        source: PriceSource.standardPlan,
        matchedRule: 'Standard plan: ${matched2.planKey}',
      );
    }

    // ── Tier 3: CSV fallback ──────────────────────────────────────
    return PriceResult(
      yourCost: record.monthlyCost,
      customerPrice: record.monthlyCost,
      source: PriceSource.csvFallback,
      matchedRule: 'CSV value (\$${record.monthlyCost.toStringAsFixed(2)})',
    );
  }

  double _resolveStandardCost(String ratePlanNorm, double fallback) {
    final match = _matchedStandardRate(ratePlanNorm);
    // Return the stored yourCost if it's been set (> 0), otherwise use the CSV fallback.
    // This ensures that updating a standard rate's yourCost is always reflected.
    if (match != null) return match.yourCost > 0 ? match.yourCost : fallback;
    return fallback;
  }

  StandardPlanRate? _matchedStandardRate(String ratePlanNorm) {
    // Sort by keyword length desc so longer/more-specific keywords win
    final sorted = List<StandardPlanRate>.from(standardRates)
      ..sort((a, b) => b.keyword.length.compareTo(a.keyword.length));

    for (final rate in sorted) {
      final kw = rate.keyword.trim().toLowerCase();
      if (kw.isNotEmpty && ratePlanNorm.contains(kw)) {
        return rate;
      }
    }
    return null;
  }

  /// Strip everything from the first `{` or `|` in a customer name.
  /// "ACME Corp {12345}"  → "ACME Corp"
  /// "ACME Corp | Branch" → "ACME Corp"
  static String _stripCustomerSuffix(String name) {
    final braceIdx = name.indexOf('{');
    final pipeIdx  = name.indexOf('|');
    int cutAt = name.length;
    if (braceIdx >= 0 && braceIdx < cutAt) cutAt = braceIdx;
    if (pipeIdx  >= 0 && pipeIdx  < cutAt) cutAt = pipeIdx;
    return name.substring(0, cutAt).trim();
  }

  /// Public helper so other parts of the app can use the same stripping logic.
  static String cleanCustomerName(String name) => _stripCustomerSuffix(name);
}
