"""Small source-only checks. Does not import Selenium or open a browser."""
import copy
import json
from pathlib import Path
import runpy
import tempfile


def main():
    source = Path(__file__).with_name("postdeploy-browser-smoke.py")
    compile(source.read_text(encoding="utf-8"), str(source), "exec")
    namespace = runpy.run_path(str(source))
    config = {"url": namespace["BASE"], "expected_version": namespace["VERSION"],
              "fixture_account_inactive_verified": True,
              "dedicated_disposable_user4_session_verified": True,
              "conversation_id": "00000000-0000-4000-8000-000000000001",
              "session_cookie": {"name": "SESSION", "value": "FAKE_TEST_VALUE_NOT_A_SESSION"}}
    cases = [("wrong_host", "url", "https://example.org"),
             ("wrong_version", "expected_version", "0.12.4.00"),
             ("active_or_unknown_account", "fixture_account_inactive_verified", False),
             ("borrowed_session", "dedicated_disposable_user4_session_verified", False),
             ("invalid_conversation", "conversation_id", "invalid")]
    results = []
    with tempfile.TemporaryDirectory(prefix="selena-source-only-") as folder:
        path = Path(folder) / "fake-input.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        namespace["configuration"](path)
        results.append({"id": "valid_fake_config_parses", "status": "PASS"})
        for name, key, value in cases:
            bad = copy.deepcopy(config)
            bad[key] = value
            path.write_text(json.dumps(bad), encoding="utf-8")
            try:
                namespace["configuration"](path)
            except (AssertionError, ValueError):
                results.append({"id": name, "status": "PASS_REJECTED"})
            else:
                raise AssertionError("Negative configuration accepted: " + name)
        for name, cookie in [("wrong_cookie_name", {"name": "remember-me", "value": "FAKE"}),
                             ("empty_cookie", {"name": "SESSION", "value": ""})]:
            bad = copy.deepcopy(config)
            bad["session_cookie"] = cookie
            path.write_text(json.dumps(bad), encoding="utf-8")
            try:
                namespace["configuration"](path)
            except AssertionError:
                results.append({"id": name, "status": "PASS_REJECTED"})
            else:
                raise AssertionError("Negative cookie accepted: " + name)
    for text, expected in [("Wersja 0.12.4.0", True), ("Wersja 0.12.4.00", False), ("Wersja 0.12.4.0.1", False)]:
        assert namespace["has_expected_version"](text) is expected
    results.append({"id": "exact_version_boundaries", "status": "PASS"})
    result = {"kind": "SOURCE_ONLY_NO_BROWSER", "status": "PASS", "checks": results,
              "browser": "NOT_RUN", "live_verdict": "NOT_RUN"}
    source.with_name("postdeploy-browser-smoke-source-check.json").write_text(
        json.dumps(result, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
