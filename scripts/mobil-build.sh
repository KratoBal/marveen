#!/usr/bin/env bash
# ANSWERS: Hogyan indul EL egy mobil build (iOS TestFlightre, Android telepitheto APK-ban), es mit ad vissza.
#
# MIERT LETEZIK, merve 2026-09-16 21:52: Balazs engedelyt adott ket buildre, es a
# flotta szerszamai kozott HAROM eszkoz allt a build KORUL (eas-keret.sh a keretet,
# eas-feltoltes.sh a feltoltest, apple-build.sh az Apple oldalat), de EGYIK SEM
# inditotta el. Az indito parancs a fejemben volt, nem a lemezen.
#
# Ez a kilencedik korlat-tipus a lapomon: az adat (es itt a KEPESSEG) megvan, a
# parancs nincs. A feloldasa nem jogosultsag-keres, hanem egy fajl.
#
# AMIT LEMERTEM AZNAP, ES AMI MIATT EZ EGYALTALAN MUKODIK:
#   - eas-cli NINCS telepitve, de `npx --yes eas-cli@latest` fut (24.6.0, node 22)
#   - a token a store/.expo-token fajlban all, EXPO_TOKEN kornyezeti valtozokent kell
#   - a klonnak a FRISS mainen kell allnia, kulonben a telefonra regi kod megy ki
#
# A KET PROFIL KULONBSEGE (eas.json), es ezt konnyu osszekeverni:
#   production       iOS: TestFlightre megy. autoIncrement, eles API.
#   production-apk   Android: eles API ES kozvetlenul telepitheto APK.
#   preview          a TESZT szerverre nez (api-staging). NEM ez kell, ha eles adat kell.
#
# HASZNALAT (a hostrol a kontenerben):
#   docker compose exec -u marveen marveen bash /home/marveen/marveen/scripts/mobil-build.sh ios
#   docker compose exec -u marveen marveen bash /home/marveen/marveen/scripts/mobil-build.sh android
#   docker compose exec -u marveen marveen bash /home/marveen/marveen/scripts/mobil-build.sh mindketto
#
# AMIT EZ NEM CSINAL MEG, SZANDEKOSAN: nem kerdez engedelyt. A build a keretbol fogy
# (eas-keret.sh), es Balazs 2026-09-03-i dontese szerint KULON engedellyel indul.
# Ez a szkript a parancsot adja meg, nem a jogot.

set -uo pipefail

KLON="${MOBIL_KLON:-/home/marveen/work/acropora-os}"
TOKEN_FILE="/home/marveen/marveen/store/.expo-token"
MIT="${1:-}"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "NINCS EXPO TOKEN: $TOKEN_FILE" >&2
  exit 1
fi

case "$MIT" in
  ios|android|mindketto) ;;
  *)
    echo "hasznalat: mobil-build.sh ios|android|mindketto" >&2
    exit 2
    ;;
esac

cd "$KLON" || exit 1

AG="$(git rev-parse --abbrev-ref HEAD)"
FEJ="$(git rev-parse --short HEAD)"
TAVOLI="$(git rev-parse --short origin/main 2>/dev/null || echo ismeretlen)"

echo "--- mobil-build ($(date '+%Y-%m-%d %H:%M:%S %Z')) ---"
echo "klon      $KLON"
echo "ag        $AG"
echo "fej       $FEJ"
echo "origin    $TAVOLI"

if [ "$FEJ" != "$TAVOLI" ]; then
  echo
  echo "MEGALLOK: a klon feje NEM egyezik az origin/main fejevel."
  echo "   A telefonra az menne ki, ami itt all -- nem az, ami a fo agon."
  echo "   Huzd ra eloszor:"
  echo "     bash /home/marveen/marveen/scripts/git-auth.sh -C $KLON pull --ff-only origin main"
  exit 3
fi

export EXPO_TOKEN
EXPO_TOKEN="$(cat "$TOKEN_FILE")"

cd "$KLON/apps/mobile" || exit 1

inditas() {
  local platform="$1" profil="$2"
  shift 2
  echo
  echo "=== $platform ($profil) ==="
  npx --yes eas-cli@latest build \
    --platform "$platform" \
    --profile "$profil" \
    --non-interactive \
    --no-wait "$@"
}

allapot=0
if [ "$MIT" = "ios" ] || [ "$MIT" = "mindketto" ]; then
  # --auto-submit: a TestFlight feltoltes is utemezodik, kulon parancs nelkul.
  inditas ios production --auto-submit || allapot=1
fi

if [ "$MIT" = "android" ] || [ "$MIT" = "mindketto" ]; then
  inditas android production-apk || allapot=1
fi

echo
echo "--- utana ---"
echo "  a build UTJA:        bash /home/marveen/marveen/scripts/eas-feltoltes.sh"
echo "  az Apple oldala:     bash /home/marveen/marveen/scripts/apple-build.sh"
echo "  a maradek keret:     bash /home/marveen/marveen/scripts/eas-keret.sh"
exit "$allapot"
