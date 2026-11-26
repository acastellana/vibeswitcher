// A session's dev servers in the inspector (js/devports.js, the node's session.ports).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { portRow, onTheNode } from '../js/devports.js';

const entry = { port: 5173, address: '127.0.0.1', pid: 4711, program: 'node', url: 'http://localhost:5173/' };

test('on the node’s own machine a port opens as http://localhost:PORT/', () => {
  // The program by its name, its process id on hover only (D18).
  assert.deepEqual(portRow(entry, '127.0.0.1'), { label: 'localhost:5173', about: 'node · this machine only', process: 'pid 4711', url: 'http://localhost:5173/' });
  assert.equal(portRow({ ...entry, address: '0.0.0.0' }, 'localhost').about, 'node · every address');
});

test('on the tailnet, or with an address that isn’t exactly the port’s, nothing opens', () => {
  assert.equal(portRow(entry, 'node.tail1234.ts.net').url, null);
  assert.equal(portRow({ ...entry, url: 'http://evil.example/' }, '127.0.0.1').url, null);
  assert.equal(portRow({ ...entry, port: 80 }, '127.0.0.1'), null);
  assert.equal(portRow({ ...entry, port: '5173; x' }, '127.0.0.1'), null);
  assert.ok(onTheNode('127.0.0.1') && !onTheNode('100.64.0.1'));
});
