"""Real-browser, read-only queue/plan smoke in a dedicated user4 session."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import urlparse

BASE = 'https://hotfix.turbot.pro'
VERSION = '0.12.4.0'


def require(value, code):
    if not value:
        raise AssertionError(code)


def configuration(path):
    data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    require(data.get('url') == BASE and data.get('expected_version') == VERSION, 'WRONG_TARGET')
    require(data.get('queue_account_inactive_verified') is True and data.get('dedicated_disposable_user4_session_verified') is True, 'DEDICATED_INACTIVE_ACCOUNT_REQUIRED')
    cookie = data['queue_session_cookie']
    require(cookie.get('name') in ('SESSION', 'JSESSIONID') and isinstance(cookie.get('value'), str) and 0 < len(cookie['value']) < 4096, 'BAD_COOKIE')
    require(type(data.get('queue_campaign_id')) is int and data['queue_campaign_id'] > 0 and data['queue_campaign_id'] not in (237, 242), 'OWN_QUEUE_FIXTURE_REQUIRED')
    require(data.get('queue_fixture_tag') == '[TEST] 0.12.4.0 queue b7a46c8d-209e-4f30-a65d-4bbdebc6fbdf', 'OWN_QUEUE_FIXTURE_REQUIRED')
    rows = data['queue_rows']
    require(isinstance(rows, list) and len(rows) == 3 and len({row['id'] for row in rows}) == 3, 'BASELINE_CHANGED')
    require([row['mode'] for row in rows] == ['QUICK_REFRESH', 'DISCOVER_GROUPS', 'REFRESH'], 'BASELINE_MODES_CHANGED')
    require([row['period'] for row in rows] == [1, 24, 24] and all(row['campaign'] == data.get('queue_campaign_id') for row in rows), 'BASELINE_SCOPE_CHANGED')
    return data


def run(args):
    data = configuration(args.input)
    from selenium import webdriver
    from selenium.webdriver.chrome.service import Service
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    output = Path(args.output)
    output.mkdir(exist_ok=False)
    result = dict(kind='automated-queue-browser-smoke', version=VERSION, status='FAIL', checks=[],
                  not_run=['modal_placement', 'two_second_refresh', 'mobile', 'bot_start'])
    driver = None
    try:
        options = webdriver.ChromeOptions()
        options.binary_location = args.binary
        for flag in ('--headless=new', '--window-size=1440,1000', '--no-first-run', '--disable-logging'):
            options.add_argument(flag)
        service = Service(executable_path=args.driver, log_output=os.devnull)
        if os.name == 'nt':
            import subprocess
            service.creation_flags = subprocess.CREATE_NO_WINDOW
        driver = webdriver.Chrome(service=service, options=options)
        driver.set_page_load_timeout(45)
        wait = WebDriverWait(driver, 30)

        def check(value, code):
            require(value, code)
            result['checks'].append(dict(id=code, status='PASS'))

        def page(path, full=True):
            driver.get(BASE + path)
            wait.until(lambda d: d.execute_script('return document.readyState') == 'complete')
            location = urlparse(driver.current_url)
            require(location.scheme == 'https' and location.netloc == 'hotfix.turbot.pro' and location.path == path.split('?')[0], 'UNEXPECTED_DESTINATION')
            require(not any(e.is_displayed() for e in driver.find_elements(By.CSS_SELECTOR, '#loginForm #password, #aiContentApproval')), 'UNEXPECTED_AUTH_OR_APPROVAL')
            from browser_startup import dismiss_startup
            dismiss_startup(driver, wait, By, EC)
            if full:
                footer = wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, '.app-footer')))
                require(re.findall(r'(?<![\d.])\d+\.\d+\.\d+\.\d+(?![\d.])', footer.get_attribute('textContent')) == [VERSION], 'WRONG_LIVE_VERSION')

        driver.get(BASE + '/robots.txt')
        cookie = data['queue_session_cookie']
        driver.add_cookie(dict(name=cookie['name'], value=cookie['value'], path='/', secure=True, httpOnly=True, sameSite='Lax'))
        page('/user')
        check(driver.find_element(By.ID, 'currentUserId').get_attribute('value') == '4', 'queue_session_owner')
        page('/facebookTasksQueue?campaign=' + str(data['queue_campaign_id']))
        check(len(driver.find_elements(By.CSS_SELECTOR, '#recurring_tasks_queue ~ #scheduled_tasks_queue')) == 1, 'recurring_before_scheduled')
        rows = wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, '#recurring_tasks_queue table tbody > tr'))
        check([row.get_attribute('id') for row in rows] == ['task__' + str(row['id']) for row in data['queue_rows']], 'complete_fresh_sql_queue_rows')
        translated = ['Sprawdzam kto odpisa\u0142', 'Szukanie nowych grup na Facebooku', 'Aktualizacja status\u00f3w']
        for element, expected, mode in zip(rows, data['queue_rows'], translated):
            cells = element.find_elements(By.CSS_SELECTOR, 'td')
            check(len(cells) >= 8 and cells[3].text.strip() == mode and cells[5].text.strip() == expected['displayed_start'] and cells[6].text.strip() == str(expected['period']), 'queue_row_' + expected['mode'])
        require(driver.save_screenshot(str(output / 'queue-loaded.png')), 'SCREENSHOT_FAILED')
        page('/showProgressModal?portal=facebook', full=False)
        rows = wait.until(lambda d: d.find_elements(By.CSS_SELECTOR, 'body > div > section table tbody > tr'))
        check(len(rows) == len(data['queue_rows']), 'complete_plan_rows')
        for element, expected, mode in zip(rows, data['queue_rows'], translated):
            cells = [cell.text.strip() for cell in element.find_elements(By.CSS_SELECTOR, 'td')]
            check(len(cells) == 6 and cells[0] == expected['campaign_name'] and bool(cells[1]) and cells[2] == mode and cells[3] == '\u2014' and cells[4] == expected['displayed_start'] and cells[5] == str(expected['period']), 'plan_row_' + expected['mode'])
        check(not driver.find_elements(By.CSS_SELECTOR, 'body > div > section button, body > div > section a[href], body > div > section input, body > div > section form'), 'plan_is_read_only')
        result['active_task_tables'] = len(driver.find_elements(By.CSS_SELECTOR, 'body > div > table'))
        require(driver.save_screenshot(str(output / 'queue-progress-plan.png')), 'SCREENSHOT_FAILED')
        result['status'] = 'PASS'
    except Exception as error:
        result['error_type'] = type(error).__name__
        if isinstance(error, AssertionError):
            result['error_code'] = str(error)
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                result['status'] = 'FAIL'
                result['cleanup'] = 'DRIVER_QUIT_FAILED'
        (output / 'result.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf8')
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for flag in ('input', 'output', 'binary', 'driver'):
        parser.add_argument('--' + flag, required=True)
    raise SystemExit(run(parser.parse_args()))
