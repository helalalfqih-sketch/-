// Contract test with a fake transport; NOT evidence of a real provider response.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
for (const model of ['gpt-6-luna', 'gpt-6-luna-2026-09-22', 'another-model']) {
  let route, sent, saved;
  class TestRecord {
    constructor() { this.id = 'job-one'; }
    set(key, value) { this[key] = value; }
  }
  const app = {
    runInTransaction: callback => callback(app),
    findRecordsByFilter: () => [],
    findCollectionByNameOrId: () => ({}),
    findRecordById: () => new TestRecord(),
    save: record => { saved = record; },
  };
  vm.runInNewContext(fs.readFileSync(__dirname + '/pb_hooks/scc_ai.pb.js', 'utf8'), {
    routerAdd: (_, __, handler) => { route = handler; },
    $apis: { requireAuth: () => {} }, Record: TestRecord,
    $os: { getenv: key => ({SCC_AI_API_KEY: 'fake-key', SCC_AI_MODEL: model}[key] || '') },
    $http: { send: request => {
      sent = JSON.parse(request.body);
      return {statusCode: 200, json: {choices: [{message: {content: 'Controlled test output'}}]}};
    } },
  });
  const response = route({app, requestInfo: () => ({auth: {id: 'user-one'}, body: {prompt: 'hello'}}),
    json: (status, body) => ({status, body})});
  assert.equal(response.status, 200);
  assert.equal(saved.state, 'completed');
  assert.equal(sent.max_completion_tokens, 1000);
  assert.equal(sent.temperature, undefined);
  assert.equal(sent.max_tokens, undefined);
  assert.equal(sent.reasoning_effort, model.startsWith('gpt-6-luna') ? 'none' : undefined);
  assert.equal(response.body.text, 'Controlled test output');
}
console.log('PASS: AI request compatibility and persistence contract (fake transport only)');
