type RequestWithCloudflareRuntime = Request & {
  runtime?: {
    cloudflare?: {
      env?: Record<string, unknown>;
    };
  };
};

export function getRuntimeEnv(
  request: Request | undefined,
  name: string,
): string | undefined {
  const cloudflareValue = (request as RequestWithCloudflareRuntime | undefined)
    ?.runtime?.cloudflare?.env?.[name];

  if (typeof cloudflareValue === 'string') {
    return cloudflareValue;
  }

  return typeof process !== 'undefined' ? process.env?.[name] : undefined;
}
