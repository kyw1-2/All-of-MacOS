#!/usr/bin/env node
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const root = path.join(__dirname,'../Extensions/Ulanzi/com.ulanzi.aom.ulanziPlugin');
const manifest = JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));
assert.strictEqual(manifest.UUID,'com.ulanzi.ulanzistudio.aom');
assert.strictEqual(manifest.Actions.length,19);
assert.strictEqual(new Set(manifest.Actions.map(x=>x.UUID)).size,19);
for (const a of manifest.Actions) {
  assert(fs.existsSync(path.join(root,a.Icon)));
  assert(['Keypad','Encoder'].some(x=>a.Controllers.includes(x)));
}
const html = fs.readFileSync(path.join(root,'plugin/app.html'),'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const callbacks = {};
const visited = [];
const ud = {
  connect: uuid => { assert.equal(uuid,manifest.UUID); },
  onRun: fn => {callbacks.run=fn;},
  onDialDown: fn => {callbacks.press=fn;},
  onDialRotate: fn => {callbacks.rotate=fn;},
  decodeContext: context => ({actionid:context}),
  openUrl: url => {visited.push(url);}
};
vm.runInNewContext(script, {$UD:ud, encodeURIComponent});
const key = n => 'com.ulanzi.ulanzistudio.aom.key'+String(n).padStart(2,'0');
const dial = n => 'com.ulanzi.ulanzistudio.aom.dial'+String(n).padStart(2,'0');
callbacks.run({context:key(1)});
callbacks.run({context:key(16)});
callbacks.press({context:dial(2)});
callbacks.rotate({context:dial(3),rotateEvent:'right'});
callbacks.rotate({context:dial(1),rotateEvent:'left'});
callbacks.run({context:'com.ulanzi.ulanzistudio.aom.key99'});
callbacks.run({context:'evil://trigger'});
callbacks.rotate({context:dial(1),rotateEvent:'unknown'});
assert.deepStrictEqual(visited,[
  'aom://trigger?name=ulanzi-key-01',
  'aom://trigger?name=ulanzi-key-16',
  'aom://trigger?name=ulanzi-dial-02-press',
  'aom://trigger?name=ulanzi-dial-03-right',
  'aom://trigger?name=ulanzi-dial-01-left'
]);
console.log('Ulanzi bridge integration tests passed: 19 action IDs, 5 routes, invalid contexts rejected');
