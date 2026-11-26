"""Tests for tools/announce.py (no network): python -m unittest tools/test_announce.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import announce  # noqa: E402


class AnnounceTest(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(announce.script_build('local SCRIPT_BUILD = "2026.11.25-86" -- note'), "2026.11.25-86")
        self.assertEqual(announce.payload_version('PAYLOAD_VERSION = "1.7.1"\n'), "1.7.1")
        self.assertIsNone(announce.script_build(""))

    def test_subjects_are_cleaned(self):
        self.assertEqual(announce.clean_subject("Fix the menu."), "Fix the menu")
        self.assertEqual(announce.clean_subject("Co-Authored-By: x"), "")
        self.assertEqual(announce.clean_subject("Merge branch 'x'"), "")
        text = announce.bullets(["One", "Two", "", "Claude-Session: x"], 1000)
        self.assertEqual(text, "- One\n- Two")

    def test_long_lists_are_cut(self):
        text = announce.bullets(["change number %d with some words" % i for i in range(200)], 500)
        self.assertLessEqual(len(text), 500)
        self.assertTrue(text.endswith("more"))

    def test_push_embeds(self):
        e = announce.update_embeds("2026.11.25-85", "2026.11.25-86", "1.7.1", "1.7.1", ["Mobile mode"], "https://x")
        self.assertEqual(len(e), 1)
        self.assertIn("build 2026.11.25-86", e[0]["title"])
        self.assertIn("- Mobile mode", e[0]["description"])
        self.assertIn("loadstring", e[0]["fields"][0]["value"])
        self.assertEqual(e[0]["url"], "https://x")
        both = announce.update_embeds("a", "b", "1.7.0", "1.7.1", ["x"])
        self.assertEqual([x["title"].split(" updated")[0] for x in both], ["Puppy Admin", "Puppy Companion"])
        self.assertEqual(announce.update_embeds("a", "a", "1", "1", ["x"]), [], "no version change: nothing")
        for x in both:
            for f in x["fields"]:
                self.assertLessEqual(len(f["value"]), announce.MAX_FIELD)

    def test_pings_are_opt_in(self):
        body = announce.payload([announce.manual_embed("T", "a\\nb")])
        self.assertEqual(body["allowed_mentions"], {"parse": []})
        self.assertNotIn("content", body)
        self.assertEqual(body["embeds"][0]["description"], "a\nb")
        here = announce.payload([], "here")
        self.assertEqual(here["content"], "@here")
        role = announce.payload([], "role:123")
        self.assertEqual((role["content"], role["allowed_mentions"]), ("<@&123>", {"roles": ["123"]}))
        bad = announce.payload([], "role:abc")
        self.assertNotIn("content", bad)

    def test_dry_run_and_missing_url(self):
        self.assertEqual(announce.main(["--title", "Hi", "--message", "x", "--dry-run"]), 0)
        os.environ.pop("DISCORD_WEBHOOK_URL", None)
        self.assertEqual(announce.main(["--title", "Hi", "--message", "x"]), 0, "no webhook: posts nothing, no error")


if __name__ == "__main__":
    unittest.main()
