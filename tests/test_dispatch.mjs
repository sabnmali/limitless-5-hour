import test from 'node:test';
import assert from 'node:assert/strict';
import { config, dispatch } from '../netlify/functions/dispatch.mjs';

const env = { L5H_GITHUB_DISPATCH_TOKEN: 'private-test-token', L5H_GITHUB_REPOSITORY: 'owner/repo' };
test('dispatches due-only work to the fixed GitHub endpoint', async () => {
  assert.equal(config.schedule, '*/30 * * * *');
  await dispatch(env, async (url, options) => {
    assert.equal(url, 'https://api.github.com/repos/owner/repo/actions/workflows/keepalive.yml/dispatches');
    assert.deepEqual(JSON.parse(options.body), { ref: 'main' });
    assert.equal(options.headers.Authorization, 'Bearer private-test-token');
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
    return { status: 204 };
  });
});
test('rejects missing credentials and URL injection before any request', async () => {
  for (const invalid of [{ ...env, L5H_GITHUB_DISPATCH_TOKEN: '' }, { ...env, L5H_GITHUB_REPOSITORY: 'attacker.invalid/x?secret=' }]) {
    await assert.rejects(dispatch(invalid, () => assert.fail('unexpected request')), /configuration/);
  }
});
test('fails without revealing upstream content or credentials', async () => {
  await assert.rejects(dispatch(env, async () => ({ status: 401 })), { message: 'GitHub dispatch failed (HTTP 401)' });
  await assert.rejects(dispatch(env, async () => { throw new Error(env.L5H_GITHUB_DISPATCH_TOKEN); }), { message: 'GitHub dispatch network failure or timeout' });
});
