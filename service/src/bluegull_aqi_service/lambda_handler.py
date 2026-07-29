"""Lambda entry point.

Deliberately thin: this module only translates between the API Gateway HTTP
API event shape and plain Python calls. The actual lookup/cache logic lives
in a separate core module (bluegull-aqi-q9r.2) so the same code path can run
locally against DynamoDB Local as runs in Lambda against DynamoDB, and so it
can be exercised by contract tests without going through a Lambda event at
all. See doc/DESIGN.md "Local development (no AWS required)".
"""
import json


def lambda_handler(event, context):  # pylint: disable=unused-argument
    """Placeholder scaffold response; replaced by bluegull-aqi-q9r.2."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"status": "ok"}),
    }
