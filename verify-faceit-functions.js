// verify-faceit-functions.js
// Run with: node verify-faceit-functions.js

const fs = require('fs');
const path = require('path');
const { simulateScript } = require('@chainlink/functions-toolkit');
const { TextDecoder } = require('util');

const STATUS_JS_PATH = path.join(__dirname, 'script/functions/getStatus.js');
const ROSTER_JS_PATH = path.join(__dirname, 'script/functions/getRoster.js');
const EXAMPLES_DIR = path.join(__dirname, 'test/faceitApiResponseBodyExamples');

console.log('✅ Loaded JS sources from disk:');
console.log('   •', STATUS_JS_PATH);
console.log('   •', ROSTER_JS_PATH);
console.log('\nUsage:');
console.log('  Live (real API):   node verify-faceit-functions.js real <matchId> --api-key=YOUR_KEY');
console.log('  Offline (your examples): node verify-faceit-functions.js offline <matchFinished.json|matchReady.json|matchOngoing.json|matchVoting.json>\n');

async function main() {
  const mode = process.argv[2]?.toLowerCase();

  if (mode === 'offline') {
    const filename = process.argv[3];
    if (!filename) {
      console.error('❌ Provide a filename, e.g. matchFinished.json');
      process.exit(1);
    }
    await runOffline(filename);
  } else if (mode === 'real') {
    const matchId = process.argv[3];
    const apiKey = process.argv.find(a => a.startsWith('--api-key='))?.split('=')[1];
    if (!matchId || !apiKey) {
      console.error('❌ Usage: node ... real <matchId> --api-key=YOUR_KEY');
      process.exit(1);
    }
    await runReal(matchId, apiKey);
  } else {
    console.log('Run with "real" or "offline" as shown above.');
  }
}

async function runOffline(filename) {
  console.log(`📁 OFFLINE MODE → ${filename}\n`);
  const filePath = path.join(EXAMPLES_DIR, filename);
  const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));

  console.log('STATUS processed string:');
  const statusStr = processStatus(raw);
  console.log(statusStr);

  console.log('\nROSTER processed string:');
  const rosterStr = processRoster(raw);
  console.log(rosterStr);

  console.log('\n✅ Copy these strings into your test constants (PROCESSED_STATUS_... / PROCESSED_ROSTER_...)');
}

function processStatus(data) {
  const status = data.status || "UNKNOWN";
  let winner = "unknown";
  if (status === "FINISHED" && data.results?.winner) winner = data.results.winner;
  return JSON.stringify({ type: "status", status, winner });
}

function processRoster(data) {
  let f1 = "", f2 = "";
  if (data.teams?.faction1?.roster) f1 = data.teams.faction1.roster.map(p => p.player_id).join(",");
  if (data.teams?.faction2?.roster) f2 = data.teams.faction2.roster.map(p => p.player_id).join(",");
  const status = data.status || "UNKNOWN";
  return JSON.stringify({ type: "roster", f1, f2, status });
}

async function runReal(matchId, apiKey) {
  console.log(`🔴 LIVE MODE → matchId ${matchId}\n`);
  const statusSource = fs.readFileSync(STATUS_JS_PATH, 'utf8');
  const rosterSource = fs.readFileSync(ROSTER_JS_PATH, 'utf8');
  const secrets = { apiKey };

  console.log('▶️ Simulating getStatus.js...');
  const statusRes = await simulateScript({ source: statusSource, args: [matchId], secrets });
  logResult('STATUS', statusRes);

  console.log('\n▶️ Simulating getRoster.js...');
  const rosterRes = await simulateScript({ source: rosterSource, args: [matchId], secrets });
  logResult('ROSTER', rosterRes);
}

function logResult(type, result) {
  if (result.error) return console.error('❌', result.error);
  const hex = result.responseBytesHexstring || result.response;
  const bytes = Buffer.from(hex.slice(2), 'hex');
  const str = new TextDecoder().decode(bytes);
  console.log('Raw response string (copy-paste to tests):');
  console.log(str);
}

main().catch(console.error);