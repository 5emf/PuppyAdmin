package com.pupdates.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PetTest {
    private val h = 3_600_000L

    @Test fun timePassesWhileClosed() {
        val p = Pet(born = 0, last = 0)
        p.advance(5 * h)
        assertEquals(80 - 5 * Pet.HUNGER_AWAKE, p.hunger, 1e-6)
        assertEquals(80 - 5 * Pet.FUN_AWAKE, p.joy, 1e-6)
        p.advance(100 * h)
        assertEquals(0.0, p.hunger, 0.0)
        assertTrue(p.sad)
        assertEquals("Hungry", p.mood())
        p.advance(50 * h)   // a clock going backwards changes nothing
        assertEquals(100 * h, p.last)
    }

    @Test fun sleepRefillsThenWakes() {
        val p = Pet(energy = 50.0, born = 0, last = 0)
        assertEquals("", p.toggleSleep(0))
        assertTrue(p.asleep)
        p.advance(h)
        assertEquals(75.0, p.energy, 1e-6)
        assertEquals("Pup is asleep.", p.feed(h))
        p.advance(3 * h)    // full after 2 h of sleep, then awake for 1 h
        assertFalse(p.asleep)
        assertEquals(100 - Pet.ENERGY_AWAKE, p.energy, 1e-6)
    }

    @Test fun careAndLimits() {
        val p = Pet(hunger = 50.0, born = 0, last = 0)
        assertEquals("", p.feed(0))
        assertEquals(80.0, p.hunger, 1e-6)
        assertEquals("", p.feed(0))
        assertEquals("Pup is full.", p.feed(0))
        p.energy = 5.0
        assertEquals("Pup is too tired to play.", p.play(0))
        p.energy = 60.0
        assertEquals("", p.play(0))
        assertEquals(3, p.care)
        val back = Pet.fromJson(p.toJson(), 0)
        assertEquals(p.hunger, back.hunger, 1e-9)
        assertEquals(p.joy, back.joy, 1e-9)
        assertEquals(3, back.care)
        assertEquals("Pup", Pet.fromJson("not json", 7).name)
    }
}
