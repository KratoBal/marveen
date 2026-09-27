#!/usr/bin/env node
// ANSWERS: Hogyan lat egy tervezo agens egy ELO lapot, tobb szelessegen, egy hivassal.
//
// MIERT LETEZIK, ES MIERT NEM ELEG A `design-shot.cjs`: az csak `file://` utat vesz
// (helyi HTML), mert arra keszult, hogy az agens a SAJAT munkajat lassa. Egy telepitett
// lap megnezesehez nincs eszkoz -- pedig pontosan az a kerdes, ami a tervlapbol NEM
// dolheto el.
//
// A MERT ESET, AMIBOL SZULETETT (2026-09-08): a terv EGYETLEN szelessegen all, tehat
// torespontot szerkezetileg nem hordoz. A `lg` (1024) a MI dontesunk volt, nem meres --
// es azt, hogy jo dontes-e, csak a valodi lapon lehet megnezni, a torespont ALATT es
// FOLOTT. Egy 1440-es es egy 390-es kep erre keves: mind a ketto messze van a hatartol.
//
// EZERT VESZ TOBB SZELESSEGET EGY HIVASBAN. Nem kenyelmi kerdes: ket kep ket kulon
// futasbol ket kulon pillanatot mutat, es egy telepites kozben keszult par ertelmezhetetlen.
//
// HASZNALAT:
//   node scripts/kirakat-kep.cjs <kimeneti-mappa> <szelessegek vesszovel> <nev=url> [nev=url ...]
//
//   node scripts/kirakat-kep.cjs exchange/kepek-0908 390,1000,1100,1440 \
//     korall=https://shop-staging.acropora.hu/hu/products/acropora-austea-tricolor
//
// AMIT A KEP MELLE KIIR, ES AMIERT: a kep NEM mondja meg, hany oszlop van -- azt hinni
// lehet rola. Ezert minden szelessegen LEMERI a kiszamolt `grid-template-columns`
// erteket es a resz, es azt kiirja. Igy a torespont-kerdes szamokkal dol el, nem
// ranezessel, es a kep a SZAM illusztracioja marad.
//
// ES KIIRJA A LAP SAJAT PANASZAIT IS (nem betoltott keresek, oldal-hibak). Egy kep, ami
// jol nez ki, meg elrejthet egy be nem toltott betut vagy kepet -- es a kep errol
// hallgat. A szam nem.

process.env.PLAYWRIGHT_BROWSERS_PATH =
  process.env.PLAYWRIGHT_BROWSERS_PATH || '/home/marveen/marveen/.playwright-browsers'

const path = require('path')
const fs = require('fs')

const [, , outArg, wArg, ...pairs] = process.argv

if (!outArg || !wArg || pairs.length === 0) {
  console.error('hasznalat: kirakat-kep.cjs <kimeneti-mappa> <szelessegek> <nev=url> [nev=url ...]')
  console.error('pelda:     kirakat-kep.cjs exchange/kepek 390,1000,1100,1440 korall=https://...')
  process.exit(2)
}

const outDir = path.resolve(outArg)
const widths = wArg.split(',').map(s => Number(s.trim())).filter(n => n > 0)
if (widths.length === 0) {
  console.error('FAIL: nincs ervenyes szelesseg')
  process.exit(2)
}

const targets = []
for (const p of pairs) {
  const i = p.indexOf('=')
  if (i < 1) { console.error(`FAIL: nev=url alakot varok, ez nem az: ${p}`); process.exit(2) }
  const nev = p.slice(0, i)
  const url = p.slice(i + 1)
  // CSAK a sajat boltjaink. Egy tervezo-eszkoz, ami barmilyen cimet lehiv, mar nem
  // tervezo-eszkoz: bongeszo.
  if (!/^https:\/\/[a-z0-9.-]*acropora\.hu(\/|$)/.test(url)) {
    console.error(`FAIL: csak acropora.hu cimet nyitok meg, ez nem az: ${url}`)
    process.exit(2)
  }
  targets.push([nev, url])
}

fs.mkdirSync(outDir, { recursive: true })

const { chromium } = require('/home/marveen/marveen/node_modules/playwright')

;(async () => {
  const browser = await chromium.launch()
  let hiba = 0
  try {
    for (const [nev, url] of targets) {
      for (const w of widths) {
        const page = await browser.newPage({ viewport: { width: w, height: 900 }, deviceScaleFactor: 1 })
        const panasz = []
        page.on('pageerror', e => panasz.push(`oldal-hiba: ${e.message}`))
        page.on('requestfailed', r => panasz.push(`nem toltodott be: ${r.url()}`))
        try {
          const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 })
          await page.evaluate(() => document.fonts && document.fonts.ready)
          const file = path.join(outDir, `${nev}-${w}.png`)
          await page.screenshot({ path: file, fullPage: true })

          const m = await page.evaluate(() => {
            // A KETOSZLOPOS RACS, es szandekosan a KISZAMOLT erteket olvassuk: az osztaly
            // neve azt mondja, mit KERTUNK, a kiszamolt ertek azt, mit KAPOTT az elem.
            const racs = [...document.querySelectorAll('*')].find(e => {
              const cs = getComputedStyle(e)
              return cs.display === 'grid' && cs.gridTemplateColumns.split(' ').length === 2
            })
            return {
              sw: document.documentElement.scrollWidth,
              sh: document.documentElement.scrollHeight,
              oszlopok: racs ? getComputedStyle(racs).gridTemplateColumns : null,
              res: racs ? getComputedStyle(racs).columnGap : null,
            }
          })

          const racsSzoveg = m.oszlopok
            ? `${m.oszlopok}  res ${m.res}`
            : 'NINCS ketoszlopos racs'
          console.log(`${nev} ${w}px  HTTP ${resp.status()}  lap ${m.sw}x${m.sh}  ${racsSzoveg}`)
          // A VIZSZINTES TULCSORDULAS KULON SOR, mert az mindig hiba, nem izles.
          if (m.sw > w) console.log(`  FIGYELEM: a lap SZELESEBB a nezetnel (${m.sw} > ${w}), vizszintesen gorgetni kell`)
          if (panasz.length) console.log(`  a lap sajat panaszai (${panasz.length}): ${panasz.slice(0, 3).join(' | ')}`)
        } catch (e) {
          hiba++
          console.log(`${nev} ${w}px HIBA: ${String(e).slice(0, 120)}`)
        }
        await page.close()
      }
    }
  } finally {
    await browser.close()
  }
  console.log(`\nKESZ: ${outDir}`)
  process.exit(hiba > 0 ? 1 : 0)
})()
