#!/usr/bin/env bash
# ANSWERS: Mit mond az APPLE egy feltoltott mobil buildrol: feldolgozta-e, es telepitheto-e a telefonra.
#
# MIERT LETEZIK (merve 2026-09-03): a feltoltes lezarultat murena meri az EAS oldalan, es
# onnantol az Apple oldala az enyem. Eddig ezt minden alkalommal KEZZEL raktam ossze egy
# beillesztett node-szkriptbol, es a receptet emlekezetbol vagy egy emlekbol kerestem elo.
# Egy recept, ami emlekben lakik, minden hasznalatnal ujra elronthato.
#
# A KRITIKUS RESZ, AMIN AZ ELSO PROBA ELHASALT: az ES256 alairas dsaEncoding merteke.
# Az alapertelmezett DER alak 401-et ad, az Apple 'ieee-p1363'-at var. Ez nem beallitas-izles:
# enelkul a hivas MINDIG jogosultsagi hibanak latszik, holott a kulcs jo.
#
# AMIT KIIR, ES AMIT NEM:
#   processingState  az APPLE feldolgozasa (PROCESSING, VALID, INVALID, FAILED)
#   internalBuildState  telepitheto-e a belso tesztelonek (IN_BETA_TESTING = igen)
#   expired          lejart-e a build
# Azt NEM mondja meg, hogy az adott ember TAGJA-e a belso csoportnak. A csoport egyszer all
# be, nem feltoltesenkent (lasd a 876-os emleket: egy kihagyott lepes egy mar meglevo
# allapotot allitott volna be ujra).
#
# HASZNALAT:
#   bash /home/marveen/marveen/scripts/apple-build.sh            # a legutobbi ot build
#   bash /home/marveen/marveen/scripts/apple-build.sh 13         # egy adott build szam
set -uo pipefail

KEY_FILE=/home/marveen/marveen/store/apple/AuthKey_9YBGSNC2ZD.p8
KEY_ID=9YBGSNC2ZD
ISSUER_ID=248e9533-ab53-4dc6-adc9-7be269dcf9f3
APP_ID=6802569809

[ -r "$KEY_FILE" ] || { echo "FAIL: nincs olvashato Apple kulcs ($KEY_FILE)" >&2; ls -l "$KEY_FILE" >&2 2>/dev/null; exit 1; }

WANT="${1:-}"

KEY_FILE="$KEY_FILE" KEY_ID="$KEY_ID" ISSUER_ID="$ISSUER_ID" APP_ID="$APP_ID" WANT="$WANT" node -e '
const crypto = require("crypto");
const fs = require("fs");

const key = fs.readFileSync(process.env.KEY_FILE, "utf8");
const now = Math.floor(Date.now() / 1000);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const header = b64({ alg: "ES256", kid: process.env.KEY_ID, typ: "JWT" });
const payload = b64({
  iss: process.env.ISSUER_ID,
  iat: now,
  exp: now + 600,
  aud: "appstoreconnect-v1",
});
const signer = crypto.createSign("SHA256");
signer.update(header + "." + payload);
// A DER alapertelmezes 401-et ad. Ez a sor a kulonbseg.
const sig = signer.sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
const jwt = header + "." + payload + "." + sig;

const api = async (path) => {
  const r = await fetch("https://api.appstoreconnect.apple.com" + path, {
    headers: { Authorization: "Bearer " + jwt },
  });
  if (!r.ok) {
    const body = await r.text();
    throw new Error("HTTP " + r.status + " " + path + " :: " + body.slice(0, 300));
  }
  return r.json();
};

(async () => {
  const want = process.env.WANT;
  const builds = await api(
    "/v1/builds?filter[app]=" + process.env.APP_ID +
    "&limit=" + (want ? 20 : 5) +
    "&sort=-uploadedDate"
  );
  const rows = builds.data.filter((b) => !want || b.attributes.version === want);
  if (rows.length === 0) {
    console.log("NINCS ilyen build az utolso 20 kozott" + (want ? " (" + want + ")" : ""));
    console.log("A nulla melle: filter[app]=" + process.env.APP_ID + ", sort=-uploadedDate, limit=20.");
    return;
  }
  for (const b of rows) {
    const a = b.attributes;
    let beta = {};
    try {
      const d = await api("/v1/builds/" + b.id + "/buildBetaDetail");
      beta = d.data ? d.data.attributes : {};
    } catch (e) {
      beta = { hiba: String(e.message).slice(0, 120) };
    }
    console.log("build " + a.version);
    console.log("  feltoltve        " + a.uploadedDate);
    console.log("  feldolgozas      " + a.processingState);
    console.log("  lejart           " + a.expired);
    console.log("  belso allapot    " + (beta.internalBuildState || "?"));
    console.log("  kulso allapot    " + (beta.externalBuildState || "?"));
    if (beta.hiba) console.log("  (a beta-reszlet nem jott le: " + beta.hiba + ")");
  }
})().catch((e) => {
  console.error("FAIL: " + e.message);
  process.exit(1);
});
'
