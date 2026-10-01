'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { webcrypto } = require('node:crypto');

async function main() {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'Gateway.AdminUi', 'wwwroot', 'purview-runtime-test.js'), 'utf8');
  const protocol = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const ids = Array.from({ length: 12 }, (_, index) => `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`);
  let checks = 0;
  const pass = () => { checks++; };
  if (!globalThis.crypto) globalThis.crypto = webcrypto;

  assert.equal(protocol.exactUtf8('a'.repeat(8192)).length, 8192);
  assert.equal(protocol.exactUtf8('€'.repeat(2730)).length, 8190);
  for (const value of ['', 'a'.repeat(8193), '€'.repeat(2731), '\ud800', '\udc00']) {
    assert.throws(() => protocol.exactUtf8(value));
    pass();
  }
  pass();
  const first = await protocol.commitSample('a'.repeat(64), ids[0], ids[1], 'Synthetic example');
  const second = await protocol.commitSample('b'.repeat(64), ids[0], ids[1], 'Synthetic example');
  assert.notEqual(first.contentHash, second.contentHash);
  assert.equal(first.utf8ByteCount, Buffer.byteLength('Synthetic example'));
  pass();
  const full = {
    positiveSamples: ids.slice(0, 8).map(caseId => ({ caseId, utf8ByteCount: 8192 })),
    negativeSample: { caseId: ids[8], utf8ByteCount: 8192 }
  };
  assert.deepEqual(protocol.planBatches(full).map(batch => batch.length), [7, 1]);
  pass();

  let requests = [];
  let recordedState;
  function create() {
    const positive = { value: 'SYNTHETIC-EMPLOYEE-0001', readOnly: false, dataset: { sitId: ids[2] } };
    const negative = { value: 'Synthetic benign control.', readOnly: false };
    const listeners = new Map();
    const root = {
      dataset: { policyMode: 'Enforce', profileId: ids[0], profileVersion: 'AAAAAAAAAAE=' },
      isConnected: true,
      querySelectorAll(selector) {
        return selector.includes('runtime-positive') ? [positive] : [positive, negative];
      },
      querySelector: () => negative,
      addEventListener: (name, callback) => listeners.set(name, callback),
      removeEventListener: name => listeners.delete(name)
    };
    const notifications = [];
    const session = protocol.createSession(root, {
      invokeMethodAsync: async (...arguments_) => { notifications.push(arguments_); }
    });
    globalThis.location = { protocol: 'https:', href: 'https://fixture.invalid/settings/runtime' };
    recordedState = { userState: null, _index: 3 };
    globalThis.history = {
      state: recordedState,
      replaceState(state, _, url) {
        assert.equal(state, recordedState, 'Runtime retention discarded router state');
        this.state = state;
        globalThis.location.href = new URL(url).href;
      }
    };
    requests = [];
    return { session, root, positive, negative, listeners, notifications };
  }
  function authorization(manifest) {
    return {
      profileId: ids[0], reviewTokenId: ids[1], reviewToken: 'synthetic-test-authority',
      idempotencyKey: ids[3], expectedRowVersion: 'AAAAAAAAAAE=', policyMode: 'Enforce',
      suiteNonce: manifest.suite.suiteNonce, positiveCaseIds: manifest.batches[0],
      negativeCaseId: manifest.suite.negativeSample.caseId
    };
  }
  function transport(post) {
    globalThis.fetch = async (url, options) => {
      requests.push({ url, options });
      assert.equal(new URL(globalThis.location.href).searchParams.get('runtimeTest'), ids[1]);
      if (url === '/portal/protection/runtime-tests/antiforgery') {
        assert.notEqual(options.method, 'POST');
        return { ok: true, json: async () => ({ headerName: 'X-Gateway-CSRF', requestToken: 'synthetic-csrf' }) };
      }
      assert.equal(url, `/portal/protection/runtime-tests/${ids[0]}/execute`, 'Unplanned transport has no network fallback');
      assert.equal(options.method, 'POST');
      assert.equal(options.redirect, 'error');
      return post(options);
    };
  }

  {
    const test = create();
    const manifest = await test.session.prepare();
    assert.ok(test.positive.readOnly && test.negative.readOnly);
    assert.ok(!JSON.stringify(manifest).includes(test.positive.value), 'Raw positive entered the interop manifest');
    assert.ok(!JSON.stringify(manifest).includes(test.negative.value), 'Raw negative entered the interop manifest');
    assert.equal(requests.length, 0);
    pass();
    transport(async options => {
      const body = JSON.parse(options.body);
      assert.deepEqual(body.samples.map(sample => sample.content), [test.positive.value, test.negative.value]);
      return { ok: true, json: async () => ({ operationId: ids[1] }) };
    });
    const permit = authorization(manifest);
    const result = await test.session.execute(permit);
    assert.equal(result.outcomeUnknown, false);
    assert.equal(requests.filter(request => request.options.method === 'POST').length, 1);
    assert.equal(permit.reviewToken, null);
    assert.ok(!globalThis.location.href.includes('synthetic-test-authority'));
    pass();
    await assert.rejects(() => test.session.execute(authorization(manifest)));
    assert.equal(requests.length, 2);
    pass();
    test.session.dispose();
    assert.equal(test.positive.value, '');
    assert.equal(test.negative.value, '');
    pass();
  }
  {
    const test = create();
    const manifest = await test.session.prepare();
    transport(async () => { throw new Error('Synthetic lost response'); });
    const result = await test.session.execute(authorization(manifest));
    assert.equal(result.outcomeUnknown, true);
    await assert.rejects(() => test.session.execute(authorization(manifest)));
    assert.equal(requests.filter(request => request.options.method === 'POST').length, 1);
    test.session.dispose();
    pass();
  }
  {
    const test = create();
    const manifest = await test.session.prepare();
    test.positive.value = 'Changed after review';
    await assert.rejects(() => test.session.execute(authorization(manifest)));
    assert.equal(requests.length, 0);
    test.listeners.get('input')();
    assert.deepEqual(test.notifications, [['RuntimeInputsChanged']]);
    test.session.dispose();
    pass();
  }
  {
    const test = create();
    const manifest = await test.session.prepare();
    globalThis.location.protocol = 'http:';
    await assert.rejects(() => test.session.execute(authorization(manifest)));
    assert.equal(requests.length, 0);
    test.session.dispose();
    pass();
  }
  {
    const test = create();
    const manifest = await test.session.prepare();
    globalThis.history.replaceState = () => { throw new Error('Synthetic retention failure'); };
    const result = await test.session.execute(authorization(manifest));
    assert.equal(result.outcomeUnknown, true);
    assert.equal(requests.length, 0);
    test.session.dispose();
    pass();
  }
  {
    const test = create();
    const pending = test.session.prepare();
    test.session.dispose();
    await assert.rejects(() => pending);
    assert.equal(test.positive.value, '');
    assert.equal(test.negative.value, '');
    pass();
  }
  assert.equal(protocol.browserExecutionBudgetMilliseconds, 210000);
  pass();
  assert.ok(checks > 0);
  console.log(`PASS: ${checks} actual runtime-browser protocol checks; synthetic in-memory transport only, no network or provider calls.`);
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
