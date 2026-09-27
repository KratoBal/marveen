#!/usr/bin/env bash
# fleet-backup.sh -- put the fleet's own data somewhere that is not this machine.
#
# WHY THIS EXISTS. Measured 2026-09-01: the memories, the kanban board and every inter-agent
# message live in ONE 57 MB SQLite file, and NO copy of it existed anywhere. Not on this disk,
# not off it. The `store/pre-update-1.33.0-backup` directory looks like a backup and is not:
# it holds source files from an earlier update and no database at all.
#
# The Acrobot repo covers configuration and code. It cannot cover this: the database changes
# every minute and carries conversation content. That is what a backup is for.
#
# DESTINATION. The csupor NAS, over SFTP, with the key set up on 2026-08-29:
#   AcroBot@100.98.191.44 : Acropora_Backup/
# The acropora-os Postgres dump has been landing there daily since 2026-08-21. This adds the
# fleet beside it, in the same naming convention, in its own folder.
#
# USAGE
#   bash scripts/fleet-backup.sh            # snapshot, upload, verify
#   bash scripts/fleet-backup.sh --local    # snapshot only, no upload (for a dry look)
#
# EXIT 0 only if the remote file exists AND its size matches the local one.

set -uo pipefail

ROOT="${FLEET_ROOT:-/home/marveen/marveen}"
KEY="${FLEET_BACKUP_KEY:-/home/marveen/.ssh/id_ed25519_csupor_backup}"
DEST_USER="${FLEET_BACKUP_USER:-AcroBot}"
DEST_HOST="${FLEET_BACKUP_HOST:-100.98.191.44}"
DEST_DIR="${FLEET_BACKUP_DIR:-Acropora_Backup/acrobot-fleet}"
WORK="$ROOT/store/backup-work"
DB="$ROOT/store/claudeclaw.db"

STAMP=$(date +%Y-%m-%d_%H-%M-%S)
NAME="acrobot-fleet-$STAMP.db.gz"

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# HETI CSOMAG: a beszelgetes-naplok.
#
# Kulon fut, es kulon okbol. A naplok ~452 MB-ot tesznek ki, es LASSAN valtoznak:
# egy nap alatt a torzsuk ugyanaz marad. Naponta feltolteni ugyanazt a 452 MB-ot
# nem ad tobb biztonsagot, csak tobb helyet fogyaszt a NAS-on.
#
# De MENTENI KELL oket, es ezt ma mertuk meg: polip naploja 09:25 es 12:06 kozott
# egyaltalan nem irodott, es amikor kiderult, az egyetlen dolog, ami a kilencven
# perc munkat megmentette, egy kezzel irt atado lap volt. Egy naplo, ami megvan,
# ennel tobbet er.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--transcripts" ]; then
  TR="acrobot-naplok-$STAMP.tar.gz"
  echo "== 1/3  A beszelgetes-naplok csomagolasa"
  tar czf "$WORK/$TR" --ignore-failed-read \
    -C /home/marveen/.claude projects 2>"$WORK/tar-naplo-hibak.txt"
  TRSZ=$(stat -c %s "$WORK/$TR" 2>/dev/null || echo 0)
  SK=$(/bin/grep -c . "$WORK/tar-naplo-hibak.txt" 2>/dev/null || echo 0)
  echo "   $TR: $TRSZ bajt, kihagyva $SK fajl"
  # A kihagyasokat KIIRJUK. Egy agens sajat felhasznaloja ala zart naplo nem hiba,
  # de nem is szabad csendben eltunnie: ha ez a szam no, az azt jelenti, hogy egyre
  # tobb beszelgetes marad ki a mentesbol.
  [ "$SK" != "0" ] && head -3 "$WORK/tar-naplo-hibak.txt"
  [ "$TRSZ" = "0" ] && { echo "FAIL: ures csomag." >&2; exit 1; }

  echo "== 2/3  Feltoltes"
  sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP >/dev/null 2>&1
