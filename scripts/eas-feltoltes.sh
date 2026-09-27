#!/usr/bin/env bash
# ANSWERS: Hol tart egy kesz mobil build UTJA az Apple fele: sorban all-e a feltoltes, vagy mar atment.
#
# MIERT LETEZIK (merve 2026-09-14 17:45, Balazs kerdesere): "Ennyi ido alatt nem lett kesz
# a build?" A build HAT PERC alatt kesz volt. A FELTOLTES allt sorban negyvennyolc percig.
#
# A KET MEGLEVO ESZKOZ KOZOTT LYUK VOLT:
#   eas-keret.sh      mennyi keret maradt (EAS oldal, szamlazas)
#   apple-build.sh    mit mond az Apple egy MAR FELTOLTOTT buildrol
# A kozotti allapot a SUBMISSION, es arra nem volt parancs. Ezert 17:45-kor az
# apple-build.sh meg csak a 13 szamut mutatta, holott a 14 szamu EAS-en otvenket perce
# kesz volt. Aki csak azt a kettot nezi, azt hiszi, a BUILD all -- pedig a feltoltes all.
#
# Ez a kilencedik korlat-tipus: az adat megvolt, a parancs nem.
#
# AMIT KIIR (buildenkent egy sor):
#   build szam, allapot, a sorban allas kezdete es vege, es ha van, a hiba
#   IN_QUEUE / IN_PROGRESS = meg tart. FINISHED = az Apple-nel van (onnantol apple-build.sh).
#   ERRORED = elhasalt, es a hibauzenet is kijon.
#
# AMIT NEM MOND MEG: hogy az Apple feldolgozta-e. Az a FELTOLTES UTAN kezdodik, es azt az
# apple-build.sh meri. A ketto egymas utan van, nem egymas helyett.
#
# HASZNALAT:
#   bash /home/marveen/marveen/scripts/eas-feltoltes.sh          # az utolso hat iOS feltoltes
#   bash /home/marveen/marveen/scripts/eas-feltoltes.sh ANDROID  # a masik platform
set -uo pipefail

TOKEN_FILE=/home/marveen/marveen/store/.expo-token
APP_ID=95c3f5b6-fd32-4ca8-8465-62a4c1e6243c

[ -r "$TOKEN_FILE" ] || { echo "FAIL: nincs olvashato Expo token ($TOKEN_FILE)" >&2; ls -l "$TOKEN_FILE" >&2 2>/dev/null; exit 1; }

PLATFORM="${1:-IOS}"

TOKEN_FILE="$TOKEN_FILE" APP_ID="$APP_ID" PLATFORM="$PLATFORM" node -e '
const fs = require("fs");
const token = fs.readFileSync(process.env.TOKEN_FILE, "utf8").trim();

// A filter argumentum KOTELEZO: nelkule a szerver validacios hibat ad, nem ures listat.
const query = `query Q($id: String!, $p: AppPlatform!) {
  app { byId(appId: $id) {
    submissions(limit: 6, offset: 0, filter: { platform: $p }) {
      id status platform createdAt updatedAt
      error { errorCode message }
      submittedBuild { appBuildVersion appVersion gitCommitHash }
    }
  } }
}`;

const hu = (iso) => iso
  ? new Date(iso).toLocaleString("hu-HU", { timeZone: "Europe/Budapest", dateStyle: "short", timeStyle: "medium" })
  : "-";

(async () => {
  const r = await fetch("https://api.expo.dev/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
    body: JSON.stringify({ query, variables: { id: process.env.APP_ID, p: process.env.PLATFORM } })
  });
  const j = await r.json();
  if (j.errors) { console.error("FAIL: " + j.errors.map(e => e.message).join("; ")); process.exit(1); }
  const list = j.data && j.data.app && j.data.app.byId && j.data.app.byId.submissions;
  if (!list || !list.length) { console.log("nincs feltoltes ezen a platformon: " + process.env.PLATFORM); return; }
  for (const s of list) {
    const b = s.submittedBuild;
    console.log("build " + (b ? b.appBuildVersion : "?") + "  " + s.status);
    console.log("  commit       " + (b && b.gitCommitHash ? b.gitCommitHash.slice(0, 7) : "-"));
    console.log("  sorba allt   " + hu(s.createdAt));
    console.log("  frissult     " + hu(s.updatedAt));
    if (s.error) console.log("  hiba         " + s.error.errorCode + ": " + s.error.message);
  }
})().catch((e) => { console.error("FAIL: " + e.message); process.exit(1); });
'
