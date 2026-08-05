export async function rollbackUploadedInvoice(
  storagePath: string,
  originalError: unknown,
  remove: (path: string) => Promise<void>,
): Promise<never> {
  const message = originalError instanceof Error ? originalError.message : 'Upload failed. Try again.';
  try {
    await remove(storagePath);
  } catch (cleanupError) {
    const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : 'unknown cleanup error';
    throw new Error(`${message} Uploaded file cleanup also failed: ${cleanupMessage}`);
  }
  throw originalError instanceof Error ? originalError : new Error(message);
}
