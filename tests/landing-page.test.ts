import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import ts from 'typescript';

// Use the existing Node runner to render real TSX modules, with navigation
// represented by anchors. Route registration still selects the actual component.
function loadModule(file: URL): any {
  const source = readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS } }).outputText;
  const require = createRequire(file);
  const exports = {};
  new Function('require', 'exports', compiled)((name: string) => {
    if (name.endsWith('.css')) return {};
    if (name === '@tanstack/react-router') return {
      createFileRoute: (path: string) => (options: unknown) => ({ path, options }),
      Link: ({ to, children, ...props }: any) => createElement('a', { ...props, href: to }, children),
    };
    if (name.startsWith('@/')) return loadModule(new URL(`../src/${name.slice(2)}.tsx`, import.meta.url));
    return require(name);
  }, exports);
  return exports;
}

test('root selects the internal beta with existing branding, imagery and sign-in links', () => {
  const { Route } = loadModule(new URL('../src/routes/index.tsx', import.meta.url));
  assert.equal(Route.path, '/');
  const html = renderToStaticMarkup(createElement(Route.options.component));
  for (const text of ['Internal Beta', 'Keep your team supplied.', 'FC Cincinnati staff', 'Built for sport. Driven by data.', '/brand/sportspend-logo-horizontal.png', '/brand/sportspend-stadium-hero.png']) assert.ok(html.includes(text), text);
  assert.equal((html.match(/href="\/auth"/g) ?? []).length, 2);
  assert.equal((html.match(/>Sign in<\/a>/g) ?? []).length, 2);
  assert.doesNotMatch(html, /Pricing|Solutions|Resources|Get started|Watch overview|trial|subscription|customer|demo|SportSpend capabilities|id="product"/i);
  assert.deepEqual(Route.options.head().meta[0], { title: 'SportSpend — Internal Beta' });
});

test('commercial component remains renderable with its original commercial sections and metadata', () => {
  const { CommercialLanding, commercialLandingHead } = loadModule(new URL('../src/components/landing/CommercialLanding.tsx', import.meta.url));
  const html = renderToStaticMarkup(createElement(CommercialLanding));
  for (const text of ['Pricing', 'Solutions', 'Resources', 'Get started', 'Watch overview', 'Make smarter decisions.', 'id="solutions"', 'id="product"']) assert.ok(html.includes(text), text);
  assert.deepEqual(commercialLandingHead().meta[0], { title: 'SportSpend — Supply requests and purchasing insights' });
});
