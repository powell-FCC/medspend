type RequestWithCloudflareRuntime = Request & {
  runtime?: {
    cloudflare?: {
      env?: Record<string, unknown>;
    };
  };
};

type BuildTimeEnv = {
  VITE_SUPABASE_URL?: string;
  VITE_SUPABASE_PUBLISHABLE_KEY?: string;
};

function getBuildTimeSupabaseEnv(
  name: string,
  buildTimeEnv: BuildTimeEnv,
): string | undefined {
  if (name === 'SUPABASE_URL') {
    return buildTimeEnv.VITE_SUPABASE_URL;
  }

  if (name === 'SUPABASE_PUBLISHABLE_KEY') {
    return buildTimeEnv.VITE_SUPABASE_PUBLISHABLE_KEY;
  }

  return undefined;
}

export function getRuntimeEnv(
  request: Request | undefined,
  name: string,
  buildTimeEnv: BuildTimeEnv = import.meta.env as BuildTimeEnv,
): string | undefined {
  const cloudflareValue = (request as RequestWithCloudflareRuntime | undefined)
    ?.runtime?.cloudflare?.env?.[name];

  if (typeof cloudflareValue === 'string') {
    return cloudflareValue;
  }

  const processValue = typeof process !== 'undefined' ? process.env?.[name] : undefined;
  if (typeof processValue === 'string') {
    return processValue;
  }

  return getBuildTimeSupabaseEnv(name, buildTimeEnv);
}

export function isMockInvoiceExtractionEnabled(request?: Request): boolean {
  if (import.meta.env?.PROD || getRuntimeEnv(request, 'NODE_ENV') === 'production') return false;
  return getRuntimeEnv(request, 'ENABLE_MOCK_INVOICE_EXTRACTION') === 'true';
}
