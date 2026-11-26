package com.pupdates.app

import org.json.JSONObject

/**
 * The Pupdates pet (a Tamagotchi-style pet drawn from the owner's original cat character sheet,
 * assets/pet/cat_v1.png). Hunger, fun and energy go down while time passes (also while the app is
 * closed: everything is worked out from timestamps), sleep refills energy, and the pet gets sad
 * when something runs low. Pure logic: PetView draws it, MainActivity's Pet section drives it.
 */
class Pet(var name: String = "Pup", var hunger: Double = 80.0, var joy: Double = 80.0, var energy: Double = 80.0,
          var asleep: Boolean = false, var born: Long = 0L, var last: Long = 0L, var care: Int = 0) {

    /** frames on the 7 x 5 sheet (column, row) */
    object Frames {
        val IDLE = listOf(0 to 0, 1 to 0, 2 to 0, 1 to 0)
        val IDLE2 = listOf(0 to 2, 1 to 2, 2 to 2, 1 to 2)
        val CAPE = listOf(0 to 1, 1 to 1, 2 to 1)
        val HAPPY = listOf(3 to 0, 4 to 0, 5 to 0, 6 to 0)
        val EAT = listOf(3 to 1, 4 to 1, 5 to 1, 6 to 1, 3 to 2, 4 to 2, 5 to 2)
        val SLEEP = listOf(0 to 3, 1 to 3, 2 to 3, 3 to 3)
        val SAD = listOf(4 to 3, 5 to 3, 6 to 3)
        val WALK = (0..6).map { it to 4 }
        const val COLS = 7
        const val ROWS = 5
    }

    companion object {
        const val HOUR = 3_600_000.0
        // per hour, awake / asleep
        const val HUNGER_AWAKE = 7.0
        const val FUN_AWAKE = 9.0
        const val ENERGY_AWAKE = 6.0
        const val HUNGER_ASLEEP = 3.0
        const val FUN_ASLEEP = 1.5
        const val ENERGY_ASLEEP = 25.0
        const val LOW = 25.0

        fun fromJson(s: String?, now: Long): Pet {
            if (s.isNullOrEmpty()) return Pet(born = now, last = now)
            return try {
                val o = JSONObject(s)
                Pet(o.optString("name", "Pup").take(20), o.optDouble("hunger", 80.0), o.optDouble("fun", 80.0), o.optDouble("energy", 80.0),
                    o.optBoolean("asleep"), o.optLong("born", now), o.optLong("last", now), o.optInt("care")).also { it.clamp() }
            } catch (e: Exception) { Pet(born = now, last = now) }
        }
    }

    fun toJson(): String = JSONObject().put("name", name).put("hunger", hunger).put("fun", joy).put("energy", energy)
        .put("asleep", asleep).put("born", born).put("last", last).put("care", care).toString()

    private fun clamp() {
        hunger = hunger.coerceIn(0.0, 100.0)
        joy = joy.coerceIn(0.0, 100.0)
        energy = energy.coerceIn(0.0, 100.0)
    }

    /** moves time on to now (a clock that went backwards changes nothing); wakes up once rested */
    fun advance(now: Long) {
        if (now <= last) { last = maxOf(last, now); return }
        var h = (now - last) / HOUR
        last = now
        if (asleep) {
            val toFull = (100.0 - energy) / ENERGY_ASLEEP
            val sleptH = minOf(h, toFull)
            hunger -= HUNGER_ASLEEP * sleptH
            joy -= FUN_ASLEEP * sleptH
            energy += ENERGY_ASLEEP * sleptH
            h -= sleptH
            clamp()
            if (energy >= 100.0) asleep = false else return
        }
        hunger -= HUNGER_AWAKE * h
        joy -= FUN_AWAKE * h
        energy -= ENERGY_AWAKE * h
        clamp()
    }

    val sad get() = hunger < LOW || joy < LOW || energy < LOW
    val level get() = 1 + care / 10
    fun ageDays(now: Long) = ((now - born) / 86_400_000L).toInt()

    /** "" when it worked, else why not (the pet's answer) */
    fun feed(now: Long): String {
        advance(now)
        if (asleep) return "$name is asleep."
        if (hunger > 92) return "$name is full."
        hunger += 30; joy += 3; care++; clamp()
        return ""
    }

    fun play(now: Long): String {
        advance(now)
        if (asleep) return "$name is asleep."
        if (energy < 12) return "$name is too tired to play."
        if (hunger < 10) return "$name is too hungry to play."
        joy += 25; energy -= 10; hunger -= 4; care++; clamp()
        return ""
    }

    fun pat(now: Long): String {
        advance(now)
        if (asleep) return "Shh, $name is asleep."
        joy += 3; clamp()
        return ""
    }

    fun toggleSleep(now: Long): String {
        advance(now)
        if (asleep) { asleep = false; return "" }
        if (energy > 90) return "$name is not sleepy."
        asleep = true
        return ""
    }

    fun mood(): String = when {
        asleep -> "Sleeping"
        hunger < LOW -> "Hungry"
        energy < LOW -> "Sleepy"
        joy < LOW -> "Bored"
        hunger > 70 && joy > 70 && energy > 50 -> "Happy"
        else -> "Fine"
    }
}
