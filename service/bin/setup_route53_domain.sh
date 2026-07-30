#!/usr/bin/env bash
# One-time setup for bluegull-aqi-8ef.18: add a Route53 hosted zone + DNS
# delegation for a new custom-domain subdomain, mirroring the existing
# aqi.bluegull.org setup (doc/DESIGN.md "Backend custom domain"). Run this
# yourself where AWS auth (the 1Password `aws` CLI shim) is actually
# unlocked -- it can't run from an unattended/sandboxed shell.
#
# Creates a Route53 hosted zone for the given subdomain (default:
# aqi.bluegull.solutions) in the dedicated bluegull-aqi AWS account
# (843088391598, bluegull-aqi-8ef.4) and prints the 4 nameservers you need
# to add as an NS record. IMPORTANT: bluegull.solutions is REGISTERED at
# Squarespace but its actual authoritative DNS (nameservers) is at
# DreamHost (confirmed via `dig NS aqi.bluegull.solutions` -> SOA
# ns1.dreamhost.com, 2026-07-30) -- unlike bluegull.org, where registrar
# and DNS host are the same (Squarespace). The NS record goes in
# DreamHost's panel, NOT Squarespace's DNS settings. Neither has a CLI/API
# for this; this script can't do that part for you, only get you the
# values to paste in.
#
# Idempotent: if a hosted zone for the subdomain already exists, reuses it
# instead of creating a duplicate (Route53 doesn't enforce unique names, so
# re-running a create blindly would create a second zone).
#
# Usage: service/bin/setup_route53_domain.sh [subdomain]
#   subdomain defaults to aqi.bluegull.solutions if omitted.

set -euo pipefail

PROFILE="AdministratorAccess-843088391598"
EXPECTED_ACCOUNT_ID="843088391598"
SUBDOMAIN="${1:-aqi.bluegull.solutions}"

echo "Verifying AWS identity for profile '$PROFILE'..."
CALLER_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Account' --output text)
if [ "$CALLER_ACCOUNT" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo "ERROR: authenticated as account $CALLER_ACCOUNT, expected $EXPECTED_ACCOUNT_ID (bluegull-aqi-8ef.4). Aborting." >&2
  exit 1
fi
echo "Confirmed: account $CALLER_ACCOUNT."

echo
echo "Looking for an existing hosted zone for '$SUBDOMAIN.'..."
ZONE_ID=$(aws route53 list-hosted-zones-by-name --profile "$PROFILE" \
  --dns-name "$SUBDOMAIN" \
  --query "HostedZones[?Name=='${SUBDOMAIN}.'] | [0].Id" --output text)

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "None found -- creating a new hosted zone for '$SUBDOMAIN'..."
  ZONE_ID=$(aws route53 create-hosted-zone \
    --profile "$PROFILE" \
    --name "$SUBDOMAIN" \
    --caller-reference "bluegull-aqi-$(date +%s)" \
    --hosted-zone-config Comment="bluegull-aqi backend custom domain (bluegull-aqi-8ef.18)" \
    --query 'HostedZone.Id' --output text)
  echo "Created zone: $ZONE_ID"
else
  echo "Reusing existing zone: $ZONE_ID"
fi

echo
echo "Fetching nameservers for the zone..."
NAMESERVERS=$(aws route53 get-hosted-zone --profile "$PROFILE" --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text)

echo
echo "=================================================================="
echo "Zone ready: $ZONE_ID ($SUBDOMAIN)"
echo
echo "Next (MANUAL -- DreamHost has no API for this):"
echo "  bluegull.solutions is REGISTERED at Squarespace but its actual DNS"
echo "  is hosted at DreamHost (confirmed via dig NS -> SOA ns1.dreamhost.com)."
echo "  The NS record goes in DreamHost's panel, NOT Squarespace."
echo
echo "  1. Log in to the DreamHost panel (panel.dreamhost.com)."
echo "  2. Go to Websites > Manage Websites, find bluegull.solutions, click"
echo "     the vertical-3-dots menu, choose DNS Settings."
echo "  3. Click 'Add Record', hover the 'NS Record' section, click 'ADD'."
echo "  4. Add one NS record per nameserver below (Host: ${SUBDOMAIN%%.bluegull.solutions},"
echo "     Value/Points-to: the nameserver) -- repeat for all 4:"
for ns in $NAMESERVERS; do
  echo "         $ns"
done
echo
echo "  5. Save, then verify (DreamHost's own docs note propagation can take"
echo "     a few hours, and subdomain NS records sometimes don't show up in"
echo "     public dig lookups even once live -- if dig still shows NXDOMAIN"
echo "     after a while, that alone isn't proof it failed):"
echo "       dig NS $SUBDOMAIN"
echo "     Should return the same 4 nameservers listed above."
echo "=================================================================="
