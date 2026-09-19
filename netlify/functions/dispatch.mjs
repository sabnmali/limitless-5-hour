// Netlify invokes scheduled functions privately, only on published deployments.
// The token needs Actions: write for ONE repository, never account-wide access.
export const config = { schedule: '*/30 * * * *' };

export async function dispatch(env, request = fetch) {
  const token = env.L5H_GITHUB_DISPATCH_TOKEN;
  const repo = env.L5H_GITHUB_REPOSITORY;
  const branch = env.L5H_GITHUB_BRANCH || 'main';
  if (!token || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo || '') ||
      !/^[A-Za-z0-9_./-]+$/.test(branch)) {
    throw new Error('Missing or invalid scheduler configuration');
  }
  let response;
  try {
    response = await request(`https://api.github.com/repos/${repo}/actions/workflows/keepalive.yml/dispatches`, {
      method: 'POST',
      redirect: 'error',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'Content-Type': 'application/json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
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

export default async function () {
  // Fail loudly in Netlify logs. Acceptance does not prove a ping or new window.
  await dispatch(process.env);
  console.log('GitHub accepted keepalive dispatch; provider result is in Actions.');
  return new Response(null, { status: 204 });
}
