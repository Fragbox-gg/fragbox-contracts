const matchId = args[0];
const playerId = args[1];
const apiKey = secrets.apiKey;

if (!apiKey) throw Error("No API key provided");

const res = await Functions.makeHttpRequest({
  url: `https://open.faceit.com/data/v4/matches/${matchId}`,
  headers: {
    Accept: "application/json",
    Authorization: `Bearer ${apiKey}`
  }
});

if (res.error) throw Error(`Faceit API error: ${res.error}`);

const data = res.data || {};
const f1Roster = (data.teams?.faction1?.roster || []).map(p => p.player_id);
const f2Roster = (data.teams?.faction2?.roster || []).map(p => p.player_id);

let faction = 0;
if (f1Roster.includes(playerId)) faction = 1;
else if (f2Roster.includes(playerId)) faction = 2;

return Functions.encodeString(
  JSON.stringify({
    type: "roster",
    playerId,
    faction, // 1 = faction1, 2 = faction2, 0 = not found
    valid: faction > 0
  })
);