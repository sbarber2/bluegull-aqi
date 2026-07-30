#!/usr/bin/env bash
# One-time setup for bluegull-aqi-8ef.11: AWS Budget + Cost Anomaly Detection
# alarms. Run this yourself where AWS auth (the 1Password `aws` CLI shim) is
# actually unlocked -- it can't run from an unattended/sandboxed shell.
#
# Idempotent: safe to re-run. Creates, in the dedicated bluegull-aqi AWS
# account (843088391598, decided in bluegull-aqi-8ef.4):
#   1. A monthly cost Budget with a low absolute limit, alerting at 50%/100%
#      of actual spend and 100% of forecasted spend.
#   2. A Cost Anomaly Detection subscription, alerting on any anomaly >= $1,
#      attached to whatever DIMENSIONAL/SERVICE monitor already exists in
#      the account rather than creating a redundant one -- AWS auto-
#      provisions a "Default-Services-Monitor" per account (predates this
#      project; confirmed present here, created 2025-02-06), and that
#      monitor already tracks all services account-wide. Deliberately does
#      NOT touch any pre-existing subscription on that monitor (e.g.
#      "Default-Services-Subscription") -- adds a second, more sensitive
#      one instead, since this account's baseline spend should be near zero
#      and the account default's $100/40%-combined threshold is too coarse
#      for that.
#
# Cost Explorer / Anomaly Detection's API only exists in us-east-1
# regardless of which region the actual resources run in (same as IAM,
# Route53, ACM-for-CloudFront) -- it's an account-wide billing construct,
# not scoped to one region, so this still covers the us-east-2 deploy.
#
# Both Budgets and Cost Anomaly Detection are free AWS features themselves;
# this only touches billing/Cost Explorer, nothing that runs or bills by
# the hour. See doc/DESIGN.md "Denial of wallet": this must exist BEFORE
# the first real deploy (bluegull-aqi-q9r.10), not after.
#
# Usage: service/bin/setup_budget_alarms.sh [email]
#   email defaults to sbarber2@gmail.com if omitted.

set -euo pipefail

PROFILE="AdministratorAccess-843088391598"
EXPECTED_ACCOUNT_ID="843088391598"
EMAIL="${1:-sbarber2@gmail.com}"
BUDGET_NAME="bluegull-aqi-monthly-cost-guard"
BUDGET_LIMIT_USD="10"
ANOMALY_SUBSCRIPTION_NAME="bluegull-aqi-cost-anomaly-alerts"
ANOMALY_THRESHOLD_USD="1"

echo "Verifying AWS identity for profile '$PROFILE'..."
CALLER_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Account' --output text)
if [ "$CALLER_ACCOUNT" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo "ERROR: authenticated as account $CALLER_ACCOUNT, expected $EXPECTED_ACCOUNT_ID (bluegull-aqi-8ef.4). Aborting." >&2
  exit 1
fi
echo "Confirmed: account $CALLER_ACCOUNT."

echo
if aws budgets describe-budget --profile "$PROFILE" --account-id "$EXPECTED_ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
  echo "Budget '$BUDGET_NAME' already exists -- skipping creation."
else
  echo "Creating monthly cost budget (limit \$$BUDGET_LIMIT_USD)..."
  aws budgets create-budget \
    --profile "$PROFILE" \
    --account-id "$EXPECTED_ACCOUNT_ID" \
    --budget "{
      \"BudgetName\": \"$BUDGET_NAME\",
      \"BudgetLimit\": {\"Amount\": \"$BUDGET_LIMIT_USD\", \"Unit\": \"USD\"},
      \"BudgetType\": \"COST\",
      \"TimeUnit\": \"MONTHLY\"
    }"
  echo "Budget created."
fi

echo
EXISTING_NOTIFICATION_COUNT=$(aws budgets describe-notifications-for-budget \
  --profile "$PROFILE" --account-id "$EXPECTED_ACCOUNT_ID" --budget-name "$BUDGET_NAME" \
  --query 'length(Notifications)' --output text)
