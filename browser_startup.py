"""Use only the test user's reversible startup dismiss controls."""
def dismiss_startup(driver, wait, By, EC):
    for button in driver.find_elements(By.CSS_SELECTOR, '.leadya-onboarding-bubble__close'):
        if button.is_displayed():
            button.click()
    flags = driver.find_elements(By.ID, 'show-terms-update-modal-flag')
    if flags and flags[0].get_attribute('value') == 'true':
        modal = wait.until(EC.visibility_of_element_located((By.ID, 'termsUpdateModal')))
        later = modal.find_element(By.ID, 'termsUpdateLaterButton')
        if not later.is_displayed() or not later.is_enabled():
            raise AssertionError('TERMS_DEFERRAL_UNAVAILABLE')
        later.click()
        wait.until(EC.invisibility_of_element_located((By.ID, 'termsUpdateModal')))
