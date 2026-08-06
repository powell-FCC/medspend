import assert from 'node:assert/strict';
import test from 'node:test';
import { getRuntimeEnv, isMockInvoiceExtractionEnabled } from '../src/lib/runtime-env.server.ts';

test('Cloudflare request-time binding takes precedence over process.env', () => {
  const name = 'MEDSPEND_RUNTIME_ENV_TEST';
  const previous = process.env[name];
  process.env[name] = 'local-value';

  try {
    const request = new Request('https://example.test') as Request & {
      runtime: { cloudflare: { env: Record<string, unknown> } };
    };
    request.runtime = { cloudflare: { env: { [name]: 'binding-value' } } };

    assert.equal(getRuntimeEnv(request, name, {}), 'binding-value');
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
    assert.equal(getRuntimeEnv(new Request('http://localhost'), name, {}), 'local-value');
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
});

test('the two public Supabase settings fall back to their build-time Vite values', () => {
  const previousUrl = process.env.SUPABASE_URL;
  const previousKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_PUBLISHABLE_KEY;

  try {
    const buildTimeEnv = {
      VITE_SUPABASE_URL: 'https://build-time.example.test',
      VITE_SUPABASE_PUBLISHABLE_KEY: 'build-time-publishable-key',
    };

    assert.equal(
      getRuntimeEnv(undefined, 'SUPABASE_URL', buildTimeEnv),
      'https://build-time.example.test',
    );
    assert.equal(
      getRuntimeEnv(undefined, 'SUPABASE_PUBLISHABLE_KEY', buildTimeEnv),
      'build-time-publishable-key',
    );
  } finally {
    if (previousUrl === undefined) delete process.env.SUPABASE_URL;
    else process.env.SUPABASE_URL = previousUrl;
    if (previousKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousKey;
  }
});

test('unrelated names never read arbitrary Vite variables', () => {
  const name = 'UNRELATED_SERVER_SETTING';
  const previous = process.env[name];
  delete process.env[name];

  try {
    assert.equal(
      getRuntimeEnv(undefined, name, {
        VITE_SUPABASE_URL: 'must-not-be-used',
        VITE_UNRELATED_SERVER_SETTING: 'must-not-be-used',
      } as { VITE_SUPABASE_URL: string }),
      undefined,
    );
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
});

test('mock invoice extraction is server-only and defaults to disabled', () => {
  const previous = process.env.ENABLE_MOCK_INVOICE_EXTRACTION;
  delete process.env.ENABLE_MOCK_INVOICE_EXTRACTION;
  try {
    assert.equal(isMockInvoiceExtractionEnabled(), false);
    assert.equal(getRuntimeEnv(undefined, 'ENABLE_MOCK_INVOICE_EXTRACTION', {
      VITE_ENABLE_MOCK_INVOICE_EXTRACTION: 'true',
    } as never), undefined);
    assert.equal(isMockInvoiceExtractionEnabled(), false);
  } finally {
    if (previous === undefined) delete process.env.ENABLE_MOCK_INVOICE_EXTRACTION;
    else process.env.ENABLE_MOCK_INVOICE_EXTRACTION = previous;
  }
});

test('mock invoice extraction requires the exact explicit server value true', () => {
  const previous = process.env.ENABLE_MOCK_INVOICE_EXTRACTION;
  try {
    process.env.ENABLE_MOCK_INVOICE_EXTRACTION = 'false';
    assert.equal(isMockInvoiceExtractionEnabled(), false);
    process.env.ENABLE_MOCK_INVOICE_EXTRACTION = 'TRUE';
    assert.equal(isMockInvoiceExtractionEnabled(), false);
    process.env.ENABLE_MOCK_INVOICE_EXTRACTION = 'true';
    assert.equal(isMockInvoiceExtractionEnabled(), true);
  } finally {
    if (previous === undefined) delete process.env.ENABLE_MOCK_INVOICE_EXTRACTION;
    else process.env.ENABLE_MOCK_INVOICE_EXTRACTION = previous;
  }
});

test('production runtime cannot enable mock invoice extraction even when flagged', () => {
  const request = new Request('https://medspend.example') as Request & {
    runtime: { cloudflare: { env: Record<string, unknown> } };
  };
  request.runtime = { cloudflare: { env: {
    NODE_ENV: 'production',
    ENABLE_MOCK_INVOICE_EXTRACTION: 'true',
  } } };
  assert.equal(isMockInvoiceExtractionEnabled(request), false);
});
