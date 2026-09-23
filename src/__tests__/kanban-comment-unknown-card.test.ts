// A komment-végpont némán elnyelte az elgépelt kártya-azonosítót: HTTP 200-at
// adott, és a sort egy nem létező kártya alá írta, ahol soha senki nem látja.
// Mérve 2026-09-07: a `2310d8da` helyett `2310da` ment el, és csak azért derült
// ki, mert a válasz ki volt íratva. A flotta minden ágense így ír eredményt a
// táblára, tehát az elgépelés nem hibát ad, hanem néma veszteséget.
//
// A helyes minta ugyanabban a fájlban már ott állt: a `breakdown` ág megnézi a
// kártya létezését és 404-et ad. Ez a teszt azt rögzíti, hogy a komment ág is.
import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { RouteContext } from '../web/routes/types.js'

const addKanbanComment = vi.fn()
const getKanbanCard = vi.fn()

vi.mock('../db.js', async (orig) => {
  const actual = await orig<typeof import('../db.js')>()
  return { ...actual, getKanbanCard, addKanbanComment }
})

const { tryHandleKanban } = await import('../web/routes/kanban.js')

/** Egy POST kérés a komment-végpontra, a válasz kódjával és törzsével. */
async function postComment(cardId: string) {
  const chunks = [Buffer.from(JSON.stringify({ author: 'teszt', content: 'szöveg' }))]
  const req = {
    on(event: string, cb: (arg?: unknown) => void) {
      if (event === 'data') for (const c of chunks) cb(c)
      if (event === 'end') cb()
      return req
    },
    headers: {},
    socket: {},
  } as unknown as RouteContext['req']

  let status = 200
  let body = ''
  const res = {
    writeHead(code: number) { status = code; return res },
    setHeader() { return res },
    end(payload?: string) { if (payload) body = payload },
  } as unknown as RouteContext['res']

  const handled = await tryHandleKanban({
    req, res,
    path: `/api/kanban/${cardId}/comments`,
    method: 'POST',
    url: `/api/kanban/${cardId}/comments`,
  } as unknown as RouteContext)

  return { handled, status, body }
}

describe('kanban komment-végpont: ismeretlen kártya-azonosító', () => {
  beforeEach(() => {
    addKanbanComment.mockReset()
    getKanbanCard.mockReset()
  })

  // A LÉNYEG NEM A VÁLASZKÓD, HANEM HOGY NEM TÖRTÉNT SEMMI. Egy őrzőt nem az
  // minősít, hogy megszólal, hanem hogy megakadályoz -- ezért az írás hiánya az
  // első állítás, és a 404 csak utána.
  it('nem ír kommentet, ha a kártya nem létezik', async () => {
    getKanbanCard.mockReturnValue(undefined)

    const { handled, status } = await postComment('2310da')

    expect(addKanbanComment).not.toHaveBeenCalled()
    expect(handled).toBe(true)
    expect(status).toBe(404)
  })

  // ISMERT POZITÍV KONTROLL: a fenti állítás akkor is zöld lenne, ha a végpont
  // SOHA nem írna kommentet (elrontott útvonal, korábban elszálló ág). Ez a
  // párja bizonyítja, hogy ugyanez a hívás létező kártyára valóban ír.
  it('létező kártyára viszont ír', async () => {
    getKanbanCard.mockReturnValue({ id: '2310d8da', title: 'létezik' })
    addKanbanComment.mockReturnValue({ id: 1, card_id: '2310d8da' })

    const { handled, status } = await postComment('2310d8da')

    expect(addKanbanComment).toHaveBeenCalledTimes(1)
    expect(addKanbanComment.mock.calls[0][0]).toBe('2310d8da')
    expect(handled).toBe(true)
    expect(status).toBe(200)
  })
})
