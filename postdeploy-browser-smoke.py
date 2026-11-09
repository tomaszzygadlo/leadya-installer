"""Read-only, release-specific Selenium smoke; operator runs after the .0 receipt.

Requires Selenium 4.20.0 and existing matching browser/driver binaries. Never
downloads a driver. Input is a PRIVATE JSON file; outputs must remain encrypted.
This is automated E2E evidence, not manual CUA acceptance or a campaign launch.
"""
import argparse
import json
import os
import re
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID


BASE = "https://hotfix.turbot.pro"
VERSION = "0.12.4.0"
LANDING = "https://webinar-ai.hotfixlanding.turbot.pro/?c=242"
REVIEW_LABEL = "Pokaż treści do zatwierdzenia"
AI_MARKER = re.compile(r"zmienion[eyae].{0,12}przez\s+AI", re.I)


def require(condition, code):
    if not condition:
        raise AssertionError(code)


def has_expected_version(text):
    return re.findall(r"(?<![\d.])\d+\.\d+\.\d+\.\d+(?![\d.])", text) == [VERSION]


def configuration(path):
    cfg = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    require(cfg.get("url") == BASE, "WRONG_ENVIRONMENT")
    require(cfg.get("expected_version") == VERSION, "WRONG_VERSION_INPUT")
    require(cfg.get("fixture_account_inactive_verified") is True, "ACCOUNT_PREFLIGHT_REQUIRED")
    require(cfg.get("dedicated_disposable_user4_session_verified") is True, "DEDICATED_SESSION_REQUIRED")
    require(str(UUID(cfg["conversation_id"])) == cfg["conversation_id"], "BAD_CONVERSATION_ID")
    cookie = cfg["session_cookie"]
    require(cookie.get("name") in {"JSESSIONID", "SESSION"}, "BAD_COOKIE_NAME")
    require(isinstance(cookie.get("value"), str) and 0 < len(cookie["value"]) < 4096, "BAD_COOKIE_VALUE")
    return cfg


