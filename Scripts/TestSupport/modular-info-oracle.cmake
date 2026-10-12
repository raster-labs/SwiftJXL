# SPDX-License-Identifier: Apache-2.0
# Test-only CMAKE_PROJECT_INCLUDE hook. Build with the pinned libjxl tree's
# own target so static-library dependencies and compiler settings are retained.
# Does not modify the fetched reference source or link it into SwiftJXL.
if(CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR AND
   NOT TARGET swiftjxl-modular-info-oracle)
  add_executable(swiftjxl-modular-info-oracle
    "${CMAKE_CURRENT_LIST_DIR}/modular-info-oracle.c")
  target_include_directories(swiftjxl-modular-info-oracle PRIVATE
    "${CMAKE_SOURCE_DIR}/lib/include" "${CMAKE_BINARY_DIR}/lib/include")
  target_link_libraries(swiftjxl-modular-info-oracle PRIVATE jxl)
endif()
