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
  const statusStr = data.status || "UNKNOWN";

  let statusCode = 0;
  if (statusStr === "VOTING") statusCode = 1;
  else if (statusStr === "READY") statusCode = 2;
  else if (statusStr === "ONGOING") statusCode = 3;
  else if (statusStr === "FINISHED") statusCode = 4;

  let winnerCode = 0; // 0 = unknown, 1 = faction1, 2 = faction2, 3 = draw
  if (statusCode === 4 && data.results?.winner) {
    let winner = data.results.winner;
    if (winner === "faction1") winnerCode = 1;
    else if (winner === "faction2") winnerCode = 2;
    else if (winner === "draw") winnerCode = 3;
  }
  return new Uint8Array([statusCode, winnerCode]);
}

function processRoster(data, playerId) {
  const f1Roster = (data.teams?.faction1?.roster || []).map(p => p.player_id);
  const f2Roster = (data.teams?.faction2?.roster || []).map(p => p.player_id);

  let faction = 0;
  if (f1Roster.includes(playerId)) faction = 1;
  else if (f2Roster.includes(playerId)) faction = 2;

  return new Uint8Array([faction]);
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

function convertResponseObjectToString(result) {
  // Handle the two possible return formats from simulateScript
  let bytes;
  if (result.responseBytesHexstring) {
    // Newer toolkit format (hex string)
    const hex = result.responseBytesHexstring.startsWith('0x')
      ? result.responseBytesHexstring.slice(2)
      : result.responseBytesHexstring;
    bytes = Buffer.from(hex, 'hex');
  } else if (result.response) {
    // Raw Uint8Array (what your script returns)
    bytes = Buffer.from(result.response);
  } else {
    return '❌ No response data';
  }

  // === SPECIAL HANDLING FOR YOUR FUNCTIONS ===
  // getRoster → 1 byte (faction)
  if (bytes.length === 1) {
    const faction = bytes[0];
    return `${faction}`;
    // return `Faction: ${faction} (0=not found, 1=faction1, 2=faction2)`;
  }

  // getStatus → 2 bytes (statusCode, winnerCode)
  if (bytes.length === 2) {
    const statusCode = bytes[0];
    const winnerCode = bytes[1];
    return `${statusCode},${winnerCode}`;
    // const statusMap = { 0: 'UNKNOWN', 1: 'VOTING', 2: 'READY', 3: 'ONGOING', 4: 'FINISHED' };
    // const winnerMap = { 0: 'unknown', 1: 'faction1', 2: 'faction2', 3: 'draw' };
    // return `Status: ${statusMap[statusCode] || statusCode} | Winner: ${winnerMap[winnerCode] || winnerCode}`;
  }

  // Fallback: show as hex (for any future functions)
  return `0x${bytes.toString('hex')}`;
}

function logResult(type, result, isSilent) {
  if (isSilent) return;

  console.log(`\n=== ${type} Result ===`);
  if (result.capturedTerminalOutput) console.log(result.capturedTerminalOutput);

  if (result.errorString || result.error) {
    console.error('❌ Error:', result.errorString || result.error);
    return;
  }

  const displayStr = convertResponseObjectToString(result);
  console.log(`✅ Response (${result.response?.length || 0} bytes / max 256):`);
  console.log(displayStr);   // ← now human-readable
  if ((result.response?.length || 0) > 256) {
    console.error('⚠️  EXCEEDS CHAINLINK FUNCTIONS LIMIT!');
  } else {
    console.log('✅ Under limit - good for DON');
  }
}

main().catch(console.error);