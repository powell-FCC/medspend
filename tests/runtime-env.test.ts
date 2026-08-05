import assert from 'node:assert/strict';
import test from 'node:test';
import { getRuntimeEnv } from '../src/lib/runtime-env.server.ts';

test('Cloudflare request-time binding takes precedence over process.env', () => {
  const name = 'MEDSPEND_RUNTIME_ENV_TEST';
  const previous = process.env[name];
  process.env[name] = 'local-value';

  try {
    const request = new Request('https://example.test') as Request & {
      runtime: { cloudflare: { env: Record<string, unknown> } };
    };
    request.runtime = { cloudflare: { env: { [name]: 'binding-value' } } };

    assert.equal(getRuntimeEnv(request, name), 'binding-value');
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
});

test('process.env remains the local development fallback', () => {
  const name = 'MEDSPEND_RUNTIME_ENV_TEST';
  const previous = process.env[name];
  process.env[name] = 'local-value';

  try {
    assert.equal(getRuntimeEnv(new Request('http://localhost'), name), 'local-value');
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
});
