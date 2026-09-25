// Netlify invokes scheduled functions privately, only on published deployments.
// The token needs Actions: write for ONE repository, never account-wide access.
// Optional Contents: read on the same repository lets it skip runs that would
// find nothing due; without it every invocation dispatches, as before.
export const config = { schedule: '*/30 * * * *' };

const API = 'https://api.github.com';

function headers(token, accept = 'application/vnd.github+json') {
  return {
    Authorization: `Bearer ${token}`,
    Accept: accept,
    'X-GitHub-Api-Version': '2022-11-28',
  };
}

function settings(env) {
  const token = env.L5H_GITHUB_DISPATCH_TOKEN;
  const repo = env.L5H_GITHUB_REPOSITORY;
  const branch = env.L5H_GITHUB_BRANCH || 'main';
  if (!token || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo || '') ||
      !/^[A-Za-z0-9_./-]+$/.test(branch)) {
    throw new Error('Missing or invalid scheduler configuration');
  }
  return { token, repo, branch };
}

// Returns the NEXT_DUE epoch second recorded by the workflow, or 0 when it
// cannot be read. Any doubt means "dispatch": a skipped check is the only way
// this optimisation could cost a ping, so it must fail open.
export async function nextDue(env, request = fetch) {
  const { token, repo, branch } = settings(env);
  try {
    const response = await request(
      `${API}/repos/${repo}/contents/state/cloud-state.env?ref=${encodeURIComponent(branch)}`,
      { method: 'GET', redirect: 'error', headers: headers(token, 'application/vnd.github.raw+json'),
        signal: AbortSignal.timeout(10000) });
    if (response.status !== 200) return 0;
    const text = String(await response.text()).slice(0, 4096);
    const match = /^NEXT_DUE=(\d{1,12})\s*$/m.exec(text);
    return match ? Number(match[1]) : 0;
  } catch {
    return 0;
  }
}

export async function dispatch(env, request = fetch) {
  const { token, repo, branch } = settings(env);
  let response;
  try {
    response = await request(`${API}/repos/${repo}/actions/workflows/keepalive.yml/dispatches`, {
      method: 'POST',
      redirect: 'error',
      headers: { ...headers(token), 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: branch }),
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    // Never log request objects, headers or upstream exception details.
    throw new Error('GitHub dispatch network failure or timeout');
  }
  if (response.status !== 204) {
    throw new Error(`GitHub dispatch failed (HTTP ${response.status})`);
  }
}

export async function run(env, request = fetch, now = Date.now()) {
  const due = await nextDue(env, request);
  // A two-minute margin absorbs clock skew between Netlify and the runner.
  if (due > 0 && now / 1000 < due - 120) {
    return { dispatched: false, due };
  }
  await dispatch(env, request);
  return { dispatched: true, due };
}

export default async function () {
  // Fail loudly in Netlify logs. Acceptance does not prove a ping or new window.
  const result = await run(process.env);
  if (result.dispatched) {
    console.log('GitHub accepted keepalive dispatch; provider result is in Actions.');
  } else {
    console.log(`Nothing due before ${new Date(result.due * 1000).toISOString()}; no dispatch.`);
  }
  return new Response(null, { status: 204 });
}
