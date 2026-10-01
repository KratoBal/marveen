// A kezbesito kor adagja NEM globalisan a legregebbi huszonot uzenet, hanem
// koronkent egy-egy minden cimzettnek. Az elozo (globalis) alak MERT hibat okozott
// 2026-09-04-en: 34 fuggo uzenetbol 27 EGY dolgozo agense volt, az adag 100
// szazalekban az ove lett, es negy keszen allo agens orakon at NEM kapott semmit.
// A hiba nema volt: nem hibauzenet, nem naplo-sor, csak nem tortent kezbesites.
import { describe, it } from 'vitest'
import assert from 'node:assert/strict'
import { fairSliceByReceiver } from '../web/message-router.js'
import type { AgentMessage } from '../db.js'

function msg(id: number, to: string): AgentMessage {
  return { id, from_agent: 'acrobot', to_agent: to, content: 'x', status: 'pending', created_at: id } as AgentMessage
}

describe('fairSliceByReceiver', () => {
  it('EGY cimzett nem eheztetheti ki a tobbit -- ez a mert hiba', () => {
    // Pontosan a 2026-09-04-i alak: egy agensnek sok REGI uzenete, a tobbinek keves ujabb.
    const pending = [
      ...Array.from({ length: 27 }, (_, i) => msg(i + 1, 'nautilus')),
      msg(100, 'barracuda'),
      msg(101, 'korall'),
      msg(102, 'murena'),
    ]
    const out = fairSliceByReceiver(pending, 25)
    const receivers = new Set(out.map(m => m.to_agent))
    assert.equal(out.length, 25)
    // A regi alak alatt ez a halmaz EGY elemu volt (csak nautilus).
    assert.ok(receivers.has('barracuda'), 'barracuda uzenete nem kerult be az adagba')
    assert.ok(receivers.has('korall'), 'korall uzenete nem kerult be az adagba')
    assert.ok(receivers.has('murena'), 'murena uzenete nem kerult be az adagba')
  })

  it('egy cimzetten BELUL megmarad a legregebbi-eloszor sorrend', () => {
    const pending = [msg(1, 'a'), msg(2, 'b'), msg(3, 'a'), msg(4, 'b'), msg(5, 'a')]
    const out = fairSliceByReceiver(pending, 4)
    const aIds = out.filter(m => m.to_agent === 'a').map(m => m.id)
    assert.deepEqual(aIds, [1, 3], 'az egy cimzetthez tartozo sorrend felborult')
  })

  it('ha minden befer, semmit nem dob el es nem is rendez at', () => {
    const pending = [msg(1, 'a'), msg(2, 'b'), msg(3, 'a')]
    const out = fairSliceByReceiver(pending, 25)
    assert.deepEqual(out.map(m => m.id), [1, 2, 3])
  })

  it('az elso kor a legregebbi uzenettel rendelkezo cimzettel kezd', () => {
    const pending = [msg(1, 'regi'), msg(2, 'uj'), msg(3, 'regi')]
    const out = fairSliceByReceiver(pending, 2)
    assert.deepEqual(out.map(m => m.to_agent), ['regi', 'uj'])
  })
})
