import test from 'node:test';
import assert from 'node:assert/strict';
import { config, dispatch, run } from '../netlify/functions/dispatch.mjs';

const env = { L5H_GITHUB_DISPATCH_TOKEN: 'private-test-token', L5H_GITHUB_REPOSITORY: 'owner/repo' };
const DISPATCH = 'https://api.github.com/repos/owner/repo/actions/workflows/keepalive.yml/dispatches';
const STATE = 'https://api.github.com/repos/owner/repo/contents/state/cloud-state.env?ref=main';

test('dispatches due-only work to the fixed GitHub endpoint', async () => {
  assert.equal(config.schedule, '*/30 * * * *');
  await dispatch(env, async (url, options) => {
    assert.equal(url, DISPATCH);
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
    await assert.rejects(run(invalid, () => assert.fail('unexpected request')), /configuration/);
  }
});
test('fails without revealing upstream content or credentials', async () => {
  await assert.rejects(dispatch(env, async () => ({ status: 401 })), { message: 'GitHub dispatch failed (HTTP 401)' });
  await assert.rejects(dispatch(env, async () => { throw new Error(env.L5H_GITHUB_DISPATCH_TOKEN); }), { message: 'GitHub dispatch network failure or timeout' });
});

function fakeGitHub(stateResponse) {
  const calls = [];
  const request = async (url, options) => {
    calls.push(url);
    if (url === STATE) {
      assert.equal(options.method, 'GET');
      assert.equal(options.redirect, 'error');
      return stateResponse();
    }
    assert.equal(url, DISPATCH);
    return { status: 204 };
  };
  return { calls, request };
}

test('skips the workflow run while nothing is due', async () => {
  const gh = fakeGitHub(() => ({ status: 200, text: async () => 'CLAUDE_LAST=1\nNEXT_DUE=2000000\n' }));
  const result = await run(env, gh.request, 1000000 * 1000);
  assert.deepEqual(result, { dispatched: false, due: 2000000 });
  assert.deepEqual(gh.calls, [STATE]);
});
test('dispatches once the recorded due time has arrived', async () => {
  const gh = fakeGitHub(() => ({ status: 200, text: async () => 'NEXT_DUE=2000000\n' }));
  assert.equal((await run(env, gh.request, 2000000 * 1000)).dispatched, true);
  assert.deepEqual(gh.calls, [STATE, DISPATCH]);
});
test('fails open when the state cannot be read', async () => {
  for (const response of [
    () => ({ status: 403, text: async () => '' }),
    () => ({ status: 200, text: async () => 'CLAUDE_LAST=1\n' }),
    () => { throw new Error('network'); },
  ]) {
    const gh = fakeGitHub(response);
    assert.equal((await run(env, gh.request, 0)).dispatched, true);
    assert.deepEqual(gh.calls, [STATE, DISPATCH]);
  }
});
