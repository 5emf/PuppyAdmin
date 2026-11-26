# Host (Linux) test of libpupemu's cores, without Android:
#   cmake -S pupdates/android/native-test -B build-native -G Ninja && cmake --build build-native
#   build-native/emu_test gb  emu/gameboy-*.lua some.gb  600
#   build-native/emu_test gba emu/gba-*.lua some.gba 600 assets/gba/cult_bios_v1.bin
#   build-native/emu_test doom assets/doom/freedoom1.wad 300
cmake_minimum_required(VERSION 3.22)
project(pupemu_test C CXX)
add_subdirectory(../app/src/main/cpp pupemu)
add_executable(emu_test emu_test.cpp)
target_link_libraries(emu_test PRIVATE emucore doomcore m pthread "-Wl,--wrap=exit")
