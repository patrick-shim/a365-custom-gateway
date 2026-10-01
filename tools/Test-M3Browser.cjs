'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

const args = process.argv.slice(2);
const option = name => args[args.indexOf(name) + 1];

async function main({ milestone = 'M3', journeys } = {}) {
  assert.ok(['M3', 'M4'].includes(milestone), 'Unsupported browser acceptance scope');
  if (args.includes('--help')) {
    console.log('node .\\tools\\Test-M3Browser.cjs --origin <printed loopback fixture URL> --playwright <package directory> --chrome <installed Chrome executable>');
    return;
  }
  for (const name of ['--origin', '--playwright', '--chrome']) {
    assert.ok(args.includes(name) && option(name), `Required option: ${name}`);
  }
  const target = new URL(option('--origin'));
  assert.equal(target.hostname, '127.0.0.1', 'Only the owned loopback browser fixture is allowed');
  assert.ok(['http:', 'https:'].includes(target.protocol) && !target.username && !target.password &&
    target.pathname === '/' && !target.search && !target.hash, 'Invalid fixture origin');
  const origin = target.origin;
  const socketOrigin = origin.replace(/^http/, 'ws');
  async function api(route, body) {
    const response = await fetch(`${origin}/__fixture/${route}`, {
      method: body ? 'POST' : 'GET',
      headers: body ? { 'Content-Type': 'application/json', 'X-Browser-Fixture': '1' } : {},
      body: body ? JSON.stringify(body) : undefined,
      redirect: 'error',
      signal: AbortSignal.timeout(15000)
    });
    assert.ok(response.ok, `Fixture ${route} returned HTTP ${response.status}`);
    return response.json();
  }
  const health = await api('health');
  assert.equal(health.synthetic, true, 'This is not a synthetic test host');
  assert.equal(health.componentAssembly, 'Gateway.AdminUi', 'The real production UI is required');
  assert.deepEqual(health.configurationSources, ['MemoryConfigurationSource'], 'Ambient host configuration was loaded');
  const catalog = await api('catalog');
  assert.equal(catalog.fleet.total, 237);
  assert.equal(catalog.fleet.filter.total, 137);

  const output = path.resolve(__dirname, '..', '.test-work', `${milestone.toLowerCase()}-browser-${randomUUID()}`);
  fs.mkdirSync(output, { recursive: true });
  const profile = path.join(output, 'chrome-profile');
  console.log(`${milestone}_BROWSER_ARTIFACTS ${output}`);
  const { chromium } = require(path.resolve(option('--playwright')));
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: option('--chrome'), headless: true,
    ignoreHTTPSErrors: target.protocol === 'https:',
    viewport: { width: 1440, height: 1000 }, reducedMotion: 'reduce',
    serviceWorkers: 'block', args: ['--lang=en-US']
  });
  const blocked = [], scriptErrors = [], consoleErrors = [];
  const expectedConsoleRules = [], expectedConsoleErrors = [];
  let page, checks = 0, current = '';
  const state = async () => (await api('state')).fixture;
  const counter = async name => (await state()).counters[name] || 0;
  async function poll(action, predicate, label, timeout = 15000) {
    const until = Date.now() + timeout;
    while (Date.now() < until) {
      const value = await action();
      if (predicate(value)) return value;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.fail(`Timed out: ${label}`);
  }
  async function isolated() {
    const result = await api('state');
    assert.deepEqual(result.fixture.unexpectedCalls, [], `${current}: unscripted API calls`);
    for (const name of ['httpAttempts', 'clientFactoryAttempts', 'tokenAttempts', 'runtimeAttempts']) {
      assert.equal(result.guards[name], 0, `${current}: ${name}`);
    }
    for (const name of ['realNetworkFallback', 'realAuthentication', 'productionHostConfiguration']) {
      assert.equal(result.guards[name], false, `${current}: ${name}`);
    }
  }
  async function reset(scenario, role = 'Administrator', width = 1440) {
    if (page && !page.isClosed()) await page.close();
    await isolated();
    await api('reset', { scenario, role, mutationDelayMs: 500 });
    current = `${scenario}/${role}/${width}`;
    page = await context.newPage();
    page.setDefaultTimeout(15000);
    await page.setViewportSize({ width, height: 1000 });
    page.on('pageerror', error => scriptErrors.push(`${current}: ${error.message}`));
    page.on('console', message => {
      if (message.type() === 'error') {
        const expected = expectedConsoleRules.find(rule => rule.scenario === current && rule.remaining > 0 &&
          message.location().url.startsWith(origin + rule.path) && rule.pattern.test(message.text()));
        if (expected) {
          expected.remaining--;
          expectedConsoleErrors.push(`${current}: expected fixture HTTP failure`);
          return;
        }
        consoleErrors.push(`${current}: ${message.text()}`);
      }
    });
    return state();
  }
  async function go(route) {
    const response = await page.goto(`${origin}${route}`);
    assert.ok(response && response.status() < 400, `${current}: ${route} did not render`);
    await page.locator('.page-header[aria-busy="false"]').waitFor();
    await page.waitForFunction(() => customElements.get('fluent-button') && document.querySelector('fluent-button')?.shadowRoot);
  }
  async function inspect(label) {
    const issues = await page.evaluate(() => {
      const failures = [];
      if (document.querySelectorAll('main h1').length !== 1) failures.push('main heading');
      if (document.documentElement.scrollWidth > innerWidth + 1) failures.push('horizontal page overflow');
      const ids = [...document.querySelectorAll('[id]')].map(element => element.id);
      if (ids.length !== new Set(ids).size) failures.push('duplicate IDs');
      for (const field of document.querySelectorAll('input,select,textarea')) {
        if (field.type === 'hidden' || !field.getClientRects().length) continue;
        if (!(field.labels?.length || field.getAttribute('aria-label') || field.getAttribute('aria-labelledby')))
          failures.push(`unlabelled field ${field.id}`);
      }
      return failures;
    });
    assert.deepEqual(issues, [], `${current}/${label}`);
    assert.ok((await page.locator('main').ariaSnapshot()).includes('heading'));
    checks++;
  }
  async function modal(title) {
    const dialog = page.getByRole('alertdialog', { name: title, exact: true });
    await dialog.waitFor();
    for (const key of ['Tab', 'Shift+Tab']) {
      for (let index = 0; index < 6; index++) {
        await page.keyboard.press(key);
        const focus = await dialog.evaluate(element => {
          const host = element.closest('fluent-dialog');
          let active = document.activeElement;
          const inside = host?.contains(active) || host === active;
          while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
          const box = active?.getBoundingClientRect();
          return { inside, visible: active?.matches(':focus-visible'), inView: box &&
            box.left >= -1 && box.top >= -1 && box.right <= innerWidth + 1 && box.bottom <= innerHeight + 1 };
        });
        assert.ok(focus.inside && focus.visible && focus.inView, `${current}/${title}: ${key} focus escaped or was hidden`);
      }
    }
    checks++;
    return dialog;
  }
  async function capture(name) {
    const cdp = await context.newCDPSession(page);
    try {
      const metrics = await cdp.send('Page.getLayoutMetrics');
      const file = path.join(output, `${name}.png`);
      if (metrics.cssVisualViewport.zoom > 1) {
        const result = await cdp.send('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
        fs.writeFileSync(file, Buffer.from(result.data, 'base64'));
      } else {
        await page.screenshot({ path: file, fullPage: await page.getByRole('alertdialog').count() === 0 });
      }
    } finally { await cdp.detach(); }
  }
  async function fillRegistration(mode = 'UseExisting', name = 'Chrome fixture agent') {
    await page.locator('#registration-form[aria-busy="false"]').waitFor();
    await page.locator('#agent-name').fill(name);
    await page.locator('#blueprint-mode').selectOption(mode);
    if (mode === 'CreateNew') await page.locator('#new-blueprint-display-name').fill('Chrome shared blueprint');
    else await page.locator('#existing-blueprint').selectOption((await state()).blueprintId);
  }
  async function create(mode = 'UseExisting') {
    await fillRegistration(mode);
    const id = await page.locator('#external-agent-id').inputValue();
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await modal('Review registration');
    assert.equal(await counter('RegisterAgentAsync'), 0, 'Review created a registration');
    await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
    return id;
  }
  async function acknowledgeKey() {
    await page.locator('#saved-gateway-key').check();
    await page.getByRole('button', { name: 'Continue to agent setup', exact: true }).click();
    await page.waitForURL('**/operations/*');
    await page.locator('.page-header[aria-busy="false"]').waitFor();
  }
  async function tabTo(locator, label) {
    await locator.waitFor();
    for (let index = 0; index < 80; index++) {
      if (await locator.evaluate(element => {
        let active = document.activeElement;
        while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
        return active === element;
      })) return;
      await page.keyboard.press('Tab');
    }
    assert.fail(`Keyboard did not reach ${label}`);
  }
  async function zoomTo200Percent() {
    const unzoomed = await page.evaluate(() => ({ width: innerWidth, pixelRatio: devicePixelRatio }));
    const settings = await context.newPage();
    await settings.goto('chrome://settings/appearance');
    await settings.getByRole('combobox', { name: 'Page zoom', exact: true }).selectOption('2');
    await settings.close();
    await page.waitForFunction(before => Math.abs(devicePixelRatio - before.pixelRatio * 2) < 0.01 &&
      Math.abs(innerWidth - before.width / 2) <= 1 && visualViewport.scale === 1, unzoomed);
    const zoomCdp = await context.newCDPSession(page);
    assert.equal((await zoomCdp.send('Page.getLayoutMetrics')).cssVisualViewport.zoom, 2);
    await zoomCdp.detach();
  }
  try {
    for (const tab of context.pages()) await tab.close();
    await context.route('**/*', route => {
      if (new URL(route.request().url()).origin === origin) return route.continue();
      blocked.push(route.request().url().split('?')[0]);
      return route.abort();
    });
    await context.routeWebSocket('**/*', socket => {
      if (new URL(socket.url()).origin === socketOrigin) socket.connectToServer();
      else { blocked.push(socket.url().split('?')[0]); socket.close(); }
    });

    if (journeys) {
      await journeys({
        api, catalog, context, state, counter, poll, isolated, reset, go, inspect, modal, capture,
        tabTo, zoomTo200Percent, page: () => page, pass: () => { checks++; }, origin,
        expectConsoleError: (path, pattern) => expectedConsoleRules.push({ scenario: current, path, pattern, remaining: 1 })
      });
    } else {
    for (const width of [1440, 390, 360]) {
      for (const role of catalog.roles) {
        for (const scenario of ['empty', 'fleet', 'read-error']) {
          await reset(scenario, role, width);
          for (const route of ['/setup', '/dashboard', '/agents']) {
            await go(route);
            await inspect(route);
          }
        }
      }
    }

    await reset('fleet');
    await go('/dashboard');
    assert.ok(!(await page.locator('main').innerText()).includes('Gateway health checks need attention'),
      'Healthy liveness and Ready readiness were treated as unhealthy');
    for (const [name, count] of [['registered', '237'], ['active', '177'], ['action-required', '30']]) {
      assert.equal((await page.locator(`[data-count="${name}"] .metric-value`).innerText()).trim(), count);
    }
    assert.equal(await page.locator('aside .nav-link').first().evaluate(element => getComputedStyle(element).display), 'flex');
    await capture('overview-desktop');
    await go('/agents');
    const seen = [];
    for (const [index, expected] of [100, 100, 37].entries()) {
      await page.getByText(`${index * 100 + 1}\u2013${Math.min((index + 1) * 100, 237)} of 237 agents`, { exact: true }).waitFor();
      await poll(() => page.locator('tbody tr').count(), value => value === expected, 'fleet page size');
      const links = await page.locator('tbody tr a[href^="/agents/"]').evaluateAll(elements => elements.map(element => element.getAttribute('href')));
      seen.push(...links);
      if (expected !== 37) await page.getByRole('button', { name: 'Next', exact: true }).click();
    }
    assert.equal(new Set(seen).size, 237, 'Fleet paging lost or repeated registrations');
    assert.equal(await page.getByRole('button', { name: 'Next', exact: true }).isDisabled(), true);
    await page.getByRole('button', { name: 'Previous', exact: true }).click();
    await poll(() => page.locator('tbody tr').count(), value => value === 100, 'previous page');
    await page.locator('#agent-search').fill('invoice-eu');
    await page.locator('#agent-status').selectOption('Active');
    await page.locator('#agent-environment').selectOption('Development');
    await page.getByRole('button', { name: 'Search', exact: true }).click();
    await page.getByText(/1.100 of 137/).waitFor();
    await page.getByRole('button', { name: 'Next', exact: true }).click();
    await poll(() => page.locator('tbody tr').count(), value => value === 37, 'filtered final page');
    assert.equal(await page.locator('#agent-status').inputValue(), 'Active');
    assert.equal(await page.locator('#agent-environment').inputValue(), 'Development');
    await page.getByRole('button', { name: 'Clear', exact: true }).click();
    await page.locator('#agent-search').fill('Auxiliary');
    await page.getByRole('button', { name: 'Search', exact: true }).click();
    await page.getByText(/1.100 of 100/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Next', exact: true }).isDisabled(), true);
    checks += 5;

    await reset('unknown-total');
    await go('/dashboard');
    for (const name of ['registered', 'active', 'action-required']) {
      assert.equal((await page.locator(`[data-count="${name}"] .metric-value`).innerText()).trim(), 'Unavailable');
    }
    await go('/agents');
    assert.ok((await page.locator('main').innerText()).toLowerCase().includes('unavailable'));
    checks++;
    await reset('cursor-error');
    await go('/agents?search=invoice-eu&status=Active&environment=Development');
    await page.getByRole('button', { name: 'Next', exact: true }).click();
    await page.getByRole('button', { name: 'Restart list', exact: true }).click();
    await page.getByText(/1.100 of 137/).waitFor();
    assert.equal(await page.locator('#agent-search').inputValue(), 'invoice-eu');
    checks++;

    for (const [mode, width] of [['UseExisting', 1440], ['CreateNew', 390]]) {
      await reset('operation-auto', 'Administrator', width);
      await go('/setup');
      await page.getByRole('link', { name: 'Register agent', exact: true }).first().click();
      await page.locator('.page-header[aria-busy="false"]').waitFor();
      const externalId = await create(mode);
      await page.locator('#gateway-api-key').waitFor();
      const key = await page.locator('#gateway-api-key').inputValue();
      assert.ok(key.length > 0 && !page.url().includes(key));
      assert.equal(await counter('RegisterAgentAsync'), 1);
      assert.equal(await counter('CompleteAgent365RegistrationAsync'), 0, 'Registry ran before key saving');
      assert.equal(await page.getByRole('button', { name: 'Continue to agent setup', exact: true }).isDisabled(), true);
      const storage = await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }));
      assert.ok(!storage.includes(key), 'One-time key persisted in browser storage');
      await page.getByText('View a non-secret connection example', { exact: true }).click();
      assert.ok(!(await page.locator('textarea').inputValue()).includes(key));
      assert.ok((await page.locator('textarea').inputValue()).includes(externalId));
      await page.evaluate(() => {
        window.fixtureClipboardOriginal = navigator.clipboard.writeText;
        navigator.clipboard.writeText = async value => { window.fixtureClipboardValue = value; };
      });
      await page.getByRole('button', { name: 'Copy One-time Gateway key', exact: true }).click();
      await page.getByText('Copied to clipboard.', { exact: true }).waitFor();
      assert.equal(await page.evaluate(() => window.fixtureClipboardValue), key);
      await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw new Error('Synthetic clipboard denial'); }; });
      await page.getByRole('button', { name: 'Copy One-time Gateway key', exact: true }).click();
      await page.getByText('Copy is unavailable. Select the text and copy it manually.', { exact: true }).waitFor();
      await page.evaluate(() => {
        navigator.clipboard.writeText = window.fixtureClipboardOriginal;
        delete window.fixtureClipboardOriginal; delete window.fixtureClipboardValue;
      });
      if (width < 850) await page.getByLabel('Toggle navigation').check();
      await page.getByRole('link', { name: 'Agents', exact: true }).click();
      await modal('Leave without saving the key?');
      await page.keyboard.press('Escape');
      await page.getByRole('alertdialog', { name: 'Leave without saving the key?', exact: true }).waitFor({ state: 'hidden' });
      assert.equal(await page.locator('#gateway-api-key').inputValue(), key);
      await inspect('one-time key');
      await capture(`key-handoff-${width}`);
      await acknowledgeKey();
      await page.getByText('This setup operation completed.', { exact: true }).waitFor();
      assert.equal(await counter('CompleteAgent365RegistrationAsync'), 1);
      assert.equal(await page.locator('#gateway-api-key').count(), 0);
      await page.reload();
      await page.locator('.page-header[aria-busy="false"]').waitFor();
      assert.equal(await counter('CompleteAgent365RegistrationAsync'), 1, 'Reopen repeated Registry completion');
      checks += 4;
    }

    for (const scenario of ['registration-unknown', 'registration-no-key']) {
      await reset(scenario);
      await go('/agents/register');
      const id = await create();
      await page.getByRole('heading', { name: 'Registration result needs checking', exact: true }).waitFor();
      assert.equal(await page.locator('#gateway-api-key').count(), 0);
      await page.reload();
      await page.locator('.page-header[aria-busy="false"]').waitFor();
      assert.equal(await page.locator('#registration-form').count(), 0);
      assert.equal(await page.locator('#registration-recovery-id').inputValue(), id);
      await page.getByRole('button', { name: 'Check existing registration', exact: true }).click();
      await page.getByRole('link', { name: 'Open registered agent', exact: true }).waitFor();
      assert.equal(await counter('RegisterAgentAsync'), 1);
      checks++;
    }

    await reset('empty');
    await go('/agents/register');
    await fillRegistration();
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await page.evaluate(() => {
      const retain = window.A365Gateway.retainRegistrationRecovery;
      window.A365Gateway.retainRegistrationRecovery = (...args) => new Promise(resolve => {
        window.fixtureReleaseRecovery = () => resolve(retain(...args));
      });
    });
    await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
    await page.waitForFunction(() => typeof window.fixtureReleaseRecovery === 'function');
    assert.equal(await counter('RegisterAgentAsync'), 0, 'Creation ran before client recovery acknowledgment');
    await page.evaluate(() => { window.fixtureReleaseRecovery(); delete window.fixtureReleaseRecovery; });
    await page.locator('#gateway-api-key').waitFor();
    assert.ok(page.url().includes('pendingExternalId='));
    assert.equal(await counter('RegisterAgentAsync'), 1);
    checks++;

    await reset('empty');
    await go('/agents/register');
    await fillRegistration();
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await page.evaluate(() => { window.A365Gateway.retainRegistrationRecovery = () => false; });
    await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
    await page.getByText(/The recovery reference could not be retained/).waitFor();
    assert.equal(await counter('RegisterAgentAsync'), 0);
    assert.equal(await page.locator('#gateway-api-key').count(), 0);
    checks++;

    await reset('empty');
    await go('/agents/register');
    await fillRegistration();
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await page.evaluate(() => {
      window.A365Gateway.retainRegistrationRecovery = () => new Promise(() => {
        window.fixtureRetentionWaiting = true;
      });
    });
    await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
    await page.waitForFunction(() => window.fixtureRetentionWaiting === true);
    await page.close();
    assert.equal(await counter('RegisterAgentAsync'), 0, 'Closing before acknowledgment created a registration');
    checks++;

    for (const scenario of ['operation-manual', 'operation-consent', 'operation-claims', 'operation-unknown', 'operation-unknown-committed']) {
      const world = await reset(scenario);
      await go(`/operations/${world.primaryOperationId}`);
      assert.equal(await counter('CompleteAgent365RegistrationAsync'), 0);
      await page.getByRole('button', { name: 'Complete Agent 365 registration', exact: true }).click();
      await modal('Complete Agent 365 registration?');
      await page.getByRole('button', { name: 'Complete registration', exact: true }).click();
      await poll(() => counter('CompleteAgent365RegistrationAsync'), value => value === 1, 'manual Registry action');
      if (scenario === 'operation-manual') {
        await page.getByText('This setup operation completed.', { exact: true }).waitFor();
      } else if (scenario === 'operation-consent' || scenario === 'operation-claims') {
        await page.getByRole('link', { name: 'Sign in and return to this operation', exact: true }).waitFor();
        const href = await page.getByRole('link', { name: 'Sign in and return to this operation', exact: true }).getAttribute('href');
        assert.ok(href.includes(encodeURIComponent(`/operations/${world.primaryOperationId}`)));
      } else {
        await page.getByRole('heading', { name: 'The Registry result is not confirmed', exact: true }).waitFor();
        await page.getByRole('button', { name: 'Check existing operation', exact: true }).click();
        if (scenario.endsWith('committed')) await page.getByText('This setup operation completed.', { exact: true }).waitFor();
        else await page.getByRole('heading', { name: 'The Registry result is not confirmed', exact: true }).waitFor();
      }
      assert.equal(await counter('CompleteAgent365RegistrationAsync'), 1);
      checks++;
    }

    for (const role of ['Operator', 'Auditor', 'SupportReader']) {
      const world = await reset('operation-manual', role);
      await go(`/agents/${world.primaryAgentId}`);
      assert.equal(await page.getByRole('button', { name: 'Issue replacement key', exact: true }).count(), 0);
      assert.equal(await page.locator('#history-heading').count(), role === 'Operator' ? 1 : 0);
      assert.equal(await page.locator('#audit-heading').count(), role === 'Auditor' ? 1 : 0);
      const response = await page.request.get(`${origin}/agents/register`);
      assert.equal(response.status(), 403, 'Direct protected route was not forbidden');
      await page.evaluate(() => {
        const link = document.createElement('a');
        link.href = '/agents/register';
        link.textContent = 'Fixture link to restricted registration';
        link.id = 'fixture-restricted-link';
        document.querySelector('#main-content').append(link);
      });
      await page.locator('#fixture-restricted-link').click();
      await page.getByRole('heading', { name: 'This task needs another role', exact: true }).waitFor();
      assert.equal(await page.locator('#registration-form').count(), 0);
      checks++;
    }

    const lifecycle = await reset('fleet', 'Administrator', 390);
    await go(`/agents/${lifecycle.primaryAgentId}`);
    const credentials = page.locator('section[aria-labelledby="gateway-credentials-heading"]');
    const oldKeyId = (await credentials.locator('tbody tr').first().locator('code').innerText()).trim();
    assert.equal(await page.getByRole('button', { name: `Revoke Gateway key ${oldKeyId}`, exact: true }).isDisabled(), true);
    await page.getByRole('button', { name: 'Issue replacement key', exact: true }).click();
    await modal('Issue a replacement key?');
    await page.getByRole('button', { name: 'Issue replacement', exact: true }).click();
    await page.locator('#gateway-api-key').waitFor();
    const replacement = await page.locator('#gateway-api-key').inputValue();
    assert.equal(await counter('IssueAgentIngressCredentialAsync'), 1);
    assert.equal(await counter('RevokeAgentIngressCredentialAsync'), 0);
    await inspect('replacement handoff');
    await page.locator('#saved-gateway-key').check();
    await page.getByRole('button', { name: 'Return to agent', exact: true }).click();
    await page.getByRole('button', { name: 'Issue replacement key', exact: true }).waitFor();
    assert.equal(await page.locator('#gateway-api-key').count(), 0);
    assert.ok(!(await page.content()).includes(replacement), 'A dismissed replacement key remained in the page');
    await page.getByRole('button', { name: `Revoke Gateway key ${oldKeyId}`, exact: true }).click();
    await modal('Revoke this Gateway key?');
    assert.equal(await page.getByRole('button', { name: 'Revoke key', exact: true }).isDisabled(), true);
    await page.locator('#replacement-installed').check();
    await page.getByRole('button', { name: 'Revoke key', exact: true }).click();
    await poll(() => counter('RevokeAgentIngressCredentialAsync'), value => value === 1, 'old-key revocation');
    await page.getByText('Selected Gateway key revoked. Other usable credentials were not revoked.', { exact: true }).waitFor();
    await inspect('revoked key metadata');
    await capture('agent-details-narrow');
    await page.getByRole('button', { name: 'Delete Gateway registration', exact: true }).click();
    const deletion = await modal('Delete this Gateway registration?');
    assert.ok((await deletion.innerText()).includes('Microsoft Entra identities, Agent 365 registrations, shared Purview policies and external hosting remain'));
    await page.keyboard.press('Escape');
    assert.equal(await counter('DeleteAgentAsync'), 0);
    checks += 3;

    const unknownKey = await reset('credential-unknown');
    await go(`/agents/${unknownKey.primaryAgentId}`);
    await page.getByRole('button', { name: 'Issue replacement key', exact: true }).click();
    await page.getByRole('button', { name: 'Issue replacement', exact: true }).click();
    await page.getByText('Check the existing result before another action.', { exact: true }).waitFor();
    assert.equal(await page.locator('#gateway-api-key').count(), 0);
    assert.equal(await page.getByRole('button', { name: 'Issue replacement key', exact: true }).isDisabled(), true);
    await page.getByRole('button', { name: 'Check agent and credential status', exact: true }).click();
    await poll(() => page.getByRole('button', { name: 'Issue replacement key', exact: true }).isEnabled(), value => value, 'credential readback');
    assert.equal(await counter('IssueAgentIngressCredentialAsync'), 1);
    checks++;

    const operator = await reset('fleet', 'Operator');
    await go(`/agents/${operator.primaryAgentId}`);
    await page.getByRole('button', { name: 'Disable agent', exact: true }).click();
    await modal('Disable this agent?');
    await page.getByRole('button', { name: 'Disable', exact: true }).click();
    await page.getByText('Disable request accepted. Current status: Disabled.', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Enable agent', exact: true }).click();
    await page.getByRole('button', { name: 'Enable', exact: true }).click();
    await page.getByText('Enable request accepted. Current status: Active.', { exact: true }).waitFor();
    assert.equal(await counter('GetAgentIngressCredentialsAsync'), 0);
    assert.equal(await counter('GetAgentAuditEventsAsync'), 0);
    checks++;

    await reset('operation-auto', 'Administrator', 360);
    await go('/setup');
    await tabTo(page.getByRole('link', { name: 'Register agent', exact: true }).first(), 'registration entry');
    await page.keyboard.press('Enter');
    await page.locator('#registration-form[aria-busy="false"]').waitFor();
    await tabTo(page.locator('#agent-name'), 'agent name');
    await page.keyboard.type('Keyboard-only fixture agent');
    await tabTo(page.locator('#blueprint-mode'), 'blueprint mode');
    await page.keyboard.press('End');
    await page.keyboard.press('Tab');
    await page.locator('#new-blueprint-display-name').waitFor();
    await tabTo(page.locator('#new-blueprint-display-name'), 'new blueprint name');
    await page.keyboard.type('Keyboard fixture blueprint');
    await tabTo(page.getByRole('button', { name: 'Review registration', exact: true }), 'registration review');
    await page.keyboard.press('Enter');
    await modal('Review registration');
    await tabTo(page.getByRole('button', { name: 'Register and show key', exact: true }), 'registration confirmation');
    await page.keyboard.press('Enter');
    await page.locator('#gateway-api-key').waitFor();
    await tabTo(page.locator('#saved-gateway-key'), 'saved-key acknowledgment');
    await page.keyboard.press('Space');
    await tabTo(page.getByRole('button', { name: 'Continue to agent setup', exact: true }), 'Registry handoff');
    await page.keyboard.press('Enter');
    await page.waitForURL('**/operations/*');
    await page.getByText('This setup operation completed.', { exact: true }).waitFor();
    assert.equal(await counter('RegisterAgentAsync'), 1);
    assert.equal(await counter('CompleteAgent365RegistrationAsync'), 1);
    await inspect('keyboard-only completed journey');
    checks++;

    await reset('operation-auto');
    await go('/agents/register');
    await page.locator('#existing-blueprint').selectOption((await state()).blueprintId);
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await page.locator('#agent-name.invalid').waitFor();
    await page.waitForFunction(() => document.activeElement.id === 'agent-name');
    assert.equal(await counter('RegisterAgentAsync'), 0);
    await fillRegistration();
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await page.getByRole('button', { name: 'Register and show key', exact: true }).dblclick();
    await page.locator('#gateway-api-key').waitFor();
    assert.equal(await counter('RegisterAgentAsync'), 1, 'Double click created two registrations');
    checks++;

    await reset('empty');
    await go('/setup');
    await zoomTo200Percent();
    for (const scenario of ['empty', 'fleet', 'read-error']) {
      await reset(scenario);
      for (const route of ['/setup', '/dashboard', '/agents', '/agents/register']) {
        await go(route);
        await inspect(`actual 200% zoom ${route}`);
      }
    }
    await reset('operation-auto');
    await go('/agents/register');
    await fillRegistration('CreateNew');
    await page.getByRole('button', { name: 'Review registration', exact: true }).click();
    await modal('Review registration');
    await inspect('actual 200% registration review');
    await capture('registration-review-zoom-200');
    await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
    await page.locator('#gateway-api-key').waitFor();
    await inspect('actual 200% key handoff');
    await acknowledgeKey();
    await page.getByText('This setup operation completed.', { exact: true }).waitFor();
    await inspect('actual 200% operation');
    await capture('operation-zoom-200');
    }

    await isolated();
    assert.deepEqual(blocked, [], 'Browser attempted nonlocal traffic');
    assert.deepEqual(scriptErrors, [], 'Unhandled browser script errors');
    assert.deepEqual(consoleErrors, [], 'Unexpected browser console errors');
    assert.ok(checks > 0, 'No Chrome acceptance checks executed');
    console.log(`${milestone}_BROWSER_RESULT ${JSON.stringify({
      browser: context.browser().version(), checks, componentModuleId: health.componentModuleId,
      nonlocalRequests: blocked.length, scriptErrors: scriptErrors.length, consoleErrors: consoleErrors.length,
      expectedFixtureConsoleErrors: expectedConsoleErrors.length,
      output, syntheticApiAndIdentity: true, productionAuthorizationOrProviderAcceptance: false
    })}`);
  } catch (error) {
    console.error(`${milestone}_BROWSER_FAILURE ${current}: ${error.message}`);
    if (page && !page.isClosed()) {
      await capture('failure');
      if (await page.locator('main').count()) console.error((await page.locator('main').ariaSnapshot()).slice(0, 5000));
    }
    throw error;
  } finally {
    await context.close();
    fs.rmSync(profile, { recursive: true });
  }
}

module.exports = { runBrowserAcceptance: main };
if (require.main === module) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
