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