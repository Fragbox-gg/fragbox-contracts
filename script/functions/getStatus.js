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
const status = data.status || "UNKNOWN";

let winner = "unknown";
if (status === "FINISHED" && data.results?.winner) {
  winner = data.results.winner;
}

return Functions.encodeString(
  JSON.stringify({
    status,
    winner
  })
);