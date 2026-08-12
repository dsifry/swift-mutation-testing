import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const REPOSITORY = 'dsifry/swift-mutation-testing';
const ENVIRONMENT = 'release-production';
const RULESET = 'immutable-release-tags';

function fail(message) {
  throw new Error(`repository controls: ${message}`);
}

function exactEnvironment(value, maintainer) {
  if (!value || value.name !== ENVIRONMENT || !Array.isArray(value.protection_rules) || value.protection_rules.length !== 1) return false;
  const rule = value.protection_rules[0];
  if (rule?.type !== 'required_reviewers' || rule.prevent_self_review !== true || !Array.isArray(rule.reviewers) || rule.reviewers.length !== 1) return false;
  const reviewer = rule.reviewers[0];
  return reviewer?.type === 'User' && typeof reviewer.reviewer?.login === 'string' && (!maintainer || reviewer.reviewer.login === maintainer);
}

function exactRuleset(value) {
  if (!value || value.name !== RULESET || value.target !== 'tag' || value.enforcement !== 'active') return false;
  if (!Array.isArray(value.bypass_actors) || value.bypass_actors.length !== 0) return false;
  const refName = value.conditions?.ref_name;
  if (!refName || !Array.isArray(refName.include) || refName.include.length !== 1 || refName.include[0] !== 'refs/tags/v*' || !Array.isArray(refName.exclude) || refName.exclude.length !== 0) return false;
  if (!Array.isArray(value.rules) || value.rules.length !== 2) return false;
  return value.rules.some(({ type }) => type === 'update') && value.rules.some(({ type }) => type === 'deletion');
}

function environmentPayload(maintainer) {
  return { maintainer, requiredApprovals: 1, preventSelfReview: true };
}

function rulesetPayload() {
  return {
    name: RULESET,
    target: 'tag',
    enforcement: 'active',
    bypass_actors: [],
    conditions: { ref_name: { include: ['refs/tags/v*'], exclude: [] } },
    rules: [{ type: 'update' }, { type: 'deletion' }],
  };
}

async function observe(api, maintainer) {
  const environment = await api.getEnvironment();
  const summaries = await api.listRulesets();
  if (!Array.isArray(summaries)) fail('ruleset listing is malformed');
  const matches = summaries.filter((item) => item?.name === RULESET);
  if (matches.length > 1) fail('exactly one immutable-release-tags ruleset is required');
  const ruleset = matches.length === 1 ? await api.getRuleset(matches[0].id) : null;
  const reviewerLogin = environment?.protection_rules?.[0]?.reviewers?.[0]?.reviewer?.login ?? maintainer;
  const permission = reviewerLogin ? await api.getRepositoryPermission(reviewerLogin) : null;
  const reviewerAuthorized = permission === 'maintain' || permission === 'admin';
  return { environment, ruleset, reviewerAuthorized, environmentExact: exactEnvironment(environment, maintainer) && reviewerAuthorized, rulesetExact: exactRuleset(ruleset) };
}

export async function configureReleaseControls({ repository, mode = 'check', maintainer, api }) {
  if (repository !== REPOSITORY) fail(`repository must equal ${REPOSITORY}`);
  if (mode !== 'check' && mode !== 'apply') fail('mode must be check or apply');
  if (!api) fail('GitHub adapter is required');
  if (typeof api.getRepositoryPermission !== 'function') fail('GitHub adapter must verify maintainer authority');
  if (mode === 'apply' && (typeof maintainer !== 'string' || maintainer.length === 0)) fail('apply requires an authenticated maintainer login');
  if (mode === 'apply') {
    const requestedPermission = await api.getRepositoryPermission(maintainer);
    if (requestedPermission !== 'maintain' && requestedPermission !== 'admin') fail('requested approval reviewer lacks maintainer/admin authority');
  }

  const before = await observe(api, mode === 'apply' ? maintainer : undefined);
  if (before.environment && before.reviewerAuthorized === false && before.environment.protection_rules?.[0]?.reviewers?.[0]?.reviewer?.login) fail('configured approval reviewer lacks maintainer/admin authority');
  if (mode === 'check') {
    if (!before.environmentExact || !before.rulesetExact) fail('required environment or ruleset is missing or weaker than policy');
    return { repository, environment: 'exact', ruleset: 'exact', changed: false };
  }

  let changed = false;
  if (!before.environmentExact) {
    await api.putEnvironment(environmentPayload(maintainer));
    changed = true;
  }
  if (!before.rulesetExact) {
    const payload = rulesetPayload();
    if (before.ruleset) await api.updateRuleset(before.ruleset.id, payload);
    else await api.createRuleset(payload);
    changed = true;
  }

  const after = await observe(api, maintainer);
  if (!after.environmentExact || !after.rulesetExact) fail('post-apply reread is missing or weaker than policy');
  return { repository, environment: 'exact', ruleset: 'exact', changed };
}

async function ghJSON(method, route, body, runCommand = execFile) {
  const argv = ['api', '--method', method, route];
  if (body !== undefined) argv.push('--input', '-');
  const { stdout } = await runCommand('gh', argv, { encoding: 'utf8', input: body === undefined ? undefined : `${JSON.stringify(body)}\n` });
  return stdout.trim() === '' ? null : JSON.parse(stdout);
}

export function createNativeGitHubAdapter(repository, maintainer, { runCommand = execFile } = {}) {
  const environmentRoute = `repos/${repository}/environments/${ENVIRONMENT}`;
  return {
    async getEnvironment() {
      try { return await ghJSON('GET', environmentRoute, undefined, runCommand); } catch (error) { if (error?.code === 1) return null; throw error; }
    },
    async listRulesets() { return ghJSON('GET', `repos/${repository}/rulesets`, undefined, runCommand); },
    async getRuleset(id) { return ghJSON('GET', `repos/${repository}/rulesets/${id}`, undefined, runCommand); },
    async getRepositoryPermission(login) {
      const value = await ghJSON('GET', `repos/${repository}/collaborators/${login}/permission`, undefined, runCommand);
      return value?.permission;
    },
    async putEnvironment(payload) {
      const user = await ghJSON('GET', `users/${payload.maintainer}`, undefined, runCommand);
      if (!Number.isSafeInteger(user?.id) || user.id <= 0) fail('maintainer identity is not observable');
      return ghJSON('PUT', environmentRoute, {
        wait_timer: 0,
        prevent_self_review: true,
        reviewers: [{ type: 'User', id: user.id }],
        deployment_branch_policy: null,
      }, runCommand);
    },
    async createRuleset(payload) { return ghJSON('POST', `repos/${repository}/rulesets`, payload, runCommand); },
    async updateRuleset(id, payload) { return ghJSON('PUT', `repos/${repository}/rulesets/${id}`, payload, runCommand); },
  };
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--check' || argument === '--apply') {
      if (values.mode) fail('choose exactly one of --check or --apply');
      values.mode = argument.slice(2);
    } else if (argument === '--repository' || argument === '--maintainer') {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) fail(`missing value for ${argument}`);
      values[argument.slice(2)] = value;
      index += 1;
    } else fail(`unknown argument ${argument}`);
  }
  if (!values.repository) fail('usage: configure-release-controls.mjs --repository OWNER/REPO [--check | --apply --maintainer LOGIN]');
  return { ...values, mode: values.mode ?? 'check' };
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const input = parseArguments(argv);
  const api = dependencies.api ?? (dependencies.createNativeGitHubAdapter ?? createNativeGitHubAdapter)(input.repository, input.maintainer);
  const result = await configureReleaseControls({ ...input, api });
  (dependencies.stdout ?? ((value) => process.stdout.write(value)))(`${JSON.stringify(result)}\n`);
  return result;
}

export async function runMain(argv = process.argv.slice(2), dependencies = {}) {
  try {
    await runCli(argv, dependencies);
    return 0;
  } catch (error) {
    (dependencies.stderr ?? ((value) => process.stderr.write(value)))(`${error.message}\n`);
    return 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exitCode = await runMain();
}