-mkdir $DEST_DIR
put $WORK/$TR $DEST_DIR/$TR
SFTP

  echo "== 3/3  Visszameres a tavoli oldalon"
  RSZ=$(sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP 2>/dev/null | /bin/grep -F "$TR" | /bin/tr -s ' ' | /bin/cut -d' ' -f5
ls -l $DEST_DIR
SFTP
)
  if [ "$RSZ" != "$TRSZ" ]; then
    echo "FAIL: a meret NEM egyezik (helyi $TRSZ, tavoli ${RSZ:-nincs ott})." >&2
    exit 1
  fi
  rm -f "$WORK/$TR"
  echo "   tavoli meret: $RSZ bajt"
  echo
  echo "KESZ. $DEST_DIR/$TR"
  exit 0
fi

echo "== 1/4  Konzisztens pillanatkep az adatbazisrol"
# NOT a plain cp. The database runs in WAL mode: a raw copy of the .db without the -wal is a
# TORN snapshot that may restore short, and nothing about it looks wrong. The sqlite3 backup
# API takes a consistent copy of a live database, which is the entire point.
python3 - "$DB" "$WORK/snapshot.db" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
d = sqlite3.connect(dst)
with d:
    s.backup(d)
n = d.execute("select count(*) from sqlite_master where type='table'").fetchone()[0]
d.close(); s.close()
print("   tabla a pillanatkepben: %d" % n)
PY
if [ ! -s "$WORK/snapshot.db" ]; then
  echo "FAIL: nem keszult pillanatkep." >&2
  exit 1
fi
RAW=$(stat -c %s "$WORK/snapshot.db")
echo "   pillanatkep: $RAW bajt"

echo "== 2/4  Tomorites"
rm -f "$WORK/$NAME"
gzip -c "$WORK/snapshot.db" > "$WORK/$NAME" || { echo "FAIL: tomorites" >&2; exit 1; }
LOCAL=$(stat -c %s "$WORK/$NAME")
echo "   $NAME: $LOCAL bajt"

if [ "${1:-}" = "--local" ]; then
  echo
  echo "--local: feltoltes nelkul allok meg. A fajl itt van: $WORK/$NAME"
  exit 0
fi

echo "== 3/4  Feltoltes a csupor NAS-ra"
# The destination account has NO shell (Synology, SFTP service only), so this must be sftp and
# not scp-over-ssh. Measured 2026-08-29: shell access is refused by design, and asking for it
# would have been the wrong request -- a backup account does not need a command line.
sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP >/dev/null 2>&1
-mkdir $DEST_DIR
put $WORK/$NAME $DEST_DIR/$NAME
SFTP

echo "== 4/4  Visszameres a TAVOLI oldalon"
# The upload exit code is not evidence. What counts is the file being there with the right
# size -- the same rule as everywhere else in this fleet: sent is not delivered.
REMOTE=$(sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP 2>/dev/null | /bin/grep -F "$NAME" | /bin/tr -s ' ' | /bin/cut -d' ' -f5
ls -l $DEST_DIR
SFTP
)
if [ -z "$REMOTE" ]; then
  echo "FAIL: a fajl NINCS ott a tavoli oldalon." >&2
  exit 1
fi
echo "   tavoli meret: $REMOTE bajt"
if [ "$REMOTE" != "$LOCAL" ]; then
  echo "FAIL: a meret NEM egyezik (helyi $LOCAL, tavoli $REMOTE)." >&2
  exit 1
fi

rm -f "$WORK/snapshot.db"
echo "   adatbazis kesz: $DEST_DIR/$NAME"

