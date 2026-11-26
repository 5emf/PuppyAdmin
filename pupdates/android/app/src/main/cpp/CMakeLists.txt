# Pupdates emulators (libpupemu): Luau VM for Puppy Admin's Game Boy / GBA modules, doomgeneric for Doom.
# Sources are fetched at build time (pinned); Doom gets Puppy Admin's patches from emu/doom-src.
# Also builds on Linux for the host test (pupdates/android/native-test).
cmake_minimum_required(VERSION 3.22)
project(pupemu C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../../.." ABSOLUTE)
set(DOOM_SRC_DIR "${REPO_ROOT}/emu/doom-src")

include(FetchContent)
set(LUAU_BUILD_CLI OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_WEB OFF CACHE BOOL "" FORCE)
set(LUAU_EXTERN_C ON CACHE BOOL "" FORCE)
FetchContent_Declare(luau
    GIT_REPOSITORY https://github.com/luau-lang/luau.git
    GIT_TAG 0.748
    GIT_SHALLOW TRUE)
FetchContent_Declare(doomgeneric
    GIT_REPOSITORY https://github.com/ozkl/doomgeneric.git
    GIT_TAG e257a09527062bfb986b6e5e0780839b6cbd5b71
    PATCH_COMMAND git apply --whitespace=nowarn "${DOOM_SRC_DIR}/i_video.c.patch" "${DOOM_SRC_DIR}/i_sound.c.patch")
FetchContent_MakeAvailable(luau)
FetchContent_GetProperties(doomgeneric)
if(NOT doomgeneric_POPULATED)
    FetchContent_Populate(doomgeneric)
endif()

set(DG "${doomgeneric_SOURCE_DIR}/doomgeneric")
set(DOOM_FILES dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main d_mode d_net f_finale f_wipe
    g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound i_system i_timer memio m_argv m_bbox m_cheat
    m_config m_controls m_fixed m_menu m_misc m_random p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl
    p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main
    r_plane r_segs r_sky r_things sha1 sounds statdump st_lib st_stuff s_sound tables v_video wi_stuff w_checksum
    w_file w_main w_wad z_zone w_file_stdc i_input i_video doomgeneric)
set(DOOM_SOURCES "${DOOM_SRC_DIR}/doomgeneric_puppy.c")
foreach(f ${DOOM_FILES})
    list(APPEND DOOM_SOURCES "${DG}/${f}.c")
endforeach()
add_library(doomcore STATIC ${DOOM_SOURCES} emu_doom.c)
target_include_directories(doomcore PUBLIC "${DG}" "${CMAKE_CURRENT_LIST_DIR}")
target_compile_definitions(doomcore PRIVATE PUPPY_ADMIN NORMALUNIX LINUX _DEFAULT_SOURCE)
target_compile_options(doomcore PRIVATE -w -fno-strict-aliasing)

add_library(emucore STATIC emu_lua.cpp emu_games.cpp)
target_include_directories(emucore PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(emucore PUBLIC Luau.VM Luau.Compiler Luau.CodeGen)

if(ANDROID)
    add_library(pupemu SHARED emu_jni.cpp)
    target_link_libraries(pupemu PRIVATE emucore doomcore log m "-Wl,--wrap=exit")
endif()
