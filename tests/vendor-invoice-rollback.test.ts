import assert from 'node:assert/strict';
import test from 'node:test';
import { rollbackUploadedInvoice } from '../src/storage/upload-rollback.ts';

test('metadata failure removes the uploaded Storage object', async () => {
  const removed: string[] = [];
  const failure = new Error('metadata insert failed');

  await assert.rejects(
    rollbackUploadedInvoice('organization/invoice.pdf', failure, async (path) => { removed.push(path); }),
    failure,
  );
  assert.deepEqual(removed, ['organization/invoice.pdf']);
});

test('cleanup failure preserves both error contexts', async () => {
  await assert.rejects(
    rollbackUploadedInvoice('organization/invoice.pdf', new Error('metadata insert failed'), async () => {
      throw new Error('storage delete failed');
    }),
    /metadata insert failed.*storage delete failed/,
  );
});
