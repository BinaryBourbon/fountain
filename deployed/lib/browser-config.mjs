import { ensure } from './execution.mjs';

const variable = /^[A-Z][A-Z0-9_]*$/;
export function validateBrowser(config, env) {
  const b = config.browser;
  ensure(config.profiles.length === 1 && !config.execution && !config.fixture, 'Run the browser console profile independently');
  ensure(b && Object.keys(b).every(k => ['email', 'password', 'agent', 'credential_provider', 'step_ms', 'conversations'].includes(k)), 'Expected explicit browser configuration');
  for (const name of ['email', 'password']) {
    ensure(variable.test(b[name]) && typeof env[b[name]] === 'string' && env[b[name]].length > 0, `Browser ${name} must name a populated environment variable`);
  }
  ensure(!env.DEBUG && !env.PWDEBUG && !env.PW_TRACE, 'Disable browser debug/native trace environment variables before entering credentials');
  const a = b.agent;
  ensure(a && Object.keys(a).every(k => ['runtime', 'model', 'sandbox_provider'].includes(k)) &&
    ['claude', 'codex', 'gemini', 'opencode'].includes(a.runtime) &&
    typeof a.model === 'string' && /^[a-z0-9_-]+\/[a-z0-9._-]+$/.test(a.model) &&
    ['sprites', 'e2b', 'daytona', 'runner'].includes(a.sandbox_provider), 'Pin the browser agent runtime, model and sandbox provider');
  ensure(['anthropic_api_key', 'claude_code_oauth_token', 'openai_api_key', 'gemini_api_key'].includes(b.credential_provider), 'Select a credential setup provider');
  b.step_ms ??= 30000;
  ensure(Number.isSafeInteger(b.step_ms) && b.step_ms >= 1000 && b.step_ms <= 60000, 'Browser step_ms must be 1000-60000');
  ensure(b.conversations === null, 'This console profile requires conversations:null; app handoff coverage is not implemented yet');
  ensure(config.limits.run_ms <= 600000 && config.limits.resources >= 2, 'Browser console requires a ten-minute bound and two-resource budget');
}
