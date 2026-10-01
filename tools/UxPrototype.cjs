#!/usr/bin/env node
'use strict';

// Local design review only. Never starts a Gateway host or loads deployment state.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const repository = path.resolve(__dirname, '..');
const assets = path.join(repository, 'docs', 'ux', 'prototype');
const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  return index < 0 ? undefined : args[index + 1];
};
const types = { 'index.html': 'text/html', 'app.css': 'text/css', 'app.js': 'text/javascript' };

function createServer() {
  return http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (request.method !== 'GET' || !Object.hasOwn(types, name)) {
      response.writeHead(url.pathname === '/favicon.ico' ? 204 : 404).end();
      return;
    }
    response.writeHead(200, {
      'Content-Type': `${types[name]}; charset=utf-8`,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    });
    fs.createReadStream(path.join(assets, name)).pipe(response);
  });
}

async function main() {
  if (args.includes('--help') || (!args.includes('--serve') && !args.includes('--check'))) {
    console.log('Review: node .\\tools\\UxPrototype.cjs --serve [--port 4173] (use 0 for an available port)');
    console.log('Check:  node .\\tools\\UxPrototype.cjs --check --playwright <package directory> --chrome <installed Chrome executable>');
    return;
  }
  for (const name of Object.keys(types)) assert.ok(fs.existsSync(path.join(assets, name)), `Missing prototype asset: ${name}`);
  const server = createServer();
  const port = args.includes('--serve') ? Number(option('--port') || 4173) : 0;
  assert.ok(Number.isInteger(port) && port >= 0 && port <= 65535, 'Invalid loopback port');
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  if (args.includes('--serve')) {
    console.log(`Synthetic UX prototype: ${origin}`);
    console.log('Stop with Ctrl+C. No Gateway or Microsoft service is connected.');
    process.once('SIGINT', () => server.close());
    process.once('SIGTERM', () => server.close());
    return;
  }
  try {
    await checkPrototype(origin);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}

async function checkPrototype(origin) {
  const { chromium } = option('--playwright')
    ? require(path.resolve(option('--playwright')))
    : require('playwright');
  const chrome = option('--chrome');
  assert.ok(chrome && fs.existsSync(chrome), '--chrome must identify the installed Google Chrome executable');
  const blocked = [];
  const errors = [];
  let checks = 0;
  let matrixChecks = 0;
  let zoomChecks = 0;
  let protectionJourneyChecks = 0;
  const policyRoute = '/settings/policy?profile=profile-contoso';
  const runtimeRoute = '/settings/runtime?profile=profile-contoso';
  const views = {
    '/setup': 'Getting started',
    '/dashboard': 'Overview',
    '/agents': 'Agents',
    '/agents/register': 'Register an agent',
    '/agents/detail': 'Agent details',
    '/operations/current': 'Agent setup',
    '/handoff': 'Save your connection details',
    '/settings': 'Settings',
    '/settings/connection': 'Connect Microsoft Purview',
    '/settings/policy': 'Shared policy',
    '/settings/runtime': 'Test policy behavior',
    '/settings/defaults': 'Registration defaults',
    '/integration': 'Connect your external agent',
    '/installation': 'Install your Gateway'
  };
  const widths = [1440, 390, 360];
  const roles = ['Administrator', 'Operator', 'Auditor', 'SupportReader', 'Developer'];
  const states = ['success', 'empty', 'loading', 'error', 'restricted'];
  const screenshots = path.join(repository, '.test-work', `m2-ux-${require('node:crypto').randomUUID()}`);
  fs.mkdirSync(screenshots, { recursive: true });
  console.log(`Browser fixture screenshots: ${screenshots}`);
  const profile = path.join(screenshots, 'chrome-profile');
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: chrome,
    headless: true,
    viewport: { width: 1440, height: 1000 },
    reducedMotion: 'reduce',
    serviceWorkers: 'block',
    args: ['--lang=en-US']
  });
  const browser = context.browser();
  try {
    await context.route('**/*', route => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.origin === origin && ['/', '/index.html', '/app.js', '/app.css', '/favicon.ico'].includes(url.pathname) && request.method() === 'GET') return route.continue();
      blocked.push(request.url().split('?')[0]);
      return route.abort();
    });
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    page.on('download', () => errors.push('The synthetic prototype attempted a download'));
    page.setDefaultTimeout(6000);
    await page.goto(origin);
    await page.locator('main h1').waitFor();

    async function screen(route, role = 'Administrator', state = 'success') {
      assert.ok(Object.hasOwn(views, route.split('?')[0]), `Unknown fixture route: ${route}`);
      await page.locator('#fixture-role').selectOption(role);
      await page.locator('#fixture-state').selectOption(state);
      await page.goto(`${origin}/#${route}`);
      const expectedRoute = role === 'Developer' ? '/integration' : route;
      await page.waitForFunction(({ hash, title }) => location.hash === hash && document.title === title, {
        hash: `#${expectedRoute}`,
        title: `${views[expectedRoute.split('?')[0]]} \u00b7 A365 Gateway prototype`
      });
      await page.locator('main h1').waitFor();
    }

    async function capture(name, zoomTarget) {
      await page.locator('#toast').waitFor({ state: 'hidden' });
      const file = path.join(screenshots, `${name}.png`);
      const metrics = await cdp.send('Page.getLayoutMetrics');
      const modalOpen = await page.locator('dialog[open]').count() > 0;
      if (!modalOpen) {
        if (metrics.cssVisualViewport.zoom > 1 && zoomTarget)
          await page.locator(zoomTarget).evaluate(element => element.scrollIntoView({block:'start',behavior:'instant'}));
        else
          await page.evaluate(() => window.scrollTo({top:0,behavior:'instant'}));
      }
      if (metrics.cssVisualViewport.zoom > 1) {
        // Playwright's CSS-unit clipping can truncate or blank a browser-zoomed capture.
        const result = await cdp.send('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
        const image = Buffer.from(result.data, 'base64');
        assert.equal(image.readUInt32BE(16), metrics.layoutViewport.clientWidth, 'Zoom screenshot width does not match the native viewport');
        assert.equal(image.readUInt32BE(20), metrics.layoutViewport.clientHeight, 'Zoom screenshot height does not match the native viewport');
        fs.writeFileSync(file, image);
        return;
      }
      await page.screenshot({
        path: file,
        fullPage: !modalOpen
      });
    }

    async function tabTo(control, label) {
      for (let index = 0; index < 40; index++) {
        if (await control.evaluate(element => element === document.activeElement)) {
          assert.ok(await control.evaluate(element => element.matches(':focus-visible')), `${label}: keyboard focus is not visible`);
          return;
        }
        await page.keyboard.press('Tab');
      }
      assert.fail(`Keyboard navigation did not reach ${label}`);
    }

    async function inspect(label) {
      assert.equal(await page.locator('main h1').count(), 1, `${label}: one main heading`);
      const issues = await page.evaluate(() => {
        const failures = [];
        if (document.documentElement.scrollWidth > innerWidth + 1) failures.push('page overflow');
        const dialog = document.querySelector('dialog[open]');
        if (dialog && dialog.scrollWidth > dialog.clientWidth + 1) failures.push('dialog overflow');
        const ids = [...document.querySelectorAll('[id]')].map(element => element.id);
        if (new Set(ids).size !== ids.length) failures.push('duplicate IDs');
        for (const field of document.querySelectorAll('input, select, textarea')) {
          if (field.type === 'hidden' || !field.getClientRects().length) continue;
          if (!(field.labels?.length || field.getAttribute('aria-label') || field.getAttribute('aria-labelledby'))) failures.push(`unlabelled ${field.id || field.tagName}`);
          if (field.hasAttribute('pattern')) new RegExp(field.getAttribute('pattern'), 'v');
        }
        for (const element of document.querySelectorAll('button, a')) {
          if (!element.getClientRects().length) continue;
          if (!(element.textContent.trim() || element.getAttribute('aria-label') || element.getAttribute('aria-labelledby'))) failures.push('unnamed action');
        }
        return failures;
      });
      assert.deepEqual(issues, [], label);
      const tree = await page.locator('main').ariaSnapshot();
      assert.ok(tree.includes('heading'), `${label}: accessible heading missing`);
      checks++;
    }

    for (const width of widths) {
      await page.setViewportSize({ width, height: 1000 });
      for (const role of roles) {
        for (const state of states) {
          for (const route of Object.keys(views)) {
            await screen(route, role, state);
            await inspect(`${width}/${role}/${state}/${route}`);
            matrixChecks++;
          }
        }
      }
    }
    assert.equal(matrixChecks, widths.length * roles.length * states.length * Object.keys(views).length, 'Incomplete browser fixture matrix');
    async function reset(route = '/dashboard') {
      await page.locator('#fixture-reset').click();
      await screen(route);
    }
    async function fixtureState(task, state) {
      const selector = page.locator(`#${task}-scenario`);
      const details = selector.locator('xpath=ancestor::details');
      if (!(await details.evaluate(element => element.open))) await details.locator('summary').click();
      await selector.selectOption(state);
    }
    async function openConnectionFixtures() {
      const details = page.locator('#connection-scenario').locator('xpath=ancestor::details');
      if (!(await details.evaluate(element => element.open))) await details.locator('summary').click();
    }
    async function outcomeCheck(label, title, hasTechnical = true) {
      assert.equal(await page.locator('main h1').innerText(), title, label);
      assert.deepEqual(await page.locator('.outcome-panel dt').allTextContents(), ['What happened', 'Why this matters', 'What remains', 'Next step'], `${label}: missing outcome explanation`);
      if (hasTechnical) {
        assert.equal(await page.locator('#technical-operation summary').innerText(), 'Technical operation details');
        assert.equal(await page.locator('#technical-operation').evaluate(element => element.open), false, `${label}: technical log starts expanded`);
        assert.ok(await page.locator('.outcome-panel').evaluate(element => Boolean(element.compareDocumentPosition(document.querySelector('#technical-operation')) & Node.DOCUMENT_POSITION_FOLLOWING)), `${label}: outcome is below the technical log`);
      }
      await inspect(label);
      protectionJourneyChecks++;
    }
    async function mutationCounts() {
      return page.evaluate(() => ({
        connection: app.connectionSubmissions,
        authorizations: app.connectionAuthorizations || 0,
        policy: app.policyWrites,
        samples: app.sampleSubmissions,
        agents: app.agentFeatureWrites
      }));
    }
    async function saveMode(mode) {
      await page.locator('#policy-mode').selectOption(mode);
      await page.getByRole('button', { name: 'Review protection choices', exact: true }).click();
      await page.locator('#confirm-shared').check();
      await page.getByRole('button', { name: 'Confirm and queue shared policy', exact: true }).click();
      assert.equal(await page.locator('main h1').innerText(), 'Shared policy configuration is pending');
      await page.getByRole('button', { name: 'Check existing operation', exact: true }).click();
    }
    async function approveSamples() {
      for (const field of await page.locator('#runtime-form input[required]').all()) await field.check();
      await page.getByRole('button', { name: 'Review test', exact: true }).click();
      await page.getByRole('button', { name: 'Confirm and send approved batch', exact: true }).click();
    }
    async function protectionJourney(label, keyboard = false) {
      async function activate(control, name) {
        if (keyboard) {
          await tabTo(control, name);
          await page.keyboard.press('Enter');
        } else await control.click();
      }
      async function acknowledge(control, name) {
        if (keyboard) {
          await tabTo(control, name);
          await page.keyboard.press('Space');
        } else await control.check();
      }
      await reset('/settings/connection');
      await fixtureState('connection', 'waiting');
      const beforeAgents = await page.evaluate(() => app.agents.map(agent => ({ id:agent.id, purview:agent.purview, shield:agent.shield })));
      const original = await page.locator('#connection-reference').innerText();
      assert.equal(await page.locator('.companion-instructions li').count(), 6, `${label}: first-run trust/paste guidance changed`);
      await activate(page.getByRole('button', { name:'Use synthetic result', exact:true }), 'synthetic companion example');
      await activate(page.getByRole('button', { name:'Review companion connection', exact:true }), 'companion review');
      await modal(`${label}/companion approval`);
      assert.ok((await page.locator('#dialog').innerText()).includes(original));
      await activate(page.getByRole('button', { name:'Simulate result submission', exact:true }), 'submit reviewed companion result');
      await outcomeCheck(`${label}/pending`, 'Checking the Purview connection');
      assert.equal(await page.locator('.outcome-panel .activity-cue').count(), 1);
      assert.equal(await page.locator('.outcome-panel').getAttribute('aria-busy'), 'true');
      assert.equal(await page.locator('.outcome-panel .activity-cue .spinner').evaluate(element => getComputedStyle(element).animationName), 'none');
      await page.emulateMedia({ reducedMotion:'no-preference' });
      assert.equal(await page.locator('.page-heading .activity-cue .spinner').evaluate(element => getComputedStyle(element).animationName), 'spin');
      await page.emulateMedia({ reducedMotion:'reduce' });
      assert.equal(await page.locator('#prototype-companion-output').count(), 0, 'Accepted companion text remained in the page');
      const fixtureDetails=page.locator('#connection-scenario').locator('xpath=ancestor::details');
      await activate(fixtureDetails.locator('summary'), 'synthetic connection readback controls');
      await activate(page.getByRole('button', { name:'Simulate verified connection', exact:true }), 'prepare synthetic verification readback');
      await page.getByRole('heading', { name:'Purview connection verified', exact:true }).waitFor();
      await outcomeCheck(`${label}/verified`, 'Purview connection verified');
      assert.equal(await page.locator('.outcome-panel .activity-cue').count(), 0);
      assert.ok((await page.locator('main').innerText()).includes('2 existing sensitive information types were found'));
      assert.equal(await page.locator('.classifier-selection').count(), 0);
      assert.equal(await page.locator('.setup-steps li').count(), 4);
      assert.ok((await page.locator('.outcome-panel').innerText()).includes('own configured app access'));
      assert.ok((await page.locator('.outcome-panel').innerText()).includes('No shared DLP policy was created'));
      assert.equal(await page.locator('#connection-reference').innerText(), original);
      assert.deepEqual(await mutationCounts(), { connection:1, authorizations:0, policy:0, samples:0, agents:0 });
      assert.ok(await page.evaluate(() => app.observation.reads > 0 && app.observation.lastRead===app.connectionId), `${label}: completion did not come from the original operation readback`);
      assert.ok(await page.evaluate(() => app.observation.contextReads===1 && app.observation.lastContextRead===app.connectionId), `${label}: terminal operation did not reload current connection context`);
      await activate(page.locator('#technical-operation summary'), 'technical operation disclosure');
      assert.ok((await page.locator('#technical-operation').innerText()).includes('Skipped means not run, not passed.'));
      assert.equal(await page.locator('#technical-operation .badge.good').filter({ hasText:'Skipped' }).count(), 0, 'Skipped was styled as a passed check');
      await activate(page.locator('#technical-operation summary'), 'collapse technical operation details');
      if (['desktop','narrow-keyboard','zoom-200-keyboard'].includes(label)) await capture(`ux34-connection-${label}`,'.outcome-panel');
      await activate(page.getByRole('link', { name:'Continue to shared policies', exact:true }), 'continue to shared policies');
      assert.equal(new URL(page.url()).hash, '#/settings/policy', `${label}: connection chose an arbitrary profile`);
      assert.equal(await page.locator('#profile-select').inputValue(), '', `${label}: first profile was selected automatically`);
      assert.equal(await page.locator('#policy-form').count(), 0);
      if (keyboard) {
        await tabTo(page.locator('#profile-select'), 'shared blueprint selection');
        await page.keyboard.press('End');
      } else await page.locator('#profile-select').selectOption('profile-contoso');
      await page.locator('#policy-form').waitFor();
      assert.equal(new URL(page.url()).hash, `#${policyRoute}`);
      assert.equal(await page.locator('#selected-profile').innerText(), 'profile-contoso');
      assert.equal(await page.locator('#policy-mode').inputValue(), 'SimulationWithoutTips', `${label}: loaded the first, unrelated profile`);
      assert.equal(await page.locator('#sit-1-minCount').count(), 0, 'Unselected types expose threshold fields');
      await acknowledge(page.locator('#sit-1'), 'add a second sensitive information type');
      for (const [field, expected] of [['minCount','1'],['maxCount','Any'],['minConfidence','75'],['maxConfidence','100']])
        assert.equal(await page.locator(`#sit-1-${field}`).inputValue(), expected, `${label}: new type ${field} default`);
      if (keyboard) {
        await tabTo(page.locator('#sit-1-minCount'), 'adjust minimum matches');
        await page.keyboard.press('ControlOrMeta+A');
        await page.keyboard.type('2');
        await acknowledge(page.locator('#sit-1'), 'temporarily deselect the type');
      } else {
        await page.locator('#sit-1-minCount').fill('2');
        await page.locator('#sit-1').uncheck();
      }
      assert.equal(await page.locator('#sit-1-minCount').count(), 0);
      await acknowledge(page.locator('#sit-1'), 'restore the selected type');
      assert.equal(await page.locator('#sit-1-minCount').inputValue(), '2', 'Reselection discarded edited thresholds');
      if (keyboard) await acknowledge(page.locator('#sit-1'), 'retain the original single-type review');
      else await page.locator('#sit-1').uncheck();
      if (keyboard) {
        await tabTo(page.locator('#policy-mode'), 'policy mode');
        await page.keyboard.press('Home');
        await tabTo(page.locator('#sit-0-maxCount'), 'classifier maximum threshold');
        await page.keyboard.press('ControlOrMeta+A');
        await page.keyboard.type('Any');
      } else {
        await page.locator('#policy-mode').selectOption('Enforce');
        await page.locator('#sit-0-maxCount').fill('Any');
      }
      await activate(page.getByRole('button', { name:'Review protection choices', exact:true }), 'review exact shared policy');
      await modal(`${label}/shared scope`);
      const review = await page.locator('#dialog').innerText();
      for (const value of ['profile-contoso','11111111-1111-4111-8111-111111111111','synthetic-sit-employee','maximum matches: Any','confidence 75–100','Enforce','every agent']) assert.ok(review.includes(value), `${label}: review omits ${value}`);
      await acknowledge(page.locator('#confirm-shared'), 'shared impact acknowledgment');
      await activate(page.getByRole('button', { name:'Confirm and queue shared policy', exact:true }), 'confirm shared policy');
      await outcomeCheck(`${label}/policy pending`, 'Shared policy configuration is pending');
      assert.equal(new URL(page.url()).hash, `#${policyRoute}`, `${label}: accepted work auto-navigated`);
      await activate(page.getByRole('button', { name:'Check existing operation', exact:true }), 'read original policy result');
      await outcomeCheck(`${label}/policy saved`, 'Policy saved; behavior is not verified');
      assert.equal(await page.getByRole('link', { name:'Continue to behavior tests', exact:true }).getAttribute('href'), `#${runtimeRoute}`);
      assert.deepEqual(await mutationCounts(), { connection:1, authorizations:0, policy:1, samples:0, agents:0 });
      assert.equal(await page.evaluate(() => app.profiles.find(profile=>profile.id==='profile-other').mode), 'SimulationWithTips', 'Saving the selected profile changed another blueprint');
      if (label==='desktop') await capture('ux34-policy-saved-desktop');
      await activate(page.getByRole('link', { name:'Continue to behavior tests', exact:true }), 'continue to exact profile behavior test');
      assert.equal(new URL(page.url()).hash, `#${runtimeRoute}`);
      assert.equal(await page.locator('#selected-profile').innerText(), 'profile-contoso');
      await outcomeCheck(`${label}/approve samples`, 'Test policy behavior', false);
      for (const field of await page.locator('#runtime-form input[required]').all()) await acknowledge(field, 'sample approval');
      await activate(page.getByRole('button', { name:'Review test', exact:true }), 'review approved sample batch');
      await modal(`${label}/private sample review`);
      const sampleReview=await page.locator('#dialog').innerText();
      for (const value of ['profile-contoso','clean negative','effective','private and ephemeral','single-use']) assert.ok(sampleReview.toLowerCase().includes(value.toLowerCase()), `${label}: sample review omits ${value}`);
      await activate(page.getByRole('button', { name:'Confirm and send approved batch', exact:true }), 'confirm one sample batch');
      await outcomeCheck(`${label}/current runtime result`, 'Approved behavior is currently verified');
      assert.equal(await page.locator('#runtime-form').count(), 0);
      assert.equal(await page.locator('.sample-content').count(), 0, 'Sample text survived completion');
      assert.deepEqual(await mutationCounts(), { connection:1, authorizations:0, policy:1, samples:1, agents:0 });
      assert.deepEqual(await page.evaluate(() => app.agents.map(agent => ({ id:agent.id, purview:agent.purview, shield:agent.shield }))), beforeAgents, 'Connection, policy or test silently changed agent feature choices');
      if (label==='desktop'||label==='narrow-keyboard') await capture(`ux34-runtime-${label}`);
      await activate(page.getByRole('link', { name:'Continue to agents', exact:true }), 'continue to agents');
      assert.equal(new URL(page.url()).hash, '#/agents');
      await activate(page.locator('a[data-agent="agent-003"]'), 'choose an agent using the reviewed blueprint');
      assert.equal(await page.evaluate(() => app.agents.find(agent=>agent.id==='agent-003').purview), 'Off', 'Agent protection changed on navigation');
      await activate(page.getByRole('button', { name:'Choose protection for this agent', exact:true }), 'choose protection explicitly');
      await modal(`${label}/agent choices`);
      assert.ok((await page.locator('#dialog').innerText()).includes('profile-contoso'));
      await acknowledge(page.locator('#agent-purview-choice'), 'explicit Purview choice');
      await activate(page.getByRole('button', { name:'Save this agent’s choices', exact:true }), 'save only this agent');
      assert.equal(await page.evaluate(() => purviewState(app.agents.find(agent=>agent.id==='agent-003'))), 'Enforcing');
      assert.equal((await mutationCounts()).agents, 1);
      assert.deepEqual(await page.evaluate(() => app.agents.filter(agent=>agent.id!=='agent-003').map(agent=>({id:agent.id,purview:agent.purview,shield:agent.shield}))), beforeAgents.filter(agent=>agent.id!=='agent-003'), 'Agent choice changed a sibling');
      assert.equal(await page.evaluate(() => app.agents.find(agent=>agent.id==='agent-003').shield), beforeAgents.find(agent=>agent.id==='agent-003').shield, 'Purview changed Prompt Shields');
      await inspect(`${label}/explicit agent outcome`);
      if (label==='zoom-200-keyboard') await capture('ux34-agent-zoom-200','main > section.card.spacer');
      checks++;
      protectionJourneyChecks++;
    }
    async function protectionRecovery(label) {
      await reset('/settings/connection');
      for (const [state,title] of [
        ['pending','Checking the Purview connection'],['stopped','Checking the Purview connection'],
        ['failed','Connection verification failed'],['unknown','The connection result is not confirmed'],
        ['read-error','Connection status could not be checked'],['expired','Connection verified earlier; refresh required'],
        ['launch-expired','Connection launch expired'],['wrong-actor','This connection belongs to another administrator'],
        ['unavailable','Purview setup is unavailable']
      ]) {
        await fixtureState('connection',state);
        await outcomeCheck(`${label}/connection/${state}`,title);
        assert.equal(await page.locator('#prototype-companion-output').count(),0,`${state}: stale companion controls exposed`);
        assert.equal(await page.getByRole('link',{name:'Continue to shared policies',exact:true}).count(),0,`${state}: verification falsely authorizes continuation`);
        const before=await mutationCounts();
        if (state==='pending') {
          await page.getByRole('button',{name:'Stop automatic updates',exact:true}).click();
          assert.ok((await page.locator('#connection-observation').innerText()).includes('You stopped automatic updates.'));
          assert.equal(await page.evaluate(()=>document.activeElement?.dataset.action),'connection-resume',`${label}: stopped observation lost keyboard focus`);
          if (label==='narrow'||label==='zoom-200') await capture(`ux34-manually-stopped-${label}`,'.outcome-panel');
          await page.getByRole('button',{name:'Resume automatic updates',exact:true}).click();
          assert.equal(await page.evaluate(()=>document.activeElement?.dataset.action),'connection-stop',`${label}: resumed observation lost keyboard focus`);
          assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'1');
        }
        if (['failed','unknown','read-error'].includes(state)) {
          const original=await page.locator('#connection-reference').innerText();
          await page.getByRole('button',{name:'Check connection status',exact:true}).click();
          assert.equal(await page.locator('#connection-reference').innerText(),original);
          assert.equal(await page.getByRole('button',{name:'Review connection refresh',exact:true}).count(),0,`${state}: offers replacement before recovery`);
        }
        if (state==='stopped') {
          assert.ok((await page.locator('#connection-observation').innerText()).includes('stopped after 5 minutes'));
          assert.ok((await page.locator('.outcome-panel').innerText()).includes('Automatic updates stopped. Resume automatic updates'));
          if (label==='narrow') await capture('ux34-stopped-narrow');
          await page.getByRole('button',{name:'Resume automatic updates',exact:true}).click();
          assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'1');
        }
        if (state==='expired') {
          const original=await page.locator('#connection-reference').innerText();
          const verifiedAt=await page.evaluate(()=>app.connectionVerifiedAt);
          assert.ok((await page.locator('#technical-operation').textContent()).includes('Completed'));
          if (label==='narrow'||label==='zoom-200') await capture(`ux34-expired-${label}`,'.outcome-panel');
          await page.getByRole('button',{name:'Review connection refresh',exact:true}).click();
          await modal(`${label}/reviewed readiness refresh`);
          assert.ok((await page.locator('#dialog').innerText()).includes('old')||(await page.locator('#dialog').innerText()).includes('expired'));
          await page.keyboard.press('Escape');
          assert.equal(await page.locator('#connection-reference').innerText(),original);
          assert.equal(await page.evaluate(()=>app.connectionVerifiedAt),verifiedAt);
        }
        assert.deepEqual(await mutationCounts(),before,`${state}: read/reopen/cancel replayed work`);
      }
      for(const [state,title] of [['pending','Shared policy configuration is pending'],['failed','Shared policy configuration failed'],['unknown','The shared policy result is not confirmed'],['read-error','Shared policy status could not be checked']]){
        await reset(policyRoute);
        await fixtureState('policy',state);
        await outcomeCheck(`${label}/policy/${state}`,title);
        assert.equal(await page.locator('#policy-form').count(),0);
        const before=await mutationCounts();
        await page.getByRole('button',{name:'Check existing operation',exact:true}).click();
        assert.deepEqual(await mutationCounts(),before);
      }
      for(const [state,title] of [['failed','Approved behavior test failed'],['unknown','The test result is not confirmed'],['read-error','Test status could not be checked']]){
        await reset(runtimeRoute);
        await fixtureState('runtime',state);
        await outcomeCheck(`${label}/runtime/${state}`,title);
        assert.equal(await page.locator('#runtime-form').count(),0);
        const before=await mutationCounts();
        await page.getByRole('button',{name:'Check test status',exact:true}).click();
        assert.deepEqual(await mutationCounts(),before,'Test status recovery resent a sample');
      }
      for(const route of ['/settings/policy?profile=missing-profile','/settings/runtime?profile=missing-profile']){
        await reset(route);
        await outcomeCheck(`${label}/missing/${route}`,'Shared policy not found',false);
        assert.equal(await page.locator('#policy-form, #runtime-form').count(),0);
        assert.equal(await page.locator('#selected-profile').count(),0,'Missing profile silently fell back to another profile');
        await page.getByRole('link',{name:'Choose another shared policy',exact:true}).click();
        assert.equal(await page.locator('#profile-select').inputValue(),'');
      }
      for(const mode of ['Disabled','SimulationWithTips','SimulationWithoutTips']){
        await reset(policyRoute);
        await saveMode(mode);
        await outcomeCheck(`${label}/saved/${mode}`,mode==='Disabled'?'Policy saved; Purview is off':'Policy saved in simulation');
        assert.equal((await mutationCounts()).samples,0);
        if(mode==='Disabled'){
          await page.getByRole('link',{name:'Continue to agents',exact:true}).click();
          assert.equal(new URL(page.url()).hash,'#/agents','Saved Off cannot finish without runtime testing');
          await screen(runtimeRoute);
          await outcomeCheck(`${label}/off runtime`,'This policy is off');
          assert.equal(await page.locator('#runtime-form').count(),0);
        }else{
          await page.getByRole('link',{name:'Optional behavior diagnostics',exact:true}).click();
          assert.equal(new URL(page.url()).hash,`#${runtimeRoute}`);
          assert.ok((await page.locator('.outcome-panel').innerText()).includes('Diagnostics are optional'));
          await approveSamples();
          await outcomeCheck(`${label}/simulation diagnostics/${mode}`,'Simulation diagnostics complete');
          assert.ok((await page.locator('main').innerText()).includes('Simulation · not blocked'));
          assert.equal(await page.evaluate(()=>currentBehavior(currentProfile())),false,'Simulation certified enforcement');
        }
        assert.equal((await mutationCounts()).agents,0);
      }
      await reset(policyRoute);
      await saveMode('Enforce');
      await page.getByRole('link',{name:'Continue to behavior tests',exact:true}).click();
      await approveSamples();
      const samples=(await mutationCounts()).samples;
      await fixtureState('runtime','expired');
      await outcomeCheck(`${label}/expired behavior`,'Historical result; current verification required');
      assert.equal(await page.getByRole('link',{name:'Continue to agents',exact:true}).count(),0);
      assert.equal(await page.evaluate(()=>currentBehavior(currentProfile())),false);
      assert.equal((await mutationCounts()).samples,samples);
      await page.getByRole('button',{name:'Review new samples',exact:true}).click();
      assert.equal((await mutationCounts()).samples,samples,'Reviewing a new batch submitted samples automatically');
      assert.equal(await page.locator('#sample-consent').isChecked(),false);
      await screen('/settings/runtime?profile=profile-other');
      assert.equal(await page.locator('#selected-profile').innerText(),'profile-other');
      assert.ok((await page.locator('main').innerText()).includes('Simulation with tips'));
      assert.equal(await page.getByRole('heading',{name:'Historical runtime test receipt',exact:true}).count(),0,'Unrelated profile inherited another result');
      checks++;
    }
    async function modal(label) {
      await page.locator('dialog[open]').waitFor();
      assert.ok(await page.locator('#dialog-title').innerText(), `${label}: dialog title`);
      for (const key of ['Tab', 'Shift+Tab']) {
        for (let index = 0; index < 8; index++) {
          await page.keyboard.press(key);
          assert.ok(await page.evaluate(() => document.querySelector('dialog').contains(document.activeElement)), `${label}: focus escaped on ${key}`);
          assert.ok(await page.evaluate(() => document.activeElement.matches(':focus-visible')), `${label}: keyboard focus is not visible`);
          assert.ok(await page.evaluate(() => {
            const bounds = document.activeElement.getBoundingClientRect();
            return bounds.left >= 0 && bounds.top >= 0 && bounds.right <= innerWidth + 1 && bounds.bottom <= innerHeight + 1;
          }), `${label}: focused control is outside the viewport`);
        }
      }
      checks++;
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    // UX-02/03/04/05/07: key handoff must precede the delegated setup action.
    for (const [blueprint, width] of [['existing', 1440], ['new', 390]]) {
      await page.setViewportSize({ width, height: 1000 });
      await reset('/agents/register');
      await inspect(`${width}/registration`);
      await page.getByRole('button', { name: 'Review registration', exact: true }).click();
      assert.ok(await page.locator('#agent-name').evaluate(element => !element.validity.valid), 'Missing name was accepted');
      assert.equal(await page.locator('dialog[open]').count(), 0, 'Invalid registration opened review');
      await page.locator('#agent-name').fill(`Prototype ${blueprint} agent`);
      const id = page.locator('#external-id');
      if (!(await id.inputValue())) await id.fill(`prototype-${blueprint}`);
      await page.locator(`input[name="blueprint"][value="${blueprint}"]`).check();
      if (blueprint === 'new') await page.locator('#blueprint-name').fill('Prototype assistants');
      await page.locator('input[name="shield"]').check();
      assert.equal(await page.locator('input[name="purview"]').isChecked(), false, 'Shield changed Purview choice');
      await page.getByRole('button', { name: 'Review registration', exact: true }).click();
      await modal('Registration review');
      await capture(`registration-review-${width}`);
      await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
      await page.locator('#handoff-key').waitFor();
      await inspect(`${width}/key handoff`);
      await capture(`key-handoff-${width}`);
      assert.equal(await page.locator('[data-action="continue-setup"]').isDisabled(), true, 'Unsaved key can be discarded silently');
      assert.equal(await page.locator('[data-action="complete-registry"]').count(), 0, 'Registry before key handoff');
      assert.ok(!(await page.url()).includes('gw_demo'), 'Key in URL');
      assert.deepEqual(await page.evaluate(() => [localStorage.length, sessionStorage.length]), [0, 0], 'Prototype persisted state');
      // Deterministic UI feedback fixtures; this does not certify OS clipboard permission.
      await page.evaluate(() => {
        window.prototypeClipboard = navigator.clipboard.writeText;
        navigator.clipboard.writeText = async value => { window.prototypeCopied = value; };
      });
      const copyEndpoint = page.locator('[data-action="copy"]').first();
      await copyEndpoint.click();
      await page.waitForFunction(() => document.querySelector('#toast').textContent === 'Copied to clipboard.');
      assert.ok((await page.evaluate(() => window.prototypeCopied)).startsWith('https://'), 'Copy did not use the endpoint');
      await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw new Error('Synthetic clipboard denial'); }; });
      await copyEndpoint.click();
      await page.waitForFunction(() => document.querySelector('#toast').textContent.includes('Copy is unavailable'));
      await page.evaluate(() => {
        navigator.clipboard.writeText = window.prototypeClipboard;
        delete window.prototypeClipboard;
        delete window.prototypeCopied;
      });
      await page.locator('#nav a[href="#/agents"]').click();
      await modal('Unsaved key warning');
      await page.keyboard.press('Escape');
      assert.equal(await page.locator('dialog[open]').count(), 0, 'Escape did not close warning');
      assert.ok(await page.locator('#handoff-key').isVisible(), 'Cancel lost the one-time display');
      await page.locator('#saved-key').check();
      await page.locator('[data-action="continue-setup"]').click();
      assert.equal(await page.locator('#handoff-key').count(), 0, 'Key remains after handoff');
      await page.locator('[data-action="complete-registry"]').click();
      await modal('Registry handoff');
      await page.keyboard.press('Escape');
      assert.ok(await page.locator('[data-action="complete-registry"]').evaluate(element => element === document.activeElement), 'Dialog focus did not return');
      await page.goto(`${origin}/#/handoff`);
      assert.equal(await page.locator('#handoff-key').count(), 0, 'Discarded key became available again');
      checks++;
    }
    // Narrow forms and focused tasks, including the separate installer fixture.
    for (const width of [1440, 390, 360]) {
      await page.setViewportSize({ width, height: 1000 });
      for (const route of ['/agents/detail', '/operations/current', '/settings/connection', '/settings/policy', '/settings/runtime', '/settings/defaults', '/integration', '/installation']) {
        await screen(route);
        await inspect(`${width}/Administrator/success/${route}`);
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    // UX-06: replacing and retiring a key keeps one usable credential.
    await reset('/agents/detail');
    await page.locator('[data-action="revoke-key"]').click();
    assert.equal(await page.locator('#dialog-title').innerText(), 'Keep one usable Gateway key');
    await page.keyboard.press('Escape');
    await page.locator('[data-action="replace-key"]').click();
    await page.getByRole('button', { name: 'Issue replacement', exact: true }).click();
    await page.locator('#saved-key').check();
    await page.locator('[data-action="continue-setup"]').click();
    await page.locator('[data-action="revoke-key"]').click();
    await page.locator('#key-updated').check();
    await page.getByRole('button', { name: 'Revoke old key', exact: true }).click();
    assert.ok((await page.locator('main').innerText()).includes('Usable keys: 1'));
    checks++;
    // UX-20/22/23: an unconfirmed edit must not change the saved policy.
    await page.setViewportSize({ width: 390, height: 1000 });
    await reset(policyRoute);
    const stackedThresholds = await page.locator('#policy-form .sample-card .form-grid input').evaluateAll(fields =>
      fields.every(field => Math.abs(field.getBoundingClientRect().width - field.parentElement.getBoundingClientRect().width) <= 1));
    assert.ok(stackedThresholds, 'Narrow classifier fields do not use the full label width');
    await page.locator('#policy-mode').selectOption('Enforce');
    await page.getByRole('button', { name: 'Review protection choices', exact: true }).click();
    await modal('Narrow shared-policy review');
    await inspect('390/shared-policy review');
    await capture('shared-policy-review-narrow');
    await page.keyboard.press('Escape');
    await page.locator('#nav a[href="#/settings"]').click();
    await screen(policyRoute);
    assert.equal(await page.locator('#policy-mode').inputValue(), 'SimulationWithoutTips', 'Cancelled policy edit changed saved mode');
    await page.locator('#policy-mode').selectOption('Disabled');
    await page.getByRole('button', { name: 'Review protection choices', exact: true }).click();
    await page.locator('#confirm-shared').check();
    await page.getByRole('button', { name: 'Confirm and queue shared policy', exact: true }).click();
    await page.getByRole('button', { name: 'Check existing operation', exact: true }).click();
    await screen(runtimeRoute);
    assert.equal(await page.locator('#runtime-form').count(), 0, 'Off policy permits sample execution');
    assert.equal(await page.locator('main h1').innerText(), 'This policy is off');
    checks++;
    // UX-25/26: only explicitly approved synthetic samples reach the simulated result.
    await reset(runtimeRoute);
    for (const field of await page.locator('#runtime-form input[required]').all()) await field.check();
    await page.getByRole('button', { name: 'Review test', exact: true }).click();
    await modal('Narrow approved-sample review');
    await page.getByRole('button', { name: 'Confirm and send approved batch', exact: true }).click();
    assert.equal(await page.locator('main h1').innerText(), 'Simulation diagnostics complete');
    assert.equal(await page.getByRole('heading', { name: 'Historical runtime test receipt', exact: true }).count(), 1);
    assert.ok((await page.locator('main').innerText()).includes('Simulation'));
    await inspect('390/synthetic runtime result');
    await capture('runtime-result-narrow');
    checks++;
    // UX-18/33: companion and installer transitions are in-memory design fixtures.
    await screen('/settings/connection', 'Administrator', 'empty');
    assert.ok((await page.locator('main').innerText()).includes('No text file is required.'));
    assert.ok((await page.locator('main').innerText()).includes('A blocked script cannot unblock itself.'));
    await page.getByLabel('Paste companion result', { exact: true }).fill('Not a synthetic result');
    assert.equal(await page.locator('[data-action="companion-review"]').isDisabled(), true);
    await page.locator('[data-action="use-synthetic-companion"]').click();
    assert.equal(await page.getByLabel('Paste companion result', { exact: true }).getAttribute('aria-invalid'), 'false');
    await inspect('390/first-run companion instructions and paste');
    await capture('connection-first-run-narrow');
    checks++;
    await page.locator('[data-action="companion-review"]').click();
    await modal('Narrow companion review');
    await page.getByRole('button', { name: 'Simulate result submission', exact: true }).click();
    assert.ok((await page.locator('main').innerText()).includes('Companion result received. Checking Gateway access.'));
    assert.equal(await page.locator('[data-action="companion-review"]').count(), 0);
    assert.equal((await page.locator('main').innerText()).includes('Connection verified'), false);
    await inspect('390/separate companion verification');
    await capture('connection-pending-narrow');
    await page.locator('#fixture-state').selectOption('empty');
    assert.equal(await page.getByRole('button', { name: 'Review companion connection', exact: true }).count(), 1);
    assert.equal((await page.locator('main').innerText()).includes('Companion result received'), false);
    await page.locator('#fixture-state').selectOption('success');
    await page.locator('[data-action="connection-reopen"]').click();
    await modal('Pending original connection');
    assert.ok((await page.locator('#dialog').innerText()).includes('Checking Gateway access'));
    await page.getByRole('button', { name: 'Done', exact: true }).click();
    await openConnectionFixtures();
    await page.locator('[data-action="connection-failed"]').click();
    await page.getByRole('heading', { name: 'Connection verification failed', exact: true }).waitFor();
    assert.ok((await page.locator('main').innerText()).includes('Connection verification failed.'));
    assert.ok((await page.locator('main').innerText()).includes('DLP protection is not enabled by this step.'));
    await inspect('390/failed independent verification');
    await capture('connection-failed-narrow');
    await page.locator('#fixture-state').selectOption('empty');
    assert.equal(await page.getByRole('button', { name: 'Review companion connection', exact: true }).count(), 1);
    assert.equal((await page.locator('main').innerText()).includes('Connection verification failed.'), false);
    checks+=5;
    await screen('/settings/connection', 'Administrator', 'empty');
    await page.locator('[data-action="use-synthetic-companion"]').click();
    await page.locator('[data-action="companion-review"]').click();
    await page.getByRole('button', { name: 'Simulate result submission', exact: true }).click();
    await openConnectionFixtures();
    await page.locator('[data-action="connection-verified"]').click();
    await page.getByRole('heading', { name: 'Purview connection verified', exact: true }).waitFor();
    await reset('/installation');
    await page.locator('#install-review').check();
    await page.locator('[data-action="review-installation"]').click();
    await modal('Narrow installation review');
    await page.getByRole('button', { name: 'Confirm reviewed plan', exact: true }).click();
    await page.locator('[data-action="installer-status"]').click();
    assert.equal(await page.locator('main h1').innerText(), 'Your Gateway is installed');
    await inspect('390/installer handoff');
    checks++;
    await page.setViewportSize({ width: 1440, height: 1000 });
    // UX-12/13: the fixture's first page is not treated as the complete collection.
    await reset('/agents');
    const firstPage = await page.locator('tbody tr').count();
    assert.ok(firstPage > 0, 'Empty success fixture');
    await page.locator('[data-action="next-page"]').click();
    assert.ok(await page.locator('tbody tr').count() > 0, 'No second page');
    await page.locator('[data-action="prev-page"]').click();
    assert.equal(await page.locator('tbody tr').count(), firstPage, 'Previous page did not restore');
    const externalId = await page.locator('tbody tr').first().innerText();
    const searchId = externalId.match(/contoso-agent-\d+/)?.[0];
    assert.ok(searchId, 'Synthetic external ID unavailable for search');
    await page.locator('#agent-query').fill(searchId);
    await page.locator('#agent-search').evaluate(form => form.requestSubmit());
    assert.equal(await page.locator('tbody tr').count(), 1, 'External-ID search does not match exactly one fixture');
    checks++;
    // UX-28: forbidden mutations and data sections never appear for a reader role.
    for (const role of ['Operator', 'Auditor', 'SupportReader']) {
      await screen('/agents/detail', role);
      for (const action of ['replace-key', 'revoke-key', 'delete-agent']) assert.equal(await page.locator(`[data-action="${action}"]`).count(), 0, `${role}: ${action} visible`);
      assert.equal(await page.locator('[data-action="view-audit"]').count(), role === 'Auditor' ? 1 : 0, `${role}: audit access`);
      assert.equal(await page.locator('[data-action="toggle-agent"]').count(), role === 'Operator' ? 1 : 0, `${role}: enablement access`);
      await screen('/agents/register', role);
      assert.equal(await page.locator('#register-form').count(), 0, `${role}: direct registration route`);
      await screen('/settings/runtime', role);
      assert.equal(await page.locator('#runtime-form').count(), 0, `${role}: raw sample form`);
      checks++;
    }
    // UX-08/27: uncertain writes expose status recovery, not a repeated create/test.
    await screen('/operations/current', 'Administrator', 'error');
    assert.equal(await page.locator('[data-action="complete-registry"]').count(), 0, 'Unknown Registry outcome permits create');
    assert.ok(await page.locator('[data-action="reconcile-registry"]').isVisible());
    await screen(runtimeRoute, 'Administrator', 'error');
    assert.equal(await page.locator('#runtime-form').count(), 0, 'Unknown test outcome permits new samples');
    assert.ok(await page.locator('[data-action="runtime-reconcile"]').isVisible());
    checks++;
    // UX-30: the first keyboard action bypasses navigation and reaches main content.
    await page.goto(origin);
    await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), 'Skip to content');
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'main');
    checks++;
    // Follow the core handoff using only keyboard input after selecting the fixture.
    await page.setViewportSize({ width: 390, height: 1000 });
    await reset('/setup');
    await tabTo(page.getByRole('link', { name: 'Register agent', exact: true }), 'registration entry');
    await page.keyboard.press('Enter');
    await page.locator('#agent-name').waitFor();
    assert.ok(await page.locator('main h1').evaluate(element => element === document.activeElement), 'Registration navigation did not focus the heading');
    await tabTo(page.locator('#agent-name'), 'agent name');
    await page.keyboard.type('Keyboard fixture agent');
    await tabTo(page.locator('input[name="blueprint"][value="existing"]'), 'blueprint choice');
    await page.keyboard.press('ArrowDown');
    assert.ok(await page.locator('input[name="blueprint"][value="new"]').isChecked(), 'Keyboard did not select a new blueprint');
    await tabTo(page.locator('#blueprint-name'), 'new blueprint name');
    await page.keyboard.type('Keyboard fixture blueprint');
    await tabTo(page.locator('input[name="shield"]'), 'Prompt Shields choice');
    await page.keyboard.press('Space');
    assert.ok(await page.locator('input[name="shield"]').isChecked(), 'Keyboard did not select Prompt Shields');
    assert.equal(await page.locator('input[name="purview"]').isChecked(), false, 'Keyboard changed the independent Purview choice');
    await inspect('390/keyboard registration');
    await tabTo(page.getByRole('button', { name: 'Review registration', exact: true }), 'registration review');
    await page.keyboard.press('Enter');
    await modal('Keyboard registration review');
    await tabTo(page.getByRole('button', { name: 'Register and show key', exact: true }), 'registration confirmation');
    await page.keyboard.press('Enter');
    await page.locator('#handoff-key').waitFor();
    await inspect('390/keyboard key handoff');
    await tabTo(page.locator('#saved-key'), 'saved key acknowledgment');
    await page.keyboard.press('Space');
    await tabTo(page.locator('[data-action="continue-setup"]'), 'continue after saving key');
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#handoff-key').count(), 0, 'Keyboard handoff retained the one-time key');
    await tabTo(page.locator('[data-action="complete-registry"]'), 'Registry handoff');
    await page.keyboard.press('Enter');
    await modal('Keyboard Registry review');
    await tabTo(page.getByRole('button', { name: 'Complete registration', exact: true }), 'Registry confirmation');
    await page.keyboard.press('Enter');
    assert.ok((await page.locator('main').innerText()).includes('Agent setup is complete'), 'Keyboard flow did not complete the synthetic registration');
    await inspect('390/keyboard registration complete');
    await tabTo(page.getByRole('link', { name: 'Open integration guide', exact: true }), 'developer handoff');
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('main h1').innerText(), 'Connect your external agent');
    await inspect('390/keyboard developer handoff');
    checks++;
    await page.setViewportSize({ width: 1440, height: 1000 });
    await screen('/setup');
    await capture('getting-started-desktop');
    await page.setViewportSize({ width: 390, height: 1000 });
    await capture('getting-started-narrow');
    // UX-34: exercise the real fixture links and confirmations, not link presence alone.
    for (const [width,label,keyboard] of [[1440,'desktop',false],[390,'narrow-keyboard',true],[360,'narrow',false]]) {
      await page.setViewportSize({width,height:1000});
      await protectionJourney(label,keyboard);
      if(width!==390)await protectionRecovery(label);
    }
    await page.setViewportSize({width:1440,height:1000});
    for(const role of ['Operator','Auditor','SupportReader']){
      await reset('/settings/connection');
      await screen('/settings/connection',role);
      assert.equal(await page.locator('#prototype-companion-output, [data-action="companion-review"], [data-action="review-connection-refresh"]').count(),0,`${role}: connection mutation controls`);
      if(role==='Operator'){
        assert.ok((await page.locator('.outcome-panel').innerText()).includes('Gateway Administrator'));
        assert.equal(await page.getByRole('link',{name:'Continue to shared policies',exact:true}).count(),0);
        await page.evaluate(()=>chooseConnectionFixture('pending'));
        const before=await mutationCounts();
        await page.getByRole('button',{name:'Stop automatic updates',exact:true}).click();
        assert.equal(await page.evaluate(()=>app.observation.stopReason),'user');
        await page.getByRole('button',{name:'Resume automatic updates',exact:true}).click();
        assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'1');
        assert.deepEqual(await mutationCounts(),before,'Operator observation controls dispatched work');
      }else assert.equal(await page.locator('main h1').innerText(),'This task needs another role');
      await screen(policyRoute,role);
      assert.equal(await page.locator('#policy-form').count(),0,`${role}: shared policy editor`);
      assert.equal(await page.getByRole('link',{name:'Continue to behavior tests',exact:true}).count(),0,`${role}: unusable runtime continuation`);
      await screen(runtimeRoute,role);
      assert.equal(await page.locator('#runtime-form').count(),0);
      checks++;
      protectionJourneyChecks++;
    }
    // Local GET observations use actual three-second timers and a five-minute deadline.
    // Advancing the isolated page clock simulates suspension without any provider call.
    await page.clock.install({time:new Date('2026-09-23T12:00:00Z')});
    await page.clock.pauseAt(new Date('2026-09-23T12:00:10Z'));
    await reset('/settings/connection');
    await fixtureState('connection','pending');
    const observedId=await page.locator('#connection-reference').innerText();
    const observationMutations=await mutationCounts();
    await page.clock.runFor(2999);
    assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'0','Polling ran before three seconds');
    await page.clock.runFor(1);
    assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'1');
    await page.clock.runFor(3000);
    assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),'2');
    await page.clock.fastForward(294000);
    await page.getByRole('button',{name:'Resume automatic updates',exact:true}).waitFor();
    const stoppedReads=await page.locator('#connection-observation').getAttribute('data-read-count');
    await page.clock.fastForward(600000);
    assert.equal(await page.locator('#connection-observation').getAttribute('data-read-count'),stoppedReads,'Polling continued after its five-minute limit');
    assert.deepEqual(await mutationCounts(),observationMutations,'Automatic observation submitted work');
    await tabTo(page.getByRole('button',{name:'Resume automatic updates',exact:true}),'resume deadline-stopped observation');
    await page.keyboard.press('Enter');
    assert.equal(Number(await page.locator('#connection-observation').getAttribute('data-read-count')),Number(stoppedReads)+1,'Resume did not read the original operation');
    await tabTo(page.getByRole('button',{name:'Stop automatic updates',exact:true}),'stop automatic observation');
    await page.keyboard.press('Enter');
    const manuallyStoppedReads=await page.evaluate(()=>app.observation.reads);
    assert.equal(await page.evaluate(()=>document.activeElement?.dataset.action),'connection-resume');
    assert.ok((await page.locator('#connection-observation').innerText()).includes('You stopped automatic updates.'));
    assert.ok(!(await page.locator('#connection-observation').innerText()).includes('after 5 minutes'));
    await page.clock.runFor(9000);
    assert.equal(await page.evaluate(()=>app.observation.reads),manuallyStoppedReads,'Manual Stop retained automatic reads');
    await page.getByRole('button',{name:'Check connection status',exact:true}).click();
    assert.equal(await page.evaluate(()=>app.observation.reads),manuallyStoppedReads+1);
    await page.getByRole('link',{name:'Settings',exact:true}).first().click();
    await page.getByRole('link',{name:'Review connection',exact:true}).click();
    await page.clock.runFor(6000);
    assert.equal(await page.evaluate(()=>app.observation.reads),manuallyStoppedReads+1,'A manual read or reopening restarted automatic observation');
    await tabTo(page.getByRole('button',{name:'Resume automatic updates',exact:true}),'resume automatic observation');
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(()=>app.observation.reads),manuallyStoppedReads+2);
    assert.equal(await page.evaluate(()=>document.activeElement?.dataset.action),'connection-stop');
    assert.equal(await page.locator('#connection-reference').innerText(),observedId);
    assert.equal(await page.evaluate(()=>app.observation.contextReads),0,'Pending work manufactured current context');
    assert.deepEqual(await mutationCounts(),observationMutations);
    checks++;
    protectionJourneyChecks++;
    await openConnectionFixtures();
    await page.getByRole('button',{name:'Simulate verified connection',exact:true}).click();
    const currentContext=await page.evaluate(()=>app.connectionContextReadback);
    await page.clock.runFor(3000);
    assert.equal(await page.locator('main h1').innerText(),'Purview connection verified');
    assert.equal(await page.locator('#connection-reference').innerText(),observedId);
    assert.equal(await page.evaluate(()=>app.observation.contextReads),1);
    assert.equal(await page.evaluate(()=>app.observation.lastContextRead),observedId);
    assert.equal(await page.evaluate(()=>app.connectionVerifiedAt),currentContext.connectionVerifiedAt,'GET fabricated a new verification timestamp');
    assert.equal(await page.evaluate(()=>app.connectionValidUntil),currentContext.connectionValidUntil,'GET extended the current readiness bound');
    assert.deepEqual(await mutationCounts(),observationMutations,'Terminal readback created policy or enabled an agent');
    const terminalReads=await page.evaluate(()=>app.observation.reads);
    await page.clock.fastForward(300000);
    assert.equal(await page.evaluate(()=>app.observation.reads),terminalReads,'A terminal result retained automatic observation');
    assert.equal(new URL(page.url()).hash,'#/settings/connection','Completion automatically navigated');
    await fixtureState('connection','pending');
    await openConnectionFixtures();
    await page.getByRole('button',{name:'Simulate completed connection with expired readiness',exact:true}).click();
    const expiredContext=await page.evaluate(()=>app.connectionContextReadback);
    await page.clock.runFor(3000);
    assert.equal(await page.locator('main h1').innerText(),'Connection verified earlier; refresh required');
    assert.ok((await page.locator('#technical-operation').textContent()).includes('Completed'));
    assert.equal(await page.getByRole('link',{name:'Continue to shared policies',exact:true}).count(),0);
    assert.equal(await page.evaluate(()=>app.observation.contextReads),1);
    assert.equal(await page.evaluate(()=>app.observation.lastContextRead),observedId);
    assert.equal(await page.evaluate(()=>app.connectionVerifiedAt),expiredContext.connectionVerifiedAt);
    assert.equal(await page.evaluate(()=>app.connectionValidUntil),expiredContext.connectionValidUntil);
    assert.deepEqual(await mutationCounts(),observationMutations,'Terminal expired context replayed work');
    checks++;
    protectionJourneyChecks++;
    await fixtureState('connection','pending');
    await page.getByRole('link',{name:'Settings',exact:true}).first().click();
    const leftReads=await page.evaluate(()=>app.observation.reads);
    await page.clock.runFor(9000);
    assert.equal(await page.evaluate(()=>app.observation.reads),leftReads,'Leaving the task retained a polling session');
    await page.clock.resume();
    checks++;
    protectionJourneyChecks++;
    // Change Chrome's real page-zoom preference, not CSS, device scale or pinch zoom.
    await page.setViewportSize({ width: 1440, height: 1000 });
    const unzoomed = await page.evaluate(() => ({ width: innerWidth, pixelRatio: devicePixelRatio }));
    const settings = await context.newPage();
    await settings.goto('chrome://settings/appearance');
    const zoomControl = settings.getByRole('combobox', { name: 'Page zoom', exact: true });
    await zoomControl.selectOption('2');
    assert.equal(await zoomControl.inputValue(), '2', 'Chrome page zoom did not change to 200%');
    await settings.close();
    await page.bringToFront();
    await page.waitForFunction(before =>
      Math.abs(devicePixelRatio - before.pixelRatio * 2) < 0.01 &&
      Math.abs(innerWidth - before.width / 2) <= 1 &&
      visualViewport.scale === 1, unzoomed);
    assert.equal((await cdp.send('Page.getLayoutMetrics')).cssVisualViewport.zoom, 2, 'Chrome did not report actual 200% page zoom');
    const zoom = await page.evaluate(() => ({ percent: 200, width: innerWidth, height: innerHeight, pixelRatio: devicePixelRatio, visualScale: visualViewport.scale }));
    await reset('/setup');
    for (const role of roles) {
      for (const state of states) {
        for (const route of Object.keys(views)) {
          await screen(route, role, state);
          await inspect(`200%/${role}/${state}/${route}`);
          zoomChecks++;
        }
      }
    }
    assert.equal(zoomChecks, roles.length * states.length * Object.keys(views).length, 'Incomplete 200% browser-zoom matrix');
    for (const [route, action, role = 'Administrator', state = 'success'] of [
      ['/agents/detail', 'toggle-agent'],
      ['/agents/detail', 'replace-key'],
      ['/agents/detail', 'revoke-key'],
      ['/agents/detail', 'delete-agent'],
      ['/agents/detail', 'view-audit'],
      ['/settings', 'policy-summary', 'Operator'],
      ['/settings/connection', 'connection-reopen'],
      ['/settings/connection', 'companion-review', 'Administrator', 'empty'],
      ['/installation', 'review-resume', 'Administrator', 'error']
    ]) {
      await reset();
      await screen(route, role, state);
      if(action==='companion-review')await page.locator('[data-action="use-synthetic-companion"]').click();
      await page.locator(`[data-action="${action}"]`).click();
      await modal(`200%/${action}`);
      await inspect(`200%/${action}`);
      await page.keyboard.press('Escape');
      assert.ok(await page.locator(`[data-action="${action}"]`).evaluate(element => element === document.activeElement), `200%/${action}: focus did not return`);
    }
    for (const blueprint of ['existing', 'new']) {
      await reset('/agents/register');
      await page.locator('#agent-name').fill(`Zoom ${blueprint} agent`);
      await page.locator(`input[name="blueprint"][value="${blueprint}"]`).check();
      if (blueprint === 'new') await page.locator('#blueprint-name').fill('Zoom fixture blueprint');
      await page.locator('input[name="purview"]').check();
      await page.locator('[data-action="review-registration-policy"]').click();
      await modal(`200%/${blueprint} registration policy`);
      await inspect(`200%/${blueprint} registration policy`);
      await page.locator('#policy-impact').check();
      await page.getByRole('button', { name: 'Confirm policy review', exact: true }).click();
      await page.getByRole('button', { name: 'Review registration', exact: true }).click();
      await modal(`200%/${blueprint} registration review`);
      await inspect(`200%/${blueprint} registration review`);
      await capture(`registration-review-${blueprint}-zoom-200`);
      await page.getByRole('button', { name: 'Register and show key', exact: true }).click();
      await page.locator('#handoff-key').waitFor();
      await inspect(`200%/${blueprint} key handoff`);
      await page.locator('#nav a[href="#/agents"]').click();
      await modal(`200%/${blueprint} unsaved key`);
      await inspect(`200%/${blueprint} unsaved key`);
      await page.keyboard.press('Escape');
      await page.locator('#saved-key').check();
      await page.locator('[data-action="continue-setup"]').click();
      await page.locator('[data-action="complete-registry"]').click();
      await modal(`200%/${blueprint} Registry handoff`);
      await inspect(`200%/${blueprint} Registry handoff`);
      await page.keyboard.press('Escape');
    }
    await reset('/agents/detail');
    await page.locator('[data-action="replace-key"]').click();
    await page.getByRole('button', { name: 'Issue replacement', exact: true }).click();
    await page.locator('#saved-key').check();
    await page.locator('[data-action="continue-setup"]').click();
    await page.locator('[data-action="revoke-key"]').click();
    await modal('200%/old key revocation');
    await inspect('200%/old key revocation');
    await page.keyboard.press('Escape');
    await reset(policyRoute);
    await page.getByRole('button', { name: 'Review protection choices', exact: true }).click();
    await modal('200%/shared policy review');
    await inspect('200%/shared policy review');
    await capture('shared-policy-review-zoom-200');
    await page.keyboard.press('Escape');
    await reset(runtimeRoute);
    for (const field of await page.locator('#runtime-form input[required]').all()) await field.check();
    await page.getByRole('button', { name: 'Review test', exact: true }).click();
    await modal('200%/approved runtime samples');
    await inspect('200%/approved runtime samples');
    await page.keyboard.press('Escape');
    await reset('/installation');
    await page.locator('#install-review').check();
    await page.locator('[data-action="review-installation"]').click();
    await modal('200%/installation review');
    await inspect('200%/installation review');
    await page.keyboard.press('Escape');
    await screen('/setup');
    await capture('getting-started-zoom-200');
    await protectionJourney('zoom-200-keyboard',true);
    await protectionRecovery('zoom-200');
    assert.ok(checks > 0, 'No browser scenarios ran');
    assert.ok(protectionJourneyChecks > 0, 'No UX-34 protection journeys ran');
    assert.deepEqual(await page.evaluate(()=>[localStorage.length,sessionStorage.length]),[0,0],'Protection fixture persisted samples or state');
    assert.equal(await page.locator('input[type="file"]').count(),0,'Prototype exposes a real file reader');
    assert.deepEqual(blocked, [], 'Prototype attempted a nonlocal request');
    assert.deepEqual(errors, [], 'Browser console or script errors');
    console.log(JSON.stringify({ browser: `Installed Chrome ${browser.version()}`, matrixChecks, zoomChecks, protectionJourneyChecks, zoom, fixtureChecks: checks, nonlocalRequests: blocked.length, browserErrors: errors.length, screenshots }, null, 2));
  } finally {
    try { await context.close(); }
    finally { fs.rmSync(profile, { recursive: true, force: true }); }
  }
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