# ---------------------------------------------------------------------------
# A MASODIK CSOMAG: az agensek dokumentumai.
#
# Balázs 2026-09-01: "nem szeretnem eldonteni. Leirtam mi az igenyem" -- tehat a
# hatokort nekem kell eldontenem az igenybol, es ez az indoklas:
#
#   az agens mappak egyutt 5,6 GB, DE a dokumentumok (md, tsv, txt, csv) ebbol
#   73 MB, 5335 fajl. A maradek tulnyomo resze klonozott repo es csomagtar
#   (murena 2,9 GB, nautilus 2,2 GB), ami gitbol ujraall -- azt menteni annyi,
#   mint ugyanazt harmadszor tarolni.
#
#   A dokumentumok viszont NEM allnak ujra sehonnan: ezek a meresek, a riportok,
#   az atado lapok es a vazlatok. 2026-09-01-en egy agens kilencven percnyi
#   munkat vesztett volna, es az atado lapja mentette meg -- pontosan egy ilyen
#   fajl.
# ---------------------------------------------------------------------------
DOCS="acrobot-docs-$STAMP.tar.gz"
echo "== 5/6  Az agensek dokumentumai ES A FLOTTA SZERSZAMKESZLETE"
cd "$ROOT" || exit 1
# A SZKRIPTEK 2026-09-21 OTA VANNAK BENNE, ES AZ OK MERES:
#   scripts/  alatt          201 db .sh es .py
#   agents/**/scripts alatt  342 db
#   es maga ez a fajl is     UNTRACKED volt (git status: ?? scripts/fleet-backup.sh)
# Vagyis a mento eszkoz sem volt mentve. A repo NEM fedi oket: a frissites mar egyszer
# elvitte a szerszamkeszletet (4d9e11c2 kartya), es egy untracked fajlnak a lemezen kivul
# SEHOL nem volt masolata.
#
# MIERT A DOKUMENTUM-CSOMAGBA, ES NEM KULON: ugyanaz a jellemzojuk, amiert a dokumentumok
# itt vannak -- nem allnak ujra sehonnan. Egy kulon csomag egy kulon ellenorzest is kivanna,
# es egy nem ellenorzott feltoltes ugyanaz, mint a hianyzo.
# --ignore-failed-read: egy masik felhasznalo ala zart fajl NE allitsa meg az egeszet.
# A kihagyasokat viszont KIIRJUK, mert egy csendben kihagyott fajl a legrosszabb fajta.
tar czf "$WORK/$DOCS" --ignore-failed-read \
  --exclude='*/node_modules/*' --exclude='*/.git/*' --exclude='*/.claude-config/*' \
  --exclude='*/.claude/*' --exclude='*/output/*.html' \
  $(find agents scripts -type f \
      \( -name '*.md' -o -name '*.tsv' -o -name '*.txt' -o -name '*.csv' \
         -o -name '*.sh' -o -name '*.py' -o -name '*.sql' \) \
    -not -path '*/.claude*' -not -path '*/node_modules/*' -print 2>/dev/null | head -20000) \
  2>"$WORK/tar-hibak.txt"
DOCSZ=$(stat -c %s "$WORK/$DOCS" 2>/dev/null || echo 0)
SKIPPED=$(/bin/grep -c . "$WORK/tar-hibak.txt" 2>/dev/null || echo 0)
echo "   $DOCS: $DOCSZ bajt, kihagyva $SKIPPED fajl"
[ "$SKIPPED" != "0" ] && head -3 "$WORK/tar-hibak.txt"

echo "== 6/6  A dokumentumok feltoltese es visszamerese"
sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP >/dev/null 2>&1
put $WORK/$DOCS $DEST_DIR/$DOCS
SFTP
DREMOTE=$(sftp -o BatchMode=yes -o ConnectTimeout=15 -i "$KEY" "$DEST_USER@$DEST_HOST" <<SFTP 2>/dev/null | /bin/grep -F "$DOCS" | /bin/tr -s ' ' | /bin/cut -d' ' -f5
ls -l $DEST_DIR
SFTP
)
if [ "$DREMOTE" != "$DOCSZ" ]; then
  echo "FAIL: a dokumentum-csomag merete NEM egyezik (helyi $DOCSZ, tavoli ${DREMOTE:-nincs ott})." >&2
  exit 1
fi
echo "   tavoli meret: $DREMOTE bajt"
rm -f "$WORK/$DOCS" "$WORK/$NAME"

echo
echo "KESZ. Ket csomag, mindketto merete egyeztetve a tavoli oldalon:"
echo "  $DEST_DIR/$NAME          ($LOCAL bajt)   memoria, kanban, agens-uzenetek"
echo "  $DEST_DIR/$DOCS   ($DOCSZ bajt)   az agensek dokumentumai"
echo
echo "AMI SZANDEKOSAN NINCS BENNE:"
echo "  klonozott repok es csomagtarak: gitbol ujraallnak, harmadszor tarolni ertelmetlen"
echo "  a beszelgetes-naplok: kulon, heti csomagban (fleet-backup-transcripts)"
echo "  az azonossag es a kod: az Acrobot repoban"
echo "  ES A LEGFONTOSABB: egy mentes, amibol meg soha nem allitottunk vissza, nem mentes."
