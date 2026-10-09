// Screenshot the real console with isolated sample state; no bank server needed.
const fs = require('fs');
const path = require('path');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
(async () => {
  const browser = await chromium.launch({headless: true, channel: 'chrome'});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 1050}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('http://beyondnet-preview.local/**', async route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/api/admin/state') {
        return route.fulfill({json: state});
      }
      const allowed = {'/': ['bank/static/index.html', 'text/html'],
        '/static/style.css': ['bank/static/style.css', 'text/css'],
        '/static/app.js': ['bank/static/app.js', 'text/javascript']};
      const asset = allowed[url.pathname];
      if (!asset) return route.fulfill({status: 404});
      return route.fulfill({body: fs.readFileSync(path.join(root, asset[0])), contentType: asset[1]});
    });
    await page.goto('http://beyondnet-preview.local/');
    await page.locator('#admin-key').fill('sample-preview-only');
    await page.locator('#login-form button').click();
    await page.locator('#login').waitFor({state: 'hidden'});
    if (await page.title() !== 'BeyondNet · Bank Console') throw Error('Wrong brand title');
    await page.screenshot({path: path.join(root, 'docs/screenshots/bank-overview.png'), fullPage: true});
    await page.locator('[data-view="setup"]').click();
    await page.screenshot({path: path.join(root, 'docs/screenshots/device-setup.png'), fullPage: true});
    await page.locator('[data-view="overview"]').click();
    await page.setViewportSize({width: 390, height: 844});
    await page.screenshot({path: path.join(root, 'docs/screenshots/bank-mobile.png'), fullPage: true});
    if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)) throw Error('Mobile overflow');
    if (errors.length) throw Error(errors.join('\n'));
    console.log('BeyondNet console previews rendered; title, layout, and JS checks passed.');
  } finally {
    await browser.close();
  }
})().catch(error => {console.error(error); process.exit(1);});
