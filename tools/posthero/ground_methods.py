"""Explicit (carrier, method) ground allowlist for PostHero transit analysis.

Substring-matching on "Ground" is wrong in BOTH directions, so this is a
maintained allowlist. Anything not listed here lands in an `unclassified`
bucket that gets counted and reported -- never silently defaulted either way.

Keys are (carrier_norm, method_norm); see `norm()`. Values are one of:
  "ground"      -- hard ground
  "ground_soft" -- ground, but worth sensitivity-testing out (last-mile
                   handoff / surface-since-2021 services)
  "air"         -- air or deferred-air; excluded from the ground histogram
"""

import re

_WS = re.compile(r"\s+")


def norm(s):
    """Normalize a carrier or method string for allowlist lookup."""
    if s is None:
        return ""
    s = str(s).strip().lower()
    s = s.replace("_", " ").replace("-", " ")
    s = _WS.sub(" ", s)
    return s


# (carrier, method) -> classification
CLASSIFIED = {}


def _add(carrier, methods, kind):
    for m in methods:
        CLASSIFIED[(norm(carrier), norm(m))] = kind


# --- UPS -------------------------------------------------------------------
_add("ups", [
    "Ground",
    "UPS Ground",
    "Ground Residential",
    "Ground Commercial",
    "UPS Ground Saver",
    "Ground Saver",
], "ground")
# SurePost is ground injection with USPS final mile -> soft.
_add("ups", ["SurePost", "UPS SurePost", "SurePost Less than 1lb",
             "SurePost 1lb or Greater"], "ground_soft")
# Named ground-ish, actually deferred air.
_add("ups", ["3 Day Select", "UPS 3 Day Select", "2nd Day Air", "Next Day Air",
             "Next Day Air Saver", "Next Day Air Early", "2nd Day Air A.M.",
             "UPS 2nd Day Air", "UPS Next Day Air"], "air")

# --- FedEx -----------------------------------------------------------------
_add("fedex", [
    "Ground",
    "Fedex Ground",
    "Home Delivery",
    "Fedex Home Delivery",
    "Ground Home Delivery",
    "International Ground",
], "ground")
_add("fedex", ["SmartPost", "Fedex SmartPost", "Ground Economy",
               "Fedex Ground Economy"], "ground_soft")
# Express Saver is 3-day *air*, despite sounding economy.
_add("fedex", ["Express Saver", "Fedex Express Saver", "Express Saver 3 Day",
               "2Day", "2Day A.M.", "Standard Overnight", "Priority Overnight",
               "First Overnight", "Fedex 2Day"], "air")

# --- USPS ------------------------------------------------------------------
# First Class Mail has been surface-only since 2021 -> ground, but soft.
_add("usps", ["First Class Mail", "First Class", "First Class Package Service",
              "First Class Mail Parcel"], "ground_soft")
_add("usps", [
    "Ground Advantage",
    "USPS Ground Advantage",
    "Parcel Select",
    "Parcel Select Ground",
    "Retail Ground",
    "Media Mail",
    "Bound Printed Matter",
], "ground")
# Priority Mail moves by air on longer zones; treat as air (not ground).
_add("usps", ["Priority Mail", "Priority Mail Express", "Express Mail"], "air")

# --- DHL eCommerce ---------------------------------------------------------
# DHL eCommerce is ground injection. "Expedited" is a service tier, not air.
_add("dhl", [
    "SmartMail Parcel Ground",
    "DHL SmartMail Parcel Ground",
    "SmartMail Parcel Expedited",
    "Parcel Expedited",
    "Parcel Expedited Max",
    "DHL Parcel Expedited",
    "DHL Parcel Expedited Max",
    "Parcel Ground",
], "ground")
_add("dhl ecommerce", [
    "SmartMail Parcel Ground", "Parcel Expedited", "Parcel Expedited Max",
    "Parcel Ground",
], "ground")
_add("dhl", ["Express Worldwide", "Express 12:00"], "air")

# --- Regional / alt carriers ----------------------------------------------
_add("uniuni", ["GROUND", "UniUni GROUND", "Standard"], "ground")
_add("gofo", ["Parcel Pickup", "GOFO Parcel Pickup", "Ground"], "ground")
_add("ontrac", ["Ground", "OnTrac Ground"], "ground")
_add("lasership", ["Ground", "Routed Delivery"], "ground")
_add("veho", ["Ground", "Standard"], "ground")


def classify(carrier, method):
    """Return 'ground', 'ground_soft', 'air', or 'unclassified'."""
    c, m = norm(carrier), norm(method)
    hit = CLASSIFIED.get((c, m))
    if hit:
        return hit
    # Try carrier prefix match (e.g. "fedex smartpost" arriving as carrier).
    for (kc, km), kind in CLASSIFIED.items():
        if kc and c.startswith(kc) and km == m:
            return kind
    return "unclassified"


def is_ground(carrier, method, include_soft=True):
    k = classify(carrier, method)
    return k == "ground" or (include_soft and k == "ground_soft")
