#!/usr/bin/env bash
# ANSWERS: Hany EAS build maradt a keretbol ebben a szamlazasi idoszakban, es mikor fordul.
#
# MIERT LETEZIK (kerte acrobot, 2026-09-03): a build ezentul csak kulon engedellyel indul,
# es az engedelyhez tudni kell, mibol mennyi van. Eddig ezt senki nem merte: a szam a
# vezerlopulton lakott, ahova az agensek nem latnak be.
#
# EZ A PAR-JA az apple-build.sh-nak: az EAS oldal (mennyi keret maradt) itt, az Apple oldal
# (feldolgozta-e, telepitheto-e) ott.
#
# MURENA IRTA, es a sajat mappajaban allt, mert oda van irasjoga. Innentol ez a kozos
# peldany: o osszevetette a kettot (byte-azonos), es a sajatjat TOROLTE -- ket azonos
# peldany csak addig azonos, amig valaki az egyiket javitja.
#
# AMIT KIIR:
#   csomag           a fizetesi konstrukcio neve (Free, Production, ...)
#   idoszak          a szamlazasi idoszak kezdete es vege, budapesti fali oraval
#   build            elhasznalt / keret, es a maradek -- iOS es Android kulon is
#   helyi build      kulon vodor (local builds), nem ugyanaz a keret
#
# AMIT NEM MOND MEG, es ezt tudni kell hozza:
#   - Nem mondja meg, hogy egy ELBUKOTT build fogyasztja-e a keretet. A merest 2026-09-03-an
#     18 befejezett buildre tudtuk elvegezni, elbukott nem volt kozottuk, tehat errol
#     nincs adatunk.
#   - A szam a FIOK szintjen all, nem projektenkent. Ma egy app van a fiokban; ha tobb lesz,
#     mind ugyanabbol a keretbol fogy.
#
# HASZNALAT:
#   bash /home/marveen/marveen/agents/murena/scripts/eas-keret.sh
set -uo pipefail

TOKEN_FILE=/home/marveen/marveen/store/.expo-token
ACCOUNT=acropora

[ -r "$TOKEN_FILE" ] || { echo "FAIL: nincs olvashato Expo token ($TOKEN_FILE)" >&2; ls -l "$TOKEN_FILE" >&2 2>/dev/null; exit 1; }

TOKEN_FILE="$TOKEN_FILE" ACCOUNT="$ACCOUNT" node -e '
const fs = require("fs");
const token = fs.readFileSync(process.env.TOKEN_FILE, "utf8").trim();
const account = process.env.ACCOUNT;
const now = new Date().toISOString();

const query = `query Q($name: String!, $date: DateTime!) {
  account { byName(accountName: $name) {
    name appCount
    subscription { planId name }
    usageMetrics { byBillingPeriod(date: $date, service: BUILDS) {
      billingPeriod { start end }
      planMetrics { serviceMetric value limit
        platformBreakdown { ios { value limit } android { value limit } } }
      overageMetrics { serviceMetric value limit totalCost }
    } }
  } }
}`;

const huf = (iso) =>
  new Date(iso).toLocaleString("hu-HU", { timeZone: "Europe/Budapest", dateStyle: "short", timeStyle: "short" });

(async () => {
  const r = await fetch("https://api.expo.dev/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
    body: JSON.stringify({ query, variables: { name: account, date: now } }),
  });
  const j = await r.json();
  if (j.errors) {
    console.error("FAIL: az EAS nem adta ki az adatot.");
    console.error(JSON.stringify(j.errors, null, 1));
    process.exit(1);
  }
  const a = j.data.account.byName;
  const u = a.usageMetrics.byBillingPeriod;
  const builds = u.planMetrics.find((m) => m.serviceMetric === "BUILDS");
  const local = u.planMetrics.find((m) => m.serviceMetric === "LOCAL_BUILDS");

  console.log("fiok        " + a.name + "  (" + a.appCount + " app)");
  console.log("csomag      " + a.subscription.name + "  (" + a.subscription.planId + ")");
  console.log("idoszak     " + huf(u.billingPeriod.start) + "  ->  " + huf(u.billingPeriod.end));
  if (builds) {
    const left = builds.limit - builds.value;
    console.log("build       " + builds.value + " / " + builds.limit + "   marad: " + left);
    const p = builds.platformBreakdown;
    if (p) {
      console.log("  iOS       " + p.ios.value + " / " + p.ios.limit + "   marad: " + (p.ios.limit - p.ios.value));
      console.log("  Android   " + p.android.value + " / " + p.android.limit + "   marad: " + (p.android.limit - p.android.value));
    }
  }
  if (local) {
    console.log("helyi build " + local.value + " / " + local.limit + "   (kulon vodor)");
  }
  if (u.overageMetrics.length) {
    console.log("TULLEPES    " + JSON.stringify(u.overageMetrics));
  }
})().catch((e) => {
  console.error("FAIL: " + e.message);
  process.exit(1);
});
'
