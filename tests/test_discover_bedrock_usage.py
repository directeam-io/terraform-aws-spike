import datetime
import importlib.util
import json
import pathlib
import unittest
from unittest import mock

SCRIPT_PATH = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "discover_bedrock_usage.py"
TODAY = datetime.date(2026, 9, 29)

spec = importlib.util.spec_from_file_location("discover_bedrock_usage", SCRIPT_PATH)
discover_bedrock_usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discover_bedrock_usage)


def page(groups, token=None):
    body = {"ResultsByTime": [{"Groups": [{"Keys": keys, "Metrics": {"UnblendedCost": {"Amount": amount}}} for keys, amount in groups]}]}
    if token:
        body["NextPageToken"] = token
    return body


def fake_aws(services, usage, account="111111111111"):
    """Answers the CLI calls: identity, cost by service, and cost by account/region."""

    def call(*args):
        if args[0] == "sts":
            return {"Account": account}
        if "Type=DIMENSION,Key=LINKED_ACCOUNT" not in args:
            return services
        return usage.pop(0) if isinstance(usage, list) else usage

    return call


class DiscoverTest(unittest.TestCase):
    def run_discovery(self, services, usage, account="111111111111", expected="111111111111", lookback=90):
        query = {"account_id": expected, "lookback_days": str(lookback)}
        with mock.patch.object(discover_bedrock_usage, "aws", side_effect=fake_aws(services, usage, account)) as aws:
            return discover_bedrock_usage.discover(query, today=TODAY), aws

    def test_finds_accounts_and_regions(self):
        result, _ = self.run_discovery(
            page([(["Amazon Bedrock"], "12.5"), (["Claude Sonnet 4 (Amazon Bedrock Edition)"], "3"), (["Amazon S3"], "99")]),
            page(
                [
                    (["111111111111", "us-west-2"], "10"),
                    (["111111111111", "us-east-1"], "1"),
                    (["222222222222", "eu-west-1"], "4.5"),
                ]
            ),
        )
        self.assertEqual(
            json.loads(result["accounts"]),
            {"111111111111": ["us-east-1", "us-west-2"], "222222222222": ["eu-west-1"]},
        )
        self.assertEqual(result["services"], "Amazon Bedrock, Claude Sonnet 4 (Amazon Bedrock Edition)")
        self.assertEqual(result["period"], "2026-07-01/2026-09-29")

    def test_ignores_zero_spend_and_non_regional_usage(self):
        result, _ = self.run_discovery(
            page([(["Amazon Bedrock"], "5")]),
            page(
                [
                    (["111111111111", "us-east-1"], "0"),
                    (["111111111111", "NoRegion"], "5"),
                    (["111111111111", "global"], "5"),
                    (["222222222222", "us-east-1"], "3"),
                    (["222222222222", "us-east-1"], "-3"),
                ]
            ),
        )
        self.assertEqual(json.loads(result["accounts"]), {})

    def test_no_bedrock_spend_skips_the_usage_query(self):
        result, aws = self.run_discovery(page([(["Amazon S3"], "99"), (["Amazon Bedrock"], "0")]), page([]))
        self.assertEqual(json.loads(result["accounts"]), {})
        self.assertEqual(result["services"], "")
        self.assertEqual(aws.call_count, 2)  # identity + services only

    def test_follows_pagination(self):
        with mock.patch.object(discover_bedrock_usage, "aws") as aws:
            aws.side_effect = [
                page([(["111111111111", "us-east-1"], "1")], token="next"),
                page([(["222222222222", "eu-west-1"], "2")]),
            ]
            usage = discover_bedrock_usage.bedrock_usage("2026-07-01", "2026-09-29", ["Amazon Bedrock"])
        self.assertEqual(usage, {"111111111111": ["us-east-1"], "222222222222": ["eu-west-1"]})
        self.assertIn("next", aws.call_args_list[1].args)

    def test_rejects_credentials_of_another_account(self):
        with self.assertRaisesRegex(discover_bedrock_usage.DiscoveryError, "belong to account 111111111111"):
            self.run_discovery(page([]), page([]), account="111111111111", expected="999999999999")


if __name__ == "__main__":
    unittest.main()
