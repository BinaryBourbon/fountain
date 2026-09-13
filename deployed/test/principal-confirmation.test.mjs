import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

// Exercise the hook shipped in the console layout, not a test copy of it.
const layout = readFileSync(new URL('../../apps/fountain/lib/fountain_web/components/layouts/root.html.heex', import.meta.url), 'utf8');
const hooks = layout.match(/const Hooks = (\{[\s\S]*?\n        \});/);
assert.ok(hooks, 'console layout must register its LiveView hooks');

function mountConfirmation(answer) {
  const prompts = [];
  const { ConfirmSubmit } = runInNewContext(`(${hooks[1]})`, {
    window: { confirm(message) {
      prompts.push(message);
      if (answer instanceof Error) throw answer;
      return answer;
    } }
  });
  const form = new EventTarget();
  form.dataset = { confirm: "Replace this principal's key? Its current key will stop working." };
  const hook = { el: form };
  ConfirmSubmit.mounted.call(hook);
  return { form, prompts, destroy: () => ConfirmSubmit.destroyed.call(hook) };
}

test('cancelling principal replacement stops submission before LiveView receives it', () => {
  const { form, prompts } = mountConfirmation(false);
  let submissions = 0;
  form.addEventListener('submit', () => { submissions++; });
  const event = new Event('submit', { cancelable: true });

  assert.equal(form.dispatchEvent(event), false);
  assert.equal(event.defaultPrevented, true);
  assert.equal(submissions, 0);
  assert.deepEqual(prompts, [form.dataset.confirm]);
});

test('accepting principal replacement permits the original submission exactly once', () => {
  const { form, prompts } = mountConfirmation(true);
  let submissions = 0;
  form.addEventListener('submit', () => { submissions++; });

  assert.equal(form.dispatchEvent(new Event('submit', { cancelable: true })), true);
  assert.equal(submissions, 1);
  assert.deepEqual(prompts, [form.dataset.confirm]);
});

test('a failed confirmation dialog leaves the current key unchanged', () => {
  const { form } = mountConfirmation(new Error('dialog unavailable'));
  let submissions = 0;
  form.addEventListener('submit', () => { submissions++; });

  assert.equal(form.dispatchEvent(new Event('submit', { cancelable: true })), false);
  assert.equal(submissions, 0);
});

test('picker interactions do not prompt and destroying the hook removes its listener', () => {
  const { form, prompts, destroy } = mountConfirmation(false);
  for (const type of ['click', 'input', 'change']) form.dispatchEvent(new Event(type));
  assert.deepEqual(prompts, []);

  destroy();
  assert.equal(form.dispatchEvent(new Event('submit', { cancelable: true })), true);
  assert.deepEqual(prompts, []);
});
