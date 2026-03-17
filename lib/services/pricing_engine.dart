// 2-Tier Pricing Engine
//
// Tier 1 — Standard Plan Rates  (keyword match on rate plan name → your cost)
// Tier 2 — Customer Plan Codes  (customer + plan code match → customer's price)
//
// Resolution order for a given device:
//   1. Customer has a specific plan code that matches → use customerPrice
//   2. Standard plan keyword matches → use yourCost (what Geotab charges you)
//   3. Fall back to the raw CSV monthly cost
//
// "Missing code" flag: if a customer has ANY CustomerPlanCode entries AND
// none of them match a device's rate plan, that device is flagged so you
// know to add/fix the special code in MyAdmin.

import '../models/activation_record.dart';
import '../models/standard_plan_rate.dart';
import '../models/customer_plan_code.dart';

enum PriceSource { customerCode, standardPlan, csvFallback }

class PriceResult {
  final double yourCost;       // what Geotab charges you (used for proration math)
  final double customerPrice;  // what YOU charge the customer
  final PriceSource source;
  final String matchedRule;    // human-readable description of what matched
  final bool missingCode;      // true when customer has codes but none matched

  const PriceResult({
    required this.yourCost,
    required this.customerPrice,
    required this.source,
    required this.matchedRule,
    this.missingCode = false,
  });
}

class PricingEngine {
  final List<StandardPlanRate> standardRates;
  final List<CustomerPlanCode> customerCodes;

  PricingEngine({
    required this.standardRates,
    required this.customerCodes,
  });

  /// Resolve pricing for a single device record.
  PriceResult resolve(ActivationRecord record) {
    final customerNameNorm = record.customer.trim().toLowerCase();
    final ratePlanNorm = record.ratePlan.trim().toLowerCase();

    // ── Tier 2: Customer-specific plan codes ─────────────────────
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
        // We have a customer code AND it matched — use customer price
        // For yourCost, resolve from standard plan as usual
        final stdCost = _resolveStandardCost(ratePlanNorm, record.monthlyCost);
        return PriceResult(
          yourCost: stdCost,
          customerPrice: matched.customerPrice,
          source: PriceSource.customerCode,
          matchedRule: 'Customer code: "${matched.planCode}"',
        );
      } else {
        // Customer has codes but NONE matched this plan — flag it
        final stdCost = _resolveStandardCost(ratePlanNorm, record.monthlyCost);
        return PriceResult(
          yourCost: stdCost,
          customerPrice: stdCost, // temporary fallback, flagged
          source: PriceSource.standardPlan,
          matchedRule: 'MISSING CODE — no plan code matched "${record.ratePlan}"',
          missingCode: true,
        );
      }
    }

    // ── Tier 1: Standard plan keyword match ───────────────────────
    final stdCost = _resolveStandardCost(ratePlanNorm, record.monthlyCost);
    if (stdCost != record.monthlyCost) {
      final matched = _matchedStandardRate(ratePlanNorm);
      return PriceResult(
        yourCost: stdCost,
        customerPrice: stdCost, // no customer override → your cost IS what you charge
        source: PriceSource.standardPlan,
        matchedRule: 'Standard plan: ${matched?.planKey ?? ""}',
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
    return match?.yourCost ?? fallback;
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
}
