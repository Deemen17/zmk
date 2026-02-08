# Copyright (c) 2026 DE
# zmk de indicator
zephyr_library()
zephyr_library_include_directories(${CMAKE_SOURCE_DIR}/include)
zephyr_library_sources(src/de_zmk_indicator.c)