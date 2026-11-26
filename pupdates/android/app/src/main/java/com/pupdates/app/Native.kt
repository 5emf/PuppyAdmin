package com.pupdates.app

import java.nio.ByteBuffer

/** libpupemu (src/main/cpp): Puppy Admin's Game Boy / GBA Luau cores in a Luau VM, and Doom (doomgeneric). */
object Native {
    init { System.loadLibrary("pupemu") }

    const val GB = 1
    const val GBA = 2

    /** null = started, else the error. */
    @JvmStatic external fun luaOpen(kind: Int, module: ByteArray, rom: ByteArray, bios: ByteArray?, save: ByteArray?): String?
    /** width shl 16 or height */
    @JvmStatic external fun luaSize(): Int
    /** one frame into a direct buffer (RGBA); draw = false skips drawing. null = fine, else the error. */
    @JvmStatic external fun luaFrame(out: ByteBuffer, draw: Boolean): String?
    /** bit set = held: 0 A, 1 B, 2 Select, 3 Start, 4 Right, 5 Left, 6 Up, 7 Down, 8 R, 9 L */
    @JvmStatic external fun luaKeys(mask: Int)
    /** GBA sound since the last call: signed 16-bit mono, 16384 Hz. Returns the sample count. */
    @JvmStatic external fun luaAudio(out: ShortArray): Int
    /** the battery save when it changed, else null */
    @JvmStatic external fun luaSave(): ByteArray?
    @JvmStatic external fun luaClose()

    /** Doom runs once per process (EmuActivity has its own process). null = started, else the error. */
    @JvmStatic external fun doomOpen(wad: String, dir: String): String?
    /** 1 running, 0 quit from Doom's menu, -1 error (see doomError) */
    @JvmStatic external fun doomTick(out: ByteBuffer): Int
    @JvmStatic external fun doomKey(down: Boolean, code: Int)
    /** stereo 16-bit at 22050 Hz into out (pairs) */
    @JvmStatic external fun doomAudio(out: ShortArray): Int
    @JvmStatic external fun doomError(): String
}