if [ "$EXISTING_NOTIFICATION_COUNT" != "0" ]; then
  echo "Budget already has $EXISTING_NOTIFICATION_COUNT notification(s) -- skipping (this script doesn't try to reconcile existing ones; check them manually)."
else
  echo "Adding budget notifications (ACTUAL 50%, ACTUAL 100%, FORECASTED 100%)..."
  aws budgets create-notification --profile "$PROFILE" --account-id "$EXPECTED_ACCOUNT_ID" --budget-name "$BUDGET_NAME" \
    --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=50,ThresholdType=PERCENTAGE \
    --subscribers SubscriptionType=EMAIL,Address="$EMAIL"
  aws budgets create-notification --profile "$PROFILE" --account-id "$EXPECTED_ACCOUNT_ID" --budget-name "$BUDGET_NAME" \
    --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE \
    --subscribers SubscriptionType=EMAIL,Address="$EMAIL"
  aws budgets create-notification --profile "$PROFILE" --account-id "$EXPECTED_ACCOUNT_ID" --budget-name "$BUDGET_NAME" \
    --notification NotificationType=FORECASTED,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE \
    --subscribers SubscriptionType=EMAIL,Address="$EMAIL"
  echo "Notifications added."
fi

echo
echo "Looking for an existing account-wide DIMENSIONAL/SERVICE cost anomaly monitor..."
MONITOR_ARN=$(aws ce get-anomaly-monitors --profile "$PROFILE" --region us-east-1 \
  --query "AnomalyMonitors[?MonitorType=='DIMENSIONAL' && MonitorDimension=='SERVICE'] | [0].MonitorArn" \
  --output text)
if [ -z "$MONITOR_ARN" ] || [ "$MONITOR_ARN" = "None" ]; then
  echo "None found -- creating one."
  MONITOR_ARN=$(aws ce create-anomaly-monitor \
    --profile "$PROFILE" \
    --region us-east-1 \
    --anomaly-monitor '{
      "MonitorName": "bluegull-aqi-cost-anomaly-monitor",
      "MonitorType": "DIMENSIONAL",
      "MonitorDimension": "SERVICE"
    }' \
    --query 'MonitorArn' --output text)
  echo "Monitor created: $MONITOR_ARN"
else
  echo "Reusing existing monitor: $MONITOR_ARN"
fi

echo
if aws ce get-anomaly-subscriptions --profile "$PROFILE" --region us-east-1 --monitor-arn "$MONITOR_ARN" \
  --query "AnomalySubscriptions[?SubscriptionName=='$ANOMALY_SUBSCRIPTION_NAME'] | [0]" --output text | grep -q .; then
  echo "Subscription '$ANOMALY_SUBSCRIPTION_NAME' already exists on this monitor -- skipping."
else
  echo "Creating anomaly subscription (alerts daily by email on any anomaly >= \$$ANOMALY_THRESHOLD_USD)..."
  aws ce create-anomaly-subscription \
    --profile "$PROFILE" \
    --region us-east-1 \
    --anomaly-subscription "{
      \"SubscriptionName\": \"$ANOMALY_SUBSCRIPTION_NAME\",
      \"MonitorArnList\": [\"$MONITOR_ARN\"],
      \"Subscribers\": [{\"Address\": \"$EMAIL\", \"Type\": \"EMAIL\"}],
      \"Frequency\": \"DAILY\",
      \"ThresholdExpression\": {
        \"Dimensions\": {
          \"Key\": \"ANOMALY_TOTAL_IMPACT_ABSOLUTE\",
          \"MatchOptions\": [\"GREATER_THAN_OR_EQUAL\"],
          \"Values\": [\"$ANOMALY_THRESHOLD_USD\"]
        }
      }
    }"
  echo "Subscription created."
fi

echo
echo "Done. If this was the subscription's first creation, AWS may email"
echo "$EMAIL a confirmation link -- it won't alert until that's confirmed."
echo "Verify with:"
echo "  aws budgets describe-notifications-for-budget --profile $PROFILE --account-id $EXPECTED_ACCOUNT_ID --budget-name $BUDGET_NAME"
echo "  aws ce get-anomaly-subscriptions --profile $PROFILE --region us-east-1 --monitor-arn $MONITOR_ARN"