def run(args):
    # Import only after configuration validation; source/AST checks need no Selenium.
    cfg = configuration(args.input)
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.chrome.service import Service as ChromeService
    from selenium.webdriver.edge.service import Service as EdgeService

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    result = {"kind": "automated-selenium-e2e", "version": VERSION, "fixture": 242,
              "status": "FAIL", "checks": [], "stage": "browser_start",
              "not_run": ["fresh_goal_conversation", "campaign_approval", "campaign_launch", "mobile", "Lite_account"]}
    driver = None
    try:
        require(Path(args.binary).is_file() and Path(args.driver).is_file(), "MISSING_BROWSER_OR_DRIVER")
        options = webdriver.EdgeOptions() if args.browser == "edge" else webdriver.ChromeOptions()
        options.binary_location = str(Path(args.binary).resolve())
        for option in ("--headless=new", "--window-size=1440,1000", "--no-first-run", "--disable-logging"):
            options.add_argument(option)
        service_type = EdgeService if args.browser == "edge" else ChromeService
        service = service_type(executable_path=str(Path(args.driver).resolve()), log_output=os.devnull)
        if os.name == "nt":
            import subprocess
            service.creation_flags = subprocess.CREATE_NO_WINDOW
        driver = (webdriver.Edge if args.browser == "edge" else webdriver.Chrome)(service=service, options=options)
        driver.set_page_load_timeout(45)
        wait = WebDriverWait(driver, 30)

        def check(condition, code, **counts):
            require(condition, code)
            result["checks"].append({"id": code, "status": "PASS", **counts})

        def screenshot(name):
            require(driver.save_screenshot(str(output / (name + ".png"))), "SCREENSHOT_FAILED")

        def page(path, name, campaign=False):
            result["stage"] = name
            driver.get(BASE + path)
            wait.until(lambda d: d.execute_script("return document.readyState") == "complete")
            require(urlparse(driver.current_url).netloc == "hotfix.turbot.pro", "UNEXPECTED_REDIRECT")
            require(not any(e.is_displayed() for e in driver.find_elements(By.CSS_SELECTOR, "#loginForm #password")), "LOGIN_REQUIRED")
            from browser_startup import dismiss_startup
            dismiss_startup(driver, wait, By, EC)
            footer = wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, ".app-footer")))
            check(has_expected_version(footer.get_attribute("textContent")), name + "_version")
            require(not re.search(r"\?\?[\w.]+\?\?", driver.find_element(By.TAG_NAME, "body").text), "MISSING_I18N")
            if campaign:
                ids = driver.find_elements(By.CSS_SELECTOR, "#idCampaing, #campaignId, #campaignOpenersPanel[data-campaign-id]")
                check(any(e.get_attribute("value") == "242" or e.get_attribute("data-campaign-id") == "242" for e in ids), name + "_campaign")
            screenshot(name)

        result["stage"] = "cookie_setup"
        driver.get(BASE + "/robots.txt")
        require(urlparse(driver.current_url).netloc == "hotfix.turbot.pro", "BAD_COOKIE_ORIGIN")
        driver.add_cookie({"name": cfg["session_cookie"]["name"], "value": cfg["session_cookie"]["value"],
                           "path": "/", "secure": True, "httpOnly": True, "sameSite": "Lax"})
        page("/user", "user")
        check(driver.find_element(By.ID, "currentUserId").get_attribute("value") == "4", "fixture_owner")

        # These GET views select fixture 242 in the dedicated disposable session.
        for path, name in (("/facebookMainPage?campaign=242", "campaign"),
                           ("/facebookPosts?campaign=242", "posts"),
                           ("/facebookMessages?campaign=242", "messages"),
                           ("/facebookLandingPage?campaign=242", "landing_tab")):
            page(path, name, campaign=True)

        result["stage"] = "fresh_chat_review"
        wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, ".leadya-assistant__launcher"))).click()
        history = wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, ".leadya-assistant__history")))
        if not history.get_attribute("open"):
            history.find_element(By.CSS_SELECTOR, "summary").click()
        conversation = '.leadya-assistant__history [data-conversation-id="' + cfg["conversation_id"] + '"]'
        wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, conversation))).click()
        wait.until(lambda d: d.find_element(By.CSS_SELECTOR, conversation).get_attribute("aria-current") == "true")
        bubbles = ".leadya-assistant__message--assistant .leadya-assistant__bubble"
        # Deliberate Polish copy guard: never click an unlabelled/ordinal action
        # which could instead be approve, start or delete.
        review = (By.XPATH, "//div[contains(@class,'leadya-assistant__campaign-actions')]/button[normalize-space(.)='" + REVIEW_LABEL + "']")
        review_button = wait.until(EC.element_to_be_clickable(review))
        before = {element.id for element in driver.find_elements(By.CSS_SELECTOR, bubbles)}
        review_button.click()
        new_bubbles = wait.until(lambda d: [e for e in d.find_elements(By.CSS_SELECTOR, bubbles) if e.id not in before])
        bubble = new_bubbles[-1]
        text = bubble.text
        links = {e.get_attribute("href") for e in bubble.find_elements(By.CSS_SELECTOR, "a[href]")}
        groups = {u for u in links if re.match(r"https://(?:www\.)?facebook\.com/groups/", u or "")}
        check(len(groups) == 10, "fresh_review_groups", count=len(groups))
        check(all(any(line.startswith("• ") and " — " + url in line
                      and not line[2:].startswith("http") for line in text.splitlines())
                  for url in groups), "fresh_review_group_names")
        check(LANDING in links, "fresh_review_landing")
        check("Komentarze do rozgrzewki" in text, "fresh_review_warmup_label")
        check(not AI_MARKER.search(text), "fresh_review_no_ai_annotation")
        screenshot("fresh-chat-review")

        page("/leadya-assistant/campaign/drafts/50/campaigns/242/editor", "creation_editor", campaign=True)
        panel = wait.until(EC.visibility_of_element_located((By.ID, "campaignOpenersPanel")))
        check(panel.get_attribute("data-creation-review") == "true", "new_campaign_editor")
        wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, "#campaignReviewPosts > li")) == 10)
        wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, "#campaignReviewWarmup > li")) == 8)
        check(True, "editor_content_counts", posts=10, warmup=8)
        check("Komentarze do rozgrzewki" in driver.find_element(By.ID, "campaignReviewWarmupTitle").text, "editor_warmup_label")
        check(not driver.find_element(By.ID, "campaignReviewCommentsSection").is_displayed(), "no_post_comments_section")
        check(not AI_MARKER.search(panel.text), "editor_no_ai_annotation")
        check(not any(e.is_displayed() for e in panel.find_elements(By.CSS_SELECTOR, ".post-review-badge, .campaign-openers__review-note")), "editor_no_change_badges_or_notes")
        screenshot("creation-editor-loaded")
        result["status"] = "PASS"
        result["stage"] = "complete"
    except Exception as error:
        # Raw WebDriver errors/DOM/page source may contain private values.
        result["error_type"] = type(error).__name__
        if isinstance(error, AssertionError):
            result["error_code"] = str(error)
        if driver is not None:
            try:
                driver.save_screenshot(str(output / "failure.png"))
            except Exception:
                result["failure_screenshot"] = "UNAVAILABLE"
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                result["cleanup"] = "DRIVER_QUIT_FAILED"
                result["status"] = "FAIL"
        (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Private JSON path; never print its contents")
    parser.add_argument("--output", required=True, help="New private output directory; encrypt before uploading")
    parser.add_argument("--browser", choices=("edge", "chrome"), required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--driver", required=True)
    raise SystemExit(run(parser.parse_args()))
