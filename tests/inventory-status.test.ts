import assert from 'node:assert/strict';
import test from 'node:test';
import { getInventoryStatus } from '../src/inventory/status.ts';

test('inventory above par is healthy', () => assert.equal(getInventoryStatus(11, 10), 'healthy'));
test('inventory at or below par is low', () => assert.equal(getInventoryStatus(8, 10), 'low'));
test('inventory at half par or lower is critical', () => assert.equal(getInventoryStatus(5, 10), 'critical'));
test('inventory without a par level is healthy', () => assert.equal(getInventoryStatus(0, null), 'healthy'));
test('archived inventory reports inactive', () => assert.equal(getInventoryStatus(20, 10, false), 'inactive'));
