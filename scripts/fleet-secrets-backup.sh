#!/usr/bin/env bash
# fleet-secrets-backup.sh -- a titkok TITKOSITOTT mentese a NAS-ra.
#
# WHY THIS EXISTS. A repo a konfiguraciot viszi, a napi mentes az adatot. A titkok egyikbe sem
# mehetnek. Ezert ma ott allunk, hogy egy gepvesztes utan mind a 31 tokent ujra ki kellene
# adni, egyenkent, kezzel, oraszamra -- pontosan az, amit Balázs 2026-09-01-en nem akar.
#
# A MEGOLDAS ALAKJA, es miert pont ilyen:
#   * a NAPI hasznalat NEM valtozik. A titkok tovabbra is sima fajlok a store/ mappaban,
#     csoportokkal elzarva. Nem kell "megnyitni" semmit, nincs kulcskeresgeles.
#   * a NAS-ra egy GPG-vel, JELSZOVAL titkositott csomag megy. Onmagaban semmit nem er.
#   * a jelszo KET helyen letezik: ezen a gepen (hogy hasznalni tudjuk) es Balázs
#     jelszokezelojeben (hogy egy gepvesztes utan is meglegyen). Csatornan SOHA nem megy at.
#
# Ez a ket masolat a lenyeg. Ha csak nalunk lenne, a gepvesztes a jelszot is elvinne, es a
# mentes hasznalhatatlan lenne. Ha csak nala, akkor minden hasznalatnal ot kellene kerdezni.
#
#   bash scripts/fleet-secrets-backup.sh
#
# EXIT 0 csak akkor, ha a tavoli fajl ott van ES a merete egyezik.

set -uo pipefail

ROOT="${FLEET_ROOT:-/home/marveen/marveen}"
STORE="$ROOT/store"
PASSFILE="${FLEET_SECRETS_PASS:-$STORE/.secrets-backup-passphrase}"
KEY="${FLEET_BACKUP_KEY:-/home/marveen/.ssh/id_ed25519_csupor_backup}"
DEST_USER="${FLEET_BACKUP_USER:-AcroBot}"
DEST_HOST="${FLEET_BACKUP_HOST:-100.98.191.44}"
DEST_DIR="${FLEET_BACKUP_DIR:-Acropora_Backup/acrobot-fleet}"
WORK="$STORE/backup-work"

if [ ! -s "$PASSFILE" ]; then
  echo "FAIL: nincs jelszo ($PASSFILE)." >&2
  echo "Enelkul nem titkositok. Egy jelszo nelkuli 'titkositott' mentes rosszabb a semminel," >&2
  echo "mert biztonsagnak latszik." >&2
  exit 1
fi

STAMP=$(date +%Y-%m-%d_%H-%M-%S)
NAME="acrobot-titkok-$STAMP.tar.gz.gpg"
mkdir -p "$WORK"

echo "== 1/4  A titkok osszegyujtese"
cd "$STORE" || exit 1
# Csak a titkok. A jelszo-fajl maga KIMARAD: egy csomag, ami a sajat nyitokulcsat is
# tartalmazza, nem titkositott csomag.
FILES=$(ls -1 .* 2>/dev/null | /bin/grep -E 'token|key|secret|cred|env' | /bin/grep -v 'secrets-backup-passphrase' || true)
N=$(printf '%s\n' "$FILES" | /bin/grep -c . || echo 0)
if [ "$N" -lt 5 ]; then
  echo "FAIL: csak $N fajlt talaltam, ez keves. Nem mentek felig." >&2
  exit 1
fi
echo "   $N fajl"

echo "== 2/4  Csomagolas es titkositas"
rm -f "$WORK/$NAME"
printf '%s\n' "$FILES" | tar czf - -T - 2>/dev/null | \
  gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$PASSFILE" -o "$WORK/$NAME" 2>/dev/null
SZ=$(stat -c %s "$WORK/$NAME" 2>/dev/null || echo 0)
if [ "$SZ" = "0" ]; then echo "FAIL: nem keszult csomag." >&2; exit 1; fi
echo "   $NAME: $SZ bajt"

echo "== 3/4  Ellenorzes: VISSZA lehet-e fejteni"
# Ez a lepes nem formasag. Egy titkositott fajl, amit meg soha nem nyitottunk ki, ugyanaz a
# kategoria, mint egy mentes, amibol soha nem allitottunk vissza: remeny, nem biztositek.
CNT=$(gpg --batch --yes --decrypt --passphrase-file "$PASSFILE" "$WORK/$NAME" 2>/dev/null | tar tz 2>/dev/null | /bin/grep -c . || echo 0)
if [ "$CNT" != "$N" ]; then
  echo "FAIL: visszafejtve $CNT fajl, de $N-et csomagoltam." >&2
  rm -f "$WORK/$NAME"
  exit 1
fi
echo "   visszafejtve, $CNT fajl, egyezik"

echo "== 4/4  Feltoltes es tavoli visszameres"
sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP >/dev/null 2>&1
-mkdir $DEST_DIR
put $WORK/$NAME $DEST_DIR/$NAME
SFTP
R=$(sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP 2>/dev/null | /bin/grep -F "$NAME" | /bin/tr -s ' ' | /bin/cut -d' ' -f5
ls -l $DEST_DIR
SFTP
)
if [ "$R" != "$SZ" ]; then
  echo "FAIL: a meret NEM egyezik (helyi $SZ, tavoli ${R:-nincs ott})." >&2
  exit 1
fi
rm -f "$WORK/$NAME"
echo "   tavoli meret: $R bajt"
echo
echo "KESZ. $DEST_DIR/$NAME"
echo "A csomag onmagaban semmit nem er. A jelszo ket helyen van: ezen a gepen es Balázs"
echo "jelszokezelojeben. Ha az egyik elvesz, a masik meg megvan."
