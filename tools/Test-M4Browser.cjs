'use strict';

const assert = require('node:assert/strict');
const { runBrowserAcceptance } = require('./Test-M3Browser.cjs');

async function journeys(harness) {
  const { api, reset, go, inspect, modal, capture, state, counter, poll, pass, origin } = harness;
  const page = harness.page;
  const setupStep = task => page().locator(`nav[aria-label="Purview setup steps"] a[href^="/settings/${task}"]`);
  async function openSavedPolicyDetails() {
    const library = page().locator('details.saved-policy-library');
    await library.waitFor();
    if (!await library.evaluate(element => element.open))
      await library.locator(':scope > summary').click();
  }
  assert.equal(new URL(origin).protocol, 'https:', 'M4 runtime samples require the owned HTTPS fixture');
  assert.ok(harness.catalog.scenarios.some(item => item.name === 'm4-ready'), 'M4 fixture catalog is required');

  await reset('m4-connection');
  await go('/settings/connection');
  const recoveryFailures = await page().evaluate(() => {
    const originalUrl = location.href;
    const originalState = history.state;
    const failures = [];
    const operationId = '33333333-3333-4333-8333-333333333333';
    const profileId = '44444444-4444-4444-8444-444444444444';
    const current = `${location.origin}/settings/connection?profile=${profileId}#purview-companion-output`;
    const target = `${location.origin}/settings/connection?profile=${profileId}&operation=${operationId}`;
    const check = (value, label) => { if (!value) failures.push(label); };
    function reject(uri, id = operationId) {
      history.replaceState(originalState, '', current);
      let rejected = false;
      try { window.A365Gateway.retainProtectionRecovery(uri, id); } catch { rejected = true; }
      check(rejected && location.href === current, `rejected without changing history: ${uri}`);
    }
    try {
      history.replaceState(originalState, '', current);
      check(window.A365Gateway.retainProtectionRecovery(target, operationId), 'fragment-only change acknowledged');
      check(location.hash === '#purview-companion-output', 'browser fragment preserved');
      check(new URL(location.href).searchParams.get('profile') === profileId, 'profile preserved');
      check(new URL(location.href).searchParams.get('operation') === operationId, 'exact operation retained');
      check(JSON.stringify(history.state) === JSON.stringify(originalState), 'Blazor history state preserved');
      check(window.A365Gateway.retainProtectionRecovery(`${target}#previous`, operationId), 'stale server fragment is not authority');
      check(location.hash === '#purview-companion-output', 'stale fragment cannot overwrite current scroll target');
      reject(target.replace(location.origin, 'https://outside.browser-fixture.invalid'));
      reject(target.replace('/settings/connection', '/settings/policy'));
      reject(target.replace(profileId, operationId));
      reject(`${target}&profile=${profileId}`);
      reject(`${target}&unreviewed=1`);
      reject(target.replace(`profile=${profileId}&`, ''));
      reject(`${target}&operation=${operationId}`);
      reject(target.replace(`&operation=${operationId}`, ''));
      reject(target, profileId);
      reject(target.replace(operationId, '00000000-0000-0000-0000-000000000000'),
        '00000000-0000-0000-0000-000000000000');
      reject(target.replace('https://', 'https://unexpected-user@'));
      const registration = `${location.origin}/agents/register?source=fixture#registration-form`;
      history.replaceState(originalState, '', registration);
      check(window.A365Gateway.retainRegistrationRecovery(
        `${registration.split('#')[0]}&pendingExternalId=synthetic-agent`, 'synthetic-agent'),
      'shared registration recovery still works');
      check(location.hash === '#registration-form', 'registration fragment preserved');
      check(new URL(location.href).searchParams.get('source') === 'fixture', 'registration context preserved');
    } finally {
      history.replaceState(originalState, '', originalUrl);
    }
    return failures;
  });
  assert.deepEqual(recoveryFailures, [], 'Recovery must preserve the document, reviewed query context and browser fragment');
  assert.equal(await counter('ConfirmProtectionOperationReviewAsync'), 0);
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 0);
  pass();

  for (const width of [1440, 390, 360]) {
    for (const role of harness.catalog.roles) {
      const core = await reset('m4-core', role, width);
      await go('/settings');
      assert.ok((await page().locator('main').innerText()).includes('Both protections Off is a complete core registration'));
      assert.equal(await page().locator('#purview-journey-heading, #defaults-heading, textarea').count(), 0);
      await inspect('optional core overview');
      await go(`/agents/${core.primaryAgentId}`);
      assert.equal(await page().getByText('Microsoft Purview connection needed', { exact: true }).count(), 0);
      await inspect('core-only details');
      if (role !== 'Administrator') {
        await go('/settings/runtime');
        assert.equal(await page().locator('textarea').count(), 0);
        assert.equal(await counter('GetPurviewSensitiveInformationTypesAsync'), 0);
        await inspect('restricted runtime task');
      }
    }
    for (const [scenario, status] of [['m4-ready', 'Enforcing'], ['m4-simulation', 'Simulation'],
      ['m4-off', 'Off'], ['m4-expired', 'Verification expired']]) {
      const snapshot = await reset(scenario, 'Administrator', width);
      await go('/agents');
      await page().locator(`[data-protection="Microsoft Purview"] [aria-label="Status: ${status}"]`).waitFor();
      await inspect(`${scenario} list`);
      await go(`/agents/${snapshot.primaryAgentId}`);
      await page().locator(`[data-protection="Microsoft Purview"] [aria-label="Status: ${status}"]`).first().waitFor();
      await inspect(`${scenario} details`);
      await go('/settings/policy');
      await openSavedPolicyDetails();
      await page().locator(`[data-protection="Microsoft Purview"] [aria-label="Status: ${status}"]`).waitFor();
      await inspect(`${scenario} shared policy`);
    }
  }

  for (const reference of ['invalid', '99999999-9999-4999-8999-999999999999']) {
    await reset('m4-connection');
    await go(`/settings/connection?operation=${reference}`);
    await page().locator('[role="alert"]').first().waitFor();
    await page().getByRole('link', { name: 'Protection overview', exact: true }).click();
    await page().waitForURL(`${origin}/settings`);
    await setupStep('connection').click();
    await page().waitForURL(`${origin}/settings/connection`);
    await poll(() => page().getByRole('button', { name: 'Review tenant connection', exact: true }).isEnabled(),
      value => value, 'clean task after invalid or missing operation');
    assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 0);
    pass();
  }

  await reset('m4-ready');
  let releaseModule;
  const moduleGate = new Promise(resolve => { releaseModule = resolve; });
  let moduleRequested = false;
  const moduleMatcher = url => url.origin === origin && /^\/purview-runtime-test(?:\.[a-z0-9]+)?\.js$/i.test(url.pathname);
  await page().route(moduleMatcher, async route => {
    moduleRequested = true;
    await moduleGate;
    await route.continue();
  });
  await go('/settings/runtime');
  await page().getByRole('button', { name: 'Verify shared profile', exact: true }).click();
  await page().locator('textarea[data-runtime-negative]').waitFor();
  await poll(async () => moduleRequested, value => value, 'delayed actual private module import');
  await page().getByRole('button', { name: 'Close and erase samples', exact: true }).click();
  releaseModule();
  await poll(() => page().locator('textarea[data-runtime-sample]').count(), value => value === 0, 'closed private sample form');
  await page().unroute(moduleMatcher);
  await page().getByRole('button', { name: 'Verify shared profile', exact: true }).click();
  await page().locator('textarea[data-runtime-negative]').waitFor();
  assert.equal(await counter('ExecuteRuntimeSamples'), 0);
  await page().getByRole('button', { name: 'Close and erase samples', exact: true }).click();
  pass();

  await reset('m4-connection');
  await go('/settings/connection');
  await page().getByRole('button', { name: 'Review tenant connection', exact: true }).click();
  await modal('Confirm connect the Microsoft Purview tenant?');
  await page().keyboard.press('Escape');
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 0);
  pass();
  await page().getByRole('button', { name: 'Review tenant connection', exact: true }).click();
  await page().getByRole('button', { name: 'Confirm and start', exact: true }).click();
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  const connection = (await state()).protection;
  assert.equal(new URL(page().url()).searchParams.get('operation'), connection.latestOperationId);
  await page().reload();
  await page().locator('.page-header[aria-busy="false"]').waitFor();
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  await page().getByRole('link', { name: 'Go to companion result', exact: true }).click();
  assert.equal(new URL(page().url()).hash, '#purview-companion-output');
  assert.equal(new URL(page().url()).searchParams.get('operation'), connection.latestOperationId);
  pass();
  const snapshot = await state();
  const expiry = await page().locator('.windows-companion-steps time').getAttribute('datetime');
  const evidence = {
    operationId: connection.latestOperationId, tenantId: snapshot.tenantId, administratorObjectId: snapshot.actorId,
    inventoryGenerationId: connection.inventoryGenerationId, observedAtUtc: new Date().toISOString(),
    inventoryExpiresAtUtc: expiry,
    authorizedCapabilities: ['DlpPolicy.ReadWrite', 'DlpRule.ReadWrite', 'KnowYourData.ReadWrite', 'SensitiveInformationTypes.Read'],
    sensitiveInformationTypes: connection.classifiers
  };
  const output = value => 'A365GW_CONNECTION_RESULT:' + Buffer.from(JSON.stringify(value)).toString('base64');
  async function paste(value) {
    await page().getByLabel('Paste companion result', { exact: true }).fill(output(value));
  }
  async function upload(value) {
    if (!await page().locator('.companion-upload').evaluate(element => element.open))
      await page().getByText('Or upload a saved result (optional)', { exact: true }).click();
    await page().locator('#purview-companion-evidence').setInputFiles({
      name: 'synthetic-companion.txt', mimeType: 'text/plain', buffer: Buffer.from(output(value))
    });
  }
  const trustCommand = await page().getByLabel('Trust this downloaded file', { exact: true }).inputValue();
  assert.equal(trustCommand, "Unblock-File -LiteralPath '.\\Connect-PurviewTenant.ps1' -ErrorAction Stop");
  assert.ok((await page().locator('.windows-companion-steps').innerText()).includes('A blocked script cannot perform this step itself'));
  assert.equal(await page().locator('.companion-upload').evaluate(element => element.open), false);
  await page().evaluate(() => {
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
      writeText: async text => { window.__copiedCompanionCommand = text; }
    } });
  });
  await page().getByRole('button', { name: 'Copy Trust this downloaded file', exact: true }).click();
  await page().getByText('Trust command copied.', { exact: true }).waitFor();
  assert.equal(await page().evaluate(() => window.__copiedCompanionCommand), trustCommand);
  await page().evaluate(() => { navigator.clipboard.writeText = async () => { throw new Error('Synthetic clipboard denial'); }; });
  await page().getByRole('button', { name: 'Copy Trust this downloaded file', exact: true }).click();
  await page().getByText('Copy was unavailable. Select the trust command and copy it manually.', { exact: true }).waitFor();
  pass();
  await page().getByLabel('Paste companion result', { exact: true }).fill('PURVIEW_REFERENCE_REGISTRATION {"status":"ExactReferenceVerified"}');
  await page().getByText(/Paste only the complete line beginning A365GW_CONNECTION_RESULT:/).waitFor();
  assert.equal(await counter('ReviewPurviewTenantConnectionCompletionAsync'), 0);
  await paste({ ...evidence, tenantId: '99999999-9999-4999-8999-999999999999' });
  await page().getByText(/not the single fresh result/).waitFor();
  assert.equal(await counter('ReviewPurviewTenantConnectionCompletionAsync'), 0);
  pass();
  const largeEvidence = { ...evidence, sensitiveInformationTypes: Array.from({ length: 354 }, (_, index) => ({
    id: `77777777-7777-4777-8777-${String(index + 1).padStart(12, '0')}`,
    exactName: `Synthetic classifier ${index + 1} ${'n'.repeat(100)}`, publisher: 'Synthetic fixture'
  })) };
  assert.ok(Buffer.byteLength(output(largeEvidence)) > 32 * 1024, 'Realistic paste must cross the default Blazor circuit limit');
  assert.ok(Buffer.byteLength(output(largeEvidence)) <= 512 * 1024, 'Paste must retain the bounded evidence limit');
  await paste(largeEvidence);
  await page().getByText(/354 current sensitive information types/).waitFor();
  assert.equal(await page().getByLabel('Paste companion result', { exact: true }).getAttribute('aria-invalid'), 'false');
  for (const width of [1440, 390, 360]) {
    await page().setViewportSize({ width, height: 1000 });
    await inspect(`first-run trust guidance and large paste at ${width}`);
    await capture(`connection-first-run-${width}`);
    pass();
  }
  await page().setViewportSize({ width: 1440, height: 1000 });
  await page().getByRole('button', { name: 'Review companion completion', exact: true }).click();
  await modal('Submit companion evidence for verification?');
  await page().keyboard.press('Escape');
  await page().getByRole('alertdialog', { name: 'Submit companion evidence for verification?', exact: true })
    .waitFor({ state: 'hidden' });
  await page().getByText('Review cancelled. No mutation was sent from this review; previously accepted work is unchanged.',
    { exact: true }).waitFor();
  assert.equal(await page().getByLabel('Paste companion result', { exact: true }).inputValue().then(value => value.length),
    output(largeEvidence).length, 'Cancelling review preserves the pasted result for correction');
  await page().getByLabel('Paste companion result', { exact: true }).fill('');
  await poll(() => page().getByRole('button', { name: 'Review companion completion', exact: true }).isDisabled(),
    value => value, 'cleared paste invalidates completion review');
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 0);
  await paste(largeEvidence);
  await page().getByText(/354 current sensitive information types/).waitFor();
  pass();
  await page().getByRole('button', { name: 'Review companion completion', exact: true }).click();
  await modal('Submit companion evidence for verification?');
  const completionReviewId = (await state()).protection.latestOperationId;
  assert.notEqual(completionReviewId, connection.latestOperationId, 'completion has its own authorization ID');
  await page().evaluate(() => {
    const retain = window.A365Gateway.retainProtectionRecovery;
    window.A365Gateway.retainProtectionRecovery = async (uri, operationId) => {
      window.__completionRecovery = { uri, operationId };
      return retain(uri, operationId);
    };
  });
  await page().getByRole('button', { name: 'Submit for verification', exact: true }).click();
  await poll(state, value => value.protection.connectionStatus === 'PendingVerification', 'separate connection verification');
  await page().getByText('Companion result received. Checking Gateway access.', { exact: true }).waitFor();
  await page().locator('.page-header [role="progressbar"]').waitFor();
  assert.equal(await page().locator('nav[aria-label="Purview setup steps"] li').count(), 4);
  await page().emulateMedia({ reducedMotion: 'no-preference' });
  assert.notEqual(await page().locator('.page-header .activity-ring').evaluate(element => getComputedStyle(element).animationName), 'none');
  await page().emulateMedia({ reducedMotion: 'reduce' });
  assert.equal(await page().locator('.page-header .activity-ring').evaluate(element => getComputedStyle(element).animationName), 'none');
  await capture('connection-active-status');
  const completionRecovery = await page().evaluate(() => window.__completionRecovery);
  assert.equal(completionRecovery.operationId, connection.latestOperationId);
  assert.equal(new URL(completionRecovery.uri).searchParams.get('operation'), connection.latestOperationId);
  assert.equal(new URL(page().url()).searchParams.get('operation'), connection.latestOperationId);
  assert.equal((await state()).protection.completionReviewId, completionReviewId);
  assert.equal(await page().getByText(/The protection action was not completed/).count(), 0);
  assert.equal(await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).count(), 0);
  assert.equal(await page().locator('#purview-companion-output, #purview-companion-evidence').count(), 0);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await page().getByText('Connection verified', { exact: true }).count(), 0);
  pass();
  await page().reload();
  await page().getByText('Companion result received. Checking Gateway access.', { exact: true }).waitFor();
  assert.equal(new URL(page().url()).searchParams.get('operation'), connection.latestOperationId);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  pass();
  await go(`/settings/connection?operation=${completionReviewId}`);
  await page().waitForURL(`${origin}/settings/connection?operation=${connection.latestOperationId}`);
  await page().getByText('Companion result received. Checking Gateway access.', { exact: true }).waitFor();
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await page().getByText(/The protection result is not confirmed/).count(), 0);
  await inspect('submitted completion read-only recovery');
  pass();
  await api('read-errors', { methods: ['GetAgentIdentityBlueprintsAsync'] });
  await setupStep('policy').click();
  await page().getByText('Resolved blueprints could not be loaded', { exact: true }).waitFor();
  await setupStep('connection').click();
  await page().getByText('Companion result received. Checking Gateway access.', { exact: true }).waitFor();
  await api('read-errors', { methods: [] });
  await api('protection', { action: 'connection-verified' });
  await page().getByRole('heading', { name: 'Purview connection verified', exact: true }).waitFor();
  assert.equal(await page().getByRole('button', { name: 'Review connection refresh', exact: true }).isEnabled(), true);
  await inspect('cross-task read failure does not trap connection recovery');
  pass();
  assert.equal(await page().locator('.protection-technical-details').evaluate(element => element.open), false);
  const connectionOutcome = await page().locator('#protection-journey-outcome').innerText();
  for (const label of ['What happened', 'Why this matters', 'What remains', 'Next step'])
    assert.ok(connectionOutcome.includes(label));
  assert.ok(connectionOutcome.includes('does not create a DLP policy'));
  const announcementBox = await page().locator('#protection-journey-outcome .outcome-announcement').boundingBox();
  assert.ok(announcementBox && announcementBox.width <= 1 && announcementBox.height <= 1);
  await page().locator('.protection-technical-details summary').click();
  await page().getByText(/No runtime samples were tested/).waitFor();
  await page().locator('.protection-technical-details summary').click();
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await page().locator('#purview-sensitive-information-type').count(), 0);
  const inventoryCount = (await state()).protection.classifiers.length;
  assert.ok((await page().locator('[data-testid="tenant-inventory-count"]').innerText()).includes(`${inventoryCount} existing sensitive information type`));
  const inventoryReads = await counter('GetPurviewSensitiveInformationTypesAsync');
  await page().getByRole('button', { name: 'Reload inventory', exact: true }).click();
  await poll(counter.bind(null, 'GetPurviewSensitiveInformationTypesAsync'), count => count === inventoryReads + 1, 'read saved inventory once');
  assert.equal(await page().locator('#purview-sensitive-information-type').count(), 0);
  await inspect('companion and inventory handoff');
  await page().evaluate(() => scrollTo(0, 0));
  await capture('connection-handoff');
  await page().setViewportSize({ width: 360, height: 1000 });
  await inspect('completed connection outcome at 360px');
  await capture('connection-outcome-360');
  await page().setViewportSize({ width: 1440, height: 1000 });
  pass();

  await harness.tabTo(page().getByRole('link', { name: 'Continue to shared policies', exact: true }), 'connection next step');
  await page().keyboard.press('Enter');
  await page().waitForURL('**/settings/policy?operation=*');
  assert.equal(await counter('StartPurviewDlpProfileOperationAsync'), 0);
  const earlierConnection = page().locator('details.previous-protection-operation');
  await earlierConnection.waitFor();
  assert.equal(await earlierConnection.evaluate(element => element.open), false);
  assert.ok((await earlierConnection.innerText()).includes('Completed earlier task: Connect tenant'));
  await earlierConnection.locator(':scope > summary').click();
  await page().getByText('The saved operation is complete', { exact: true }).waitFor();
  await earlierConnection.locator(':scope > summary').click();
  await page().locator('#dlp-blueprint').selectOption('0');
  await page().locator('input[data-sit-id]').first().waitFor();
  const firstType = page().locator('input[data-sit-id]').first();
  const thresholdInput = field => page().locator(`input[data-threshold-field="${field}"]`).first();
  await firstType.check();
  for (const [field, value] of Object.entries({ MinCount: '1', MaxCount: '-1', MinConfidence: '75', MaxConfidence: '100' }))
    assert.equal(await thresholdInput(field).inputValue(), value, `visible new-selection default ${field}`);
  await thresholdInput('MinCount').fill('2');
  await thresholdInput('MaxCount').fill('4');
  await thresholdInput('MinConfidence').fill('85');
  await thresholdInput('MaxConfidence').fill('95');
  await firstType.uncheck();
  await firstType.check();
  for (const [field, value] of Object.entries({ MinCount: '2', MaxCount: '4', MinConfidence: '85', MaxConfidence: '95' }))
    assert.equal(await thresholdInput(field).inputValue(), value, `reselected draft preserves ${field}`);
  for (const [field, value] of Object.entries({ MinCount: '1', MaxCount: '-1', MinConfidence: '75', MaxConfidence: '100' }))
    await thresholdInput(field).fill(value);
  for (const sit of await page().locator('input[data-sit-id]').all()) await sit.check();
  assert.equal(await page().getByRole('combobox', { name: /blueprint/i }).count(), 1, 'policy task has only one blueprint selection');
  await page().evaluate(() => scrollTo(0, 0));
  await capture('policy-editor-defaults-desktop');
  for (const width of [390, 360]) {
    await page().setViewportSize({ width, height: 1000 });
    await inspect(`selected types and adjustable defaults at ${width}px`);
    await capture(`policy-editor-defaults-${width}`);
  }
  await page().setViewportSize({ width: 1440, height: 1000 });
  await page().locator('input[type="radio"][value="Enforce"]').check();
  await page().getByRole('button', { name: 'Review protection choices', exact: true }).click();
  await modal('Review shared Purview configuration');
  await page().getByRole('button', { name: 'Confirm and queue shared policy', exact: true }).click();
  await poll(counter.bind(null, 'StartPurviewDlpProfileOperationAsync'), count => count === 1, 'one new shared policy in the same journey');
  await page().getByText('The Gateway accepted the explicitly reviewed shared policy.', { exact: false }).waitFor();
  await api('protection', { action: 'policy-readback' });
  await page().getByRole('heading', { name: 'Policy saved; behavior is not verified', exact: true }).waitFor();
  const guidedProfile = (await state()).protection.profileId;
  await page().getByRole('link', { name: 'Continue to behavior tests', exact: true }).click();
  await page().waitForURL('**/settings/runtime?*');
  assert.equal(new URL(page().url()).searchParams.get('profile'), guidedProfile);
  assert.equal(await counter('ExecuteRuntimeSamples'), 0);
  await page().getByRole('link', { name: 'Choose test samples', exact: true }).click();
  assert.equal(new URL(page().url()).pathname, '/settings/runtime');
  assert.equal(new URL(page().url()).searchParams.get('profile'), guidedProfile);
  await page().getByRole('button', { name: 'Verify shared profile', exact: true }).click();
  await fillAndReviewSamples();
  await page().getByRole('button', { name: 'Confirm and send approved batch', exact: true }).click();
  await page().locator('#protection-journey-outcome').getByRole('heading', { name: 'Approved behavior is currently verified', exact: true }).waitFor();
  assert.equal(await counter('ExecuteRuntimeSamples'), 1);
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await counter('StartPurviewDlpProfileOperationAsync'), 1);
  await inspect('complete connection policy runtime onward journey');
  await page().evaluate(() => scrollTo(0, 0));
  await capture('guided-runtime-outcome');
  await page().locator('#protection-journey-outcome').getByRole('link', { name: 'Continue to agents', exact: true }).click();
  await page().waitForURL(`${origin}/agents`);
  await page().locator('[data-protection="Microsoft Purview"] [aria-label="Status: Off"]').first().waitFor();
  assert.equal(await counter('UpdateAgentFeaturesAsync'), 0, 'shared policy and testing did not enable an agent');
  await inspect('explicit per-agent continuation preserves Off');
  pass();

  await reset('m4-connection');
  await go('/settings/connection');
  await page().getByRole('button', { name: 'Review tenant connection', exact: true }).click();
  await page().getByRole('button', { name: 'Confirm and start', exact: true }).click();
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  const lostCompletionSource = (await state()).protection.latestOperationId;
  await upload({ ...evidence, operationId: lostCompletionSource, observedAtUtc: new Date().toISOString(),
    inventoryExpiresAtUtc: await page().locator('.windows-companion-steps time').getAttribute('datetime') });
  await page().getByText(/Evidence checked for this tenant/).waitFor();
  assert.equal(await page().getByLabel('Paste companion result', { exact: true }).inputValue(), '');
  await page().getByRole('button', { name: 'Review companion completion', exact: true }).click();
  await modal('Submit companion evidence for verification?');
  await api('protection', { action: 'lose-next-connection-completion-response' });
  await page().getByRole('button', { name: 'Submit for verification', exact: true }).click();
  await page().getByRole('heading', { name: 'The protection result is not confirmed', exact: true }).waitFor();
  assert.equal(new URL(page().url()).searchParams.get('operation'), lostCompletionSource);
  assert.equal(await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).count(), 0);
  await page().getByRole('button', { name: 'Check existing operation', exact: true }).click();
  await page().getByText('Companion result received. Checking Gateway access.', { exact: true }).waitFor();
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await page().getByText(/The protection action was not completed/).count(), 0);
  assert.equal(await page().getByText(/The protection result is not confirmed/).count(), 0);
  await inspect('lost completion response readback');
  pass();
  await api('protection', { action: 'connection-failed' });
  await page().getByRole('heading', { name: 'The saved operation needs attention', exact: true }).waitFor();
  await page().getByText('Connection verification failed.', { exact: true }).waitFor();
  await page().locator('.protection-technical-details summary').click();
  assert.equal(await page().locator('.protection-technical-details').getByText('Failed', { exact: true }).count(), 2,
    'The operation and failed discovery must display the terminal provider failure');
  assert.equal(await page().locator('.protection-technical-details').getByText('Pending', { exact: true }).count(), 6);
  await page().locator('.operation-failure-code').getByText('PURVIEW_CONNECTION_PROVIDER_UNVERIFIED', { exact: true }).waitFor();
  assert.equal(await page().getByText('Connection verified', { exact: true }).count(), 0);
  assert.equal(await page().getByText('Awaiting admin', { exact: true }).count(), 0);
  assert.ok(await page().getByText('Failed', { exact: true }).count() >= 2);
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 1);
  assert.match(await page().locator('.operation-meta time').innerText(), /UTC$/);
  await inspect('truthful provider verification failure');
  await capture('connection-verification-failed');
  pass();

  await reset('m4-connection-unknown');
  await go('/settings/connection');
  await page().getByRole('button', { name: 'Review tenant connection', exact: true }).click();
  await page().getByRole('button', { name: 'Confirm and start', exact: true }).click();
  await page().getByRole('heading', { name: 'The protection result is not confirmed', exact: true }).waitFor();
  await page().getByRole('button', { name: 'Check existing operation', exact: true }).click();
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  pass();

  await reset('m4-connection-expired');
  const expiredConnection = (await state()).protection;
  await go(`/settings/connection?operation=${expiredConnection.latestOperationId}`);
  await page().getByText('Connection launch expired.', { exact: true }).waitFor();
  assert.equal(await page().locator('a[download]').count(), 0);
  assert.equal(await page().locator('#purview-companion-evidence').isDisabled(), true);
  assert.equal(await page().locator('#purview-companion-output').isDisabled(), true);
  assert.equal(await page().getByRole('button', { name: 'Review connection refresh', exact: true }).isEnabled(), true);
  await page().getByRole('button', { name: 'Review connection refresh', exact: true }).click();
  await modal('Confirm connect the Microsoft Purview tenant?');
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 0);
  await page().getByRole('button', { name: 'Confirm and start', exact: true }).click();
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  const refreshedConnection = (await state()).protection;
  assert.notEqual(refreshedConnection.latestOperationId, expiredConnection.latestOperationId);
  assert.equal(new URL(page().url()).searchParams.get('operation'), refreshedConnection.latestOperationId);
  assert.ok(Date.parse(await page().locator('.windows-companion-steps time').getAttribute('datetime')) > Date.now());
  assert.equal(await counter('StartPurviewTenantConnectionOperationAsync'), 1);
  assert.equal(await page().getByRole('button', { name: 'Review connection refresh', exact: true }).isDisabled(), true);
  await inspect('expired companion reviewed replacement');
  await capture('connection-expired-recovery');
  pass();

  await reset('m4-ready');
  await go('/settings/collection');
  await page().locator('#purview-sensitive-information-type').selectOption('0');
  await page().getByRole('button', { name: 'Reload inventory', exact: true }).click();
  await page().getByText(/Earlier choice: Synthetic employee identifier/).waitFor();
  assert.equal(await page().locator('#purview-sensitive-information-type').inputValue(), '');
  assert.equal(await counter('StartPurviewKnowYourDataOperationAsync'), 0);
  await inspect('optional collection keeps its separate deliberate selector');
  pass();

  async function policyReview(scenario, width = 1440) {
    await reset(scenario, 'Administrator', width);
    await go('/settings/policy');
    assert.equal(await page().locator('details.saved-policy-library').evaluate(element => element.open), false);
    await openSavedPolicyDetails();
    await page().getByRole('button', { name: 'Review settings', exact: true }).click();
    await poll(() => page().evaluate(() => document.activeElement?.id), id => id === 'dlp-review-form-heading', 'editing moves focus to the form above the saved library');
    const threshold = page().locator('[data-threshold-field="MinCount"]').first();
    await threshold.fill('2');
    await threshold.blur();
    await page().locator('input[id$="impact-acknowledgment"]').check();
    await page().getByRole('button', { name: 'Review protection choices', exact: true }).click();
    await modal('Review shared Purview configuration');
    assert.ok((await page().getByRole('alertdialog').innerText()).includes('All agents using this blueprint'));
    assert.ok((await page().getByRole('alertdialog').innerText()).includes('ANY selected SIT (OR)'));
    return page().getByRole('button', { name: 'Confirm and queue shared policy', exact: true });
  }
  let confirm = await policyReview('m4-ready');
  await confirm.click();
  await poll(counter.bind(null, 'StartPurviewDlpProfileOperationAsync'), count => count === 1, 'one reviewed policy start');
  await page().getByText('The Gateway accepted the explicitly reviewed shared policy.', { exact: false }).waitFor();
  await inspect('accepted shared policy');
  pass();
  confirm = await policyReview('m4-policy-conflict');
  await confirm.click();
  await page().getByText('Protection configuration needs attention', { exact: true }).waitFor();
  assert.equal(await counter('StartPurviewDlpProfileOperationAsync'), 0);
  pass();
  confirm = await policyReview('m4-policy-unknown');
  await confirm.click();
  await page().getByText('The shared policy result is not confirmed.', { exact: true }).waitFor();
  await page().getByRole('button', { name: 'Check existing operation', exact: true }).click();
  await page().getByText('The Gateway accepted the explicitly reviewed shared policy.', { exact: false }).waitFor();
  assert.equal(await counter('StartPurviewDlpProfileOperationAsync'), 1);
  pass();

  async function fillAndReviewSamples() {
    await page().locator('textarea[data-runtime-negative]').waitFor();
    const positives = page().locator('textarea[data-runtime-positive]');
    for (let index = 0; index < await positives.count(); index++)
      await positives.nth(index).fill(`M4_PRIVATE_POSITIVE_${index}_SYNTHETIC_ONLY`);
    await page().locator('textarea[data-runtime-negative]').fill('M4_PRIVATE_NEGATIVE_SYNTHETIC_ONLY');
    await page().locator('input[id$="-synthetic"]').check();
    await page().getByRole('button', { name: 'Review test batch', exact: true }).click();
    await modal('Review protection test');
    assert.equal(await counter('ExecuteRuntimeSamples'), 0);
    await page().locator('input[id$="-target"]').check();
    return page().getByRole('button', { name: 'Confirm and send approved batch', exact: true });
  }
  async function runtimeReview(scenario, width = 1440) {
    await reset(scenario, 'Administrator', width);
    await go('/settings/runtime');
    await page().getByRole('button', { name: 'Verify shared profile', exact: true }).click();
    return fillAndReviewSamples();
  }
  for (const [scenario, width] of [['m4-ready', 1440], ['m4-simulation', 390], ['m4-runtime-unknown-committed', 360]]) {
    confirm = await runtimeReview(scenario, width);
    if (scenario.includes('unknown')) harness.expectConsoleError('/portal/protection/runtime-tests/', /502/);
    await confirm.click();
    if (scenario.includes('unknown')) {
      await page().getByText(/transport outcome is unknown/).waitFor();
      await page().getByRole('button', { name: 'Recover safe report', exact: true }).click();
    }
    await page().getByText('Historical runtime test receipt', { exact: true }).waitFor();
    assert.equal(await counter('ExecuteRuntimeSamples'), 1);
    await poll(
      () => page().locator('textarea[data-runtime-sample]').evaluateAll(inputs => inputs.map(input => input.value)),
      values => values.length === 3 && values.every(value => value === ''),
      'private samples erased after execution');
    assert.ok(!JSON.stringify(await state()).includes('M4_PRIVATE_'), 'Raw samples entered fixture state');
    await inspect(`${scenario} safe receipt`);
    if (width < 760) {
      const caption = await page().locator('.runtime-observations caption').boundingBox();
      assert.ok(caption && caption.width > 100 && caption.height < 100, 'The narrow report caption collapsed into a vertical column');
    }
    await capture(`${scenario}-receipt`);
    await page().getByRole('link', { name: 'Open saved report', exact: true }).click();
    await page().waitForURL('**/protection/runtime-tests/*');
    await page().getByRole('heading', { name: 'Protection runtime report', exact: true }).waitFor();
    await page().getByText('Historical runtime test receipt', { exact: true }).waitFor();
    assert.equal(await page().locator('textarea').count(), 0);
    assert.equal(await counter('ExecuteRuntimeSamples'), 1);
    pass();
  }
  confirm = await runtimeReview('m4-runtime-expiry');
  await confirm.click();
  await page().locator('.journey-outcome[id^="runtime-outcome-"]')
    .getByRole('heading', { name: 'Approved behavior is currently verified', exact: true }).waitFor();
  await page().locator('#protection-journey-outcome')
    .getByRole('heading', { name: 'Approved behavior is currently verified', exact: true }).waitFor();
  await page().locator('#protection-journey-outcome')
    .getByRole('heading', { name: 'Earlier verification has expired', exact: true }).waitFor({ timeout: 20000 });
  assert.equal(await page().locator('.profile-card-header [aria-label="Status: Enforcing"]').count(), 0);
  assert.equal(await counter('ExecuteRuntimeSamples'), 1, 'Expiry never resubmits private samples');
  assert.equal(await counter('StartPurviewDlpProfileOperationAsync'), 0);
  await inspect('replacement runtime expiry updates parent guidance and card without interaction');
  await capture('runtime-parent-readback-expired');
  pass();
  await reset('m4-off');
  await go('/settings/runtime');
  await page().getByRole('button', { name: 'Verify shared profile', exact: true }).click();
  await page().getByText(/configured\/off. No samples are collected or sent/).waitFor();
  assert.equal(await page().locator('textarea').count(), 0);
  assert.equal(await counter('ExecuteRuntimeSamples'), 0);
  pass();

  await reset('m4-ready');
  await go('/settings');
  await harness.zoomTo200Percent();
  for (const route of ['/settings', '/settings/connection', '/settings/policy', '/settings/runtime', '/settings/defaults']) {
    await go(route);
    await inspect(`actual 200% zoom ${route}`);
    if (route === '/settings/connection' || route === '/settings/runtime') {
      const nextAction = page().locator('#protection-journey-outcome a');
      await harness.tabTo(nextAction, `${route} outcome action at 200%`);
      assert.ok(await nextAction.evaluate(element => {
        const box = element.getBoundingClientRect();
        return element.matches(':focus-visible') && box.top >= 0 && box.bottom <= innerHeight &&
          box.left >= 0 && box.right <= innerWidth;
      }));
      await page().evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await capture(route === '/settings/connection' ? 'connection-outcome-zoom-200' : 'runtime-outcome-zoom-200');
    }
  }
  await reset('m4-connection');
  await go('/settings/connection');
  await harness.tabTo(page().getByRole('button', { name: 'Review tenant connection', exact: true }), 'connection review');
  await page().keyboard.press('Enter');
  await modal('Confirm connect the Microsoft Purview tenant?');
  await harness.tabTo(page().getByRole('button', { name: 'Confirm and start', exact: true }), 'connection confirmation');
  await page().keyboard.press('Enter');
  await page().getByRole('link', { name: 'Download the Windows Purview companion', exact: true }).waitFor();
  const zoomConnection = (await state()).protection;
  await harness.tabTo(page().getByLabel('Paste companion result', { exact: true }), 'companion result at 200%');
  await page().keyboard.insertText(output({ ...largeEvidence, operationId: zoomConnection.latestOperationId,
    observedAtUtc: new Date().toISOString(),
    inventoryExpiresAtUtc: await page().locator('.windows-companion-steps time').getAttribute('datetime') }));
  await page().getByText(/354 current sensitive information types/).waitFor();
  await page().keyboard.press('Tab');
  assert.ok(await page().locator('.companion-upload summary').evaluate(element => element === document.activeElement));
  await page().keyboard.press('Enter');
  assert.equal(await page().locator('.companion-upload').evaluate(element => element.open), true);
  await inspect('actual 200% first-run guidance and keyboard paste');
  await capture('connection-first-run-zoom-200');
  await harness.tabTo(page().getByRole('button', { name: 'Review companion completion', exact: true }), 'pasted result review');
  await page().keyboard.press('Enter');
  await modal('Submit companion evidence for verification?');
  await page().keyboard.press('Escape');
  assert.equal(await counter('CompletePurviewTenantConnectionOperationAsync'), 0);
  pass();
  confirm = await runtimeReview('m4-ready');
  await inspect('actual 200% sample review');
  await capture('runtime-review-zoom-200');
  await page().keyboard.press('Escape');
  assert.equal(await counter('ExecuteRuntimeSamples'), 0);
  await poll(
    () => page().locator('textarea[data-runtime-sample]').evaluateAll(inputs => inputs.map(input => input.value)),
    values => values.length === 3 && values.every(value => value === ''),
    'private samples erased after cancelling review');
  pass();
}

if (process.argv.includes('--help')) {
  console.log('node .\\tools\\Test-M4Browser.cjs --origin <HTTPS loopback fixture URL> --playwright <package directory> --chrome <installed Chrome executable>');
  console.log('Set NODE_EXTRA_CA_CERTS to the fixture READY publicCertificatePath for this process only.');
} else {
  runBrowserAcceptance({ milestone: 'M4', journeys }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
