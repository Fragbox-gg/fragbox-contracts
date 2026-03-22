const matchId = args[0];
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
let f1 = "";
let f2 = "";

if (data.teams?.faction1?.roster) {
  f1 = data.teams.faction1.roster.map(p => p.player_id).join(",");
}
if (data.teams?.faction2?.roster) {
  f2 = data.teams.faction2.roster.map(p => p.player_id).join(",");
}

const status = data.status || "UNKNOWN";

return Functions.encodeString(
  JSON.stringify({
    type: "roster",
    f1,
    f2,
    status
  })
);