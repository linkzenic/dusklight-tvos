# Dusklight Mod SDK entry point
#
# Provides game/service headers, compile definitions and version.h without
# configuring the full game tree.
#
# Usage (from a mod project):
#   add_subdirectory(<dusk>/sdk dusk-sdk EXCLUDE_FROM_ALL)
#   add_mod(my_mod SOURCES ... MOD_JSON mod.json)

cmake_minimum_required(VERSION 3.25)

if (TARGET dusklight_game_headers)
    message(FATAL_ERROR "Mod SDK already configured")
endif ()

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/WindowsTargetProcessor.cmake")

if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING
            "Build type options: Debug Release RelWithDebInfo MinSizeRel" FORCE)
endif ()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Version detection & version.h
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/DetectVersion.cmake")
detect_version()
configure_version_header()

# Game ABI headers & compile definitions
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/GameABIConfig.cmake")

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/ModSDK.cmake")
