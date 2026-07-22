// transport.test.js — unit test for transport.js's pure wire-protocol fns.
// Run: node frontend/js/transport.test.js
const assert = require("node:assert/strict");
const { _encode, _decode } = require("./transport.js");

assert.equal(
  _encode({ op: "start", id: "t", cols: 80, rows: 24, cwd: null }),
  '{"op":"start","id":"t","cols":80,"rows":24,"cwd":null}'
);

assert.deepEqual(
  _decode('{"ev":"output","id":"t","data":"hi"}'),
  { ev: "output", id: "t", data: "hi" }
);

console.log("transport.test.js: PASS");
