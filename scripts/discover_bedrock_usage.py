#!/usr/bin/env python3
"""Find the accounts and regions that use Amazon Bedrock, using AWS Cost Explorer.

Runs as a Terraform "external" data source: reads a JSON query on stdin and prints a JSON object of strings on stdout.
Needs Python 3.8+ and the AWS CLI on PATH, and the same AWS credentials Terraform uses (ce:GetCostAndUsage).
"""

import datetime
import json
import re
import subprocess
import sys

CE_REGION = "us-east-1"
ACCOUNT_PATTERN = re.compile(r"^\d{12}$")
REGION_PATTERN = re.compile(r"^[a-z]{2}(-[a-z]+)+-\d$")


class DiscoveryError(Exception):
    pass


def aws(*args):
    try:
        completed = subprocess.run(
            ["aws", *args, "--output", "json"],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except FileNotFoundError:
        raise DiscoveryError(
            "The AWS CLI is required to discover Bedrock usage automatically but was not found on PATH. Install it, "
            "or set bedrock_invocation_logs_accounts explicitly."
        )
    except subprocess.TimeoutExpired:
        raise DiscoveryError(f"'aws {' '.join(args[:2])}' timed out.")
    if completed.returncode != 0:
        raise DiscoveryError(f"'aws {' '.join(args[:2])}' failed: {completed.stderr.strip()}")
    return json.loads(completed.stdout or "{}")


def cost_groups(start, end, group_by, filter_expression=None):
    """Yield (keys, amount) for every group, following pagination."""
    token = None
    while True:
        args = [
            "ce",
            "get-cost-and-usage",
            "--region",
            CE_REGION,
            "--time-period",
            f"Start={start},End={end}",
            "--granularity",
            "MONTHLY",
            "--metrics",
            "UnblendedCost",
            "--group-by",
            *[f"Type=DIMENSION,Key={key}" for key in group_by],
        ]
        if filter_expression:
            args += ["--filter", json.dumps(filter_expression)]
        if token:
            args += ["--next-page-token", token]
        page = aws(*args)
        for period in page.get("ResultsByTime", []):
            for group in period.get("Groups", []):
                yield group["Keys"], float(group["Metrics"]["UnblendedCost"]["Amount"])
        token = page.get("NextPageToken")
        if not token:
            return


def bedrock_services(start, end):
    """Cost Explorer lists Bedrock under several service names, e.g. 'Amazon Bedrock' and '<Model> (Amazon Bedrock Edition)'."""
    totals = {}
    for (service,), amount in cost_groups(start, end, ["SERVICE"]):
        if "bedrock" in service.lower():
            totals[service] = totals.get(service, 0.0) + amount
    return sorted(service for service, amount in totals.items() if amount > 0)


def bedrock_usage(start, end, services):
    totals = {}
    filter_expression = {"Dimensions": {"Key": "SERVICE", "Values": services}}
    for (account_id, region), amount in cost_groups(start, end, ["LINKED_ACCOUNT", "REGION"], filter_expression):
        totals[(account_id, region)] = totals.get((account_id, region), 0.0) + amount
    usage = {}
    for (account_id, region), amount in totals.items():
        # Skips refunds/credits that net to zero, and non-regional values such as "global" or "NoRegion".
        if amount > 0 and ACCOUNT_PATTERN.match(account_id) and REGION_PATTERN.match(region):
            usage.setdefault(account_id, []).append(region)
    return {account_id: sorted(regions) for account_id, regions in sorted(usage.items())}


def check_credentials(expected_account_id):
    actual = aws("sts", "get-caller-identity")["Account"]
    if actual != expected_account_id:
        raise DiscoveryError(
            f"The AWS CLI credentials belong to account {actual}, but Terraform is deploying to account "
            f"{expected_account_id} (for example through an assume_role provider). Run Terraform with credentials for "
            "the target account, or set bedrock_invocation_logs_accounts explicitly."
        )


def discover(query, today=None):
    lookback_days = int(query["lookback_days"])
    end = today or datetime.datetime.now(datetime.timezone.utc).date()
    start = end - datetime.timedelta(days=lookback_days)

    check_credentials(query["account_id"])
    services = bedrock_services(start.isoformat(), end.isoformat())
    usage = bedrock_usage(start.isoformat(), end.isoformat(), services) if services else {}
    return {
        "accounts": json.dumps(usage, sort_keys=True),
        "services": ", ".join(services),
        "period": f"{start.isoformat()}/{end.isoformat()}",
    }


def main():
    try:
        print(json.dumps(discover(json.load(sys.stdin))))
    except DiscoveryError as error:
        print(f"Bedrock usage discovery failed: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
