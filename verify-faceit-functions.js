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
  const isSilent = process.argv.includes('--silent');

  if (mode === 'offline') {
    const filename = process.argv[3];
    if (!filename) return console.error('❌ Provide filename e.g. matchFinished.json');
    const playerId = process.argv[5];
    runOffline(filename, playerId, isSilent);
  } else if (mode === 'real') {
    const matchId = process.argv[3];
    const playerId = process.argv[5];
    let apiKey = process.argv.find(a => a.startsWith('--api-key='))?.split('=')[1] || process.env.FACEIT_CLIENT_API_KEY;
    if (!matchId || !apiKey) {
      return console.error('Usage: node verify-faceit-functions.js real <matchId> --api-key=YOUR_KEY <playerId>');
    }
    await runReal(matchId, playerId, apiKey, isSilent);
  } else if (!isSilent) {
    console.log('Commands:');
    console.log('  offline <filename>');
    console.log('  real <matchId> --api-key=xxx <playerId>');
  }
}

function runOffline(filename, playerId, isSilent) {
  if (!isSilent) console.log(`\n📁 OFFLINE MODE → ${filename}`);
  const raw = JSON.parse(fs.readFileSync(path.join(EXAMPLES_DIR, filename), 'utf8'));
  
  if (playerId) {
    if (!isSilent) console.log('\nROSTER string:');
    process.stdout.write(processRoster(raw, playerId));
  }
  else {
    if (!isSilent) {
      console.log("\nNo player id provided so I'm skipping processRoster");
      console.log('\nSTATUS string:');
    }
    process.stdout.write(processStatus(raw));
  }
}

function processStatus(data) {
  const status = data.status || "UNKNOWN";
  let winner = "unknown";
  if (status === "FINISHED" && data.results?.winner) winner = data.results.winner;
  return JSON.stringify({ status, winner });
}

function processRoster(data, playerId) {
  const f1Roster = (data.teams?.faction1?.roster || []).map(p => p.player_id);
  const f2Roster = (data.teams?.faction2?.roster || []).map(p => p.player_id);

  let faction = 0;
  if (f1Roster.includes(playerId)) faction = 1;
  else if (f2Roster.includes(playerId)) faction = 2;

  return JSON.stringify({ faction });
}

async function runReal(matchId, playerId, apiKey, isSilent) {
  if (!isSilent) console.log(`\n🔴 LIVE MODE → matchId ${matchId}`);
  const statusSource = fs.readFileSync(STATUS_JS_PATH, 'utf8');
  const rosterSource = fs.readFileSync(ROSTER_JS_PATH, 'utf8');
  const secrets = { apiKey };

  if (playerId) {
    if (!isSilent) console.log('\n▶️  getRoster.js');
    const verifyRes = await simulateScript({ source: rosterSource, args: [matchId, playerId], secrets });
    if (isSilent) process.stdout.write(convertResponseObjectToString(verifyRes));
    logResult('ROSTER', verifyRes, isSilent);
  }
  else {
    if (!isSilent) console.log('\n▶️  getStatus.js');
    const statusRes = await simulateScript({ source: statusSource, args: [matchId], secrets });
    if (isSilent) process.stdout.write(convertResponseObjectToString(statusRes));
    logResult('STATUS', statusRes, isSilent);
  }
}

function logResult(type, result, isSilent) {
  if (isSilent) return;

  console.log(`\n=== ${type} Result ===`);
  if (result.capturedTerminalOutput) console.log(result.capturedTerminalOutput);

  if (result.errorString || result.error) {
    console.error('❌ Error:', result.errorString || result.error);
    return;
  }

  str = convertResponseObjectToString(result);
  console.log(`✅ Response (${str.length} bytes / max 256):`);
  console.log(str);
  if (str.length > 256) console.error('⚠️  EXCEEDS CHAINLINK FUNCTIONS LIMIT!');
  else console.log('✅ Under limit - good for DON');
}

function convertResponseObjectToString(result) {
  const hex = result.responseBytesHexstring || result.response;
  if (!hex) return console.error('No response');

  const bytes = Buffer.from(hex.startsWith('0x') ? hex.slice(2) : hex, 'hex');
  const str = new TextDecoder().decode(bytes);
  return str;
}

main().catch(console.error);