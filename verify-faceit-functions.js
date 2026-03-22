// verify-faceit-functions.js — v3 with size reporting
const fs = require('fs');
const path = require('path');
const { simulateScript } = require('@chainlink/functions-toolkit');
const { TextDecoder } = require('util');

const STATUS_JS_PATH = path.join(__dirname, 'script/functions/getStatus.js');
const ROSTER_JS_PATH = path.join(__dirname, 'script/functions/getRoster.js');
const EXAMPLES_DIR = path.join(__dirname, 'test/faceitApiResponseBodyExamples');

async function main() {
  const mode = process.argv[2]?.toLowerCase();

  if (mode === 'offline') {
    const filename = process.argv[3];
    if (!filename) return console.error('❌ Provide filename e.g. matchFinished.json');
    const playerId = process.argv[4];
    runOffline(filename, playerId);
  } else if (mode === 'real') {
    const matchId = process.argv[3];
    const playerId = process.argv[4];
    let apiKey = process.argv.find(a => a.startsWith('--api-key='))?.split('=')[1] || process.env.FACEIT_API_KEY;
    if (!matchId || !playerId || !apiKey) {
      return console.error('Usage: node verify-faceit-functions.js real <matchId> --api-key=YOUR_KEY');
    }
    await runReal(matchId, playerId, apiKey);
  } else {
    console.log('Commands:');
    console.log('  offline <filename>');
    console.log('  real <matchId> --api-key=xxx');
  }
}

function runOffline(filename, playerId) {
  console.log(`\n📁 OFFLINE MODE → ${filename}`);
  const raw = JSON.parse(fs.readFileSync(path.join(EXAMPLES_DIR, filename), 'utf8'));
  console.log('\nSTATUS string:');
  console.log(processStatus(raw));

  if (playerId) {
    console.log('\nROSTER string:');
    console.log(processRoster(raw, playerId));
  }
  else {
    console.log("\nNo player id provided so I'm skipping processRoster");
  }
}

function processStatus(data) {
  const status = data.status || "UNKNOWN";
  let winner = "unknown";
  if (status === "FINISHED" && data.results?.winner) winner = data.results.winner;
  return JSON.stringify({ type: "status", status, winner });
}

function processRoster(data, playerId) {
  const status = data.status || "UNKNOWN";
  const f1Roster = (data.teams?.faction1?.roster || []).map(p => p.player_id);
  const f2Roster = (data.teams?.faction2?.roster || []).map(p => p.player_id);

  let faction = 0;
  if (f1Roster.includes(playerId)) faction = 1;
  else if (f2Roster.includes(playerId)) faction = 2;

  return JSON.stringify({ type: "roster", playerId, faction, valid: faction > 0, status });
}

async function runReal(matchId, playerId, apiKey) {
  console.log(`\n🔴 LIVE MODE → matchId ${matchId}`);
  const statusSource = fs.readFileSync(STATUS_JS_PATH, 'utf8');
  const rosterSource = fs.readFileSync(ROSTER_JS_PATH, 'utf8');
  const secrets = { apiKey };

  console.log('\n▶️  getStatus.js');
  const statusRes = await simulateScript({ source: statusSource, args: [matchId], secrets });
  logResult('STATUS', statusRes);

  console.log('\n▶️  getRoster.js');
  const verifyRes = await simulateScript({ source: rosterSource, args: [matchId, playerId], secrets });
  logResult('ROSTER', verifyRes);
}

function logResult(type, result) {
  console.log(`\n=== ${type} Result ===`);
  if (result.capturedTerminalOutput) console.log(result.capturedTerminalOutput);

  if (result.errorString || result.error) {
    console.error('❌ Error:', result.errorString || result.error);
    return;
  }

  const hex = result.responseBytesHexstring || result.response;
  if (!hex) return console.error('No response');

  const bytes = Buffer.from(hex.startsWith('0x') ? hex.slice(2) : hex, 'hex');
  const str = new TextDecoder().decode(bytes);
  console.log(`✅ Response (${str.length} bytes / max 256):`);
  console.log(str);
  if (str.length > 256) console.error('⚠️  EXCEEDS CHAINLINK FUNCTIONS LIMIT!');
  else console.log('✅ Under limit - good for DON');
}

main().catch(console.error);