cmake_minimum_required(VERSION 3.22.1)
project(movementor_stockfish CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(SF_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/stockfish/src")
if(NOT EXISTS "${SF_SRC_DIR}/engine.cpp")
  message(FATAL_ERROR
    "Stockfish source missing at ${SF_SRC_DIR}. "
    "Run `bash tool/prepare_android_stockfish.sh` before building Android APKs.")
endif()

set(STOCKFISH_CORE_SOURCES
  "${SF_SRC_DIR}/attacks.cpp"
  "${SF_SRC_DIR}/benchmark.cpp"
  "${SF_SRC_DIR}/bitboard.cpp"
  "${SF_SRC_DIR}/engine.cpp"
  "${SF_SRC_DIR}/evaluate.cpp"
  "${SF_SRC_DIR}/memory.cpp"
  "${SF_SRC_DIR}/misc.cpp"
  "${SF_SRC_DIR}/movegen.cpp"
  "${SF_SRC_DIR}/movepick.cpp"
  "${SF_SRC_DIR}/position.cpp"
  "${SF_SRC_DIR}/score.cpp"
  "${SF_SRC_DIR}/search.cpp"
  "${SF_SRC_DIR}/thread.cpp"
  "${SF_SRC_DIR}/timeman.cpp"
  "${SF_SRC_DIR}/tt.cpp"
  "${SF_SRC_DIR}/tune.cpp"
  "${SF_SRC_DIR}/uci.cpp"
  "${SF_SRC_DIR}/ucioption.cpp"
  "${SF_SRC_DIR}/syzygy/tbprobe.cpp"
  "${SF_SRC_DIR}/nnue/nnue_accumulator.cpp"
  "${SF_SRC_DIR}/nnue/nnue_misc.cpp"
  "${SF_SRC_DIR}/nnue/network.cpp"
  "${SF_SRC_DIR}/nnue/features/half_ka_v2_hm.cpp"
  "${SF_SRC_DIR}/nnue/features/full_threats.cpp"
  "${SF_SRC_DIR}/nnue/features/pp_3wide.cpp"
)

add_library(movementor_stockfish SHARED
  stockfish_ffi.cpp
  ${STOCKFISH_CORE_SOURCES}
)

target_include_directories(movementor_stockfish PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${SF_SRC_DIR}"
)

target_compile_definitions(movementor_stockfish PRIVATE
  NDEBUG
  NNUE_EMBEDDING_OFF
)

target_compile_options(movementor_stockfish PRIVATE
  -O3
  -fno-exceptions
  -Wno-deprecated-declarations
)

if(ANDROID)
  if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    target_compile_definitions(movementor_stockfish PRIVATE
      IS_64BIT
      USE_POPCNT
      USE_NEON=8
    )
  elseif(CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
    target_compile_definitions(movementor_stockfish PRIVATE
      USE_POPCNT
      USE_NEON=7
    )
    target_compile_options(movementor_stockfish PRIVATE
      -mthumb
      -march=armv7-a
      -mfloat-abi=softfp
      -mfpu=neon
    )
  elseif(CMAKE_ANDROID_ARCH_ABI STREQUAL "x86_64")
    target_compile_definitions(movementor_stockfish PRIVATE
      IS_64BIT
      USE_SSE2
      USE_SSSE3
      USE_SSE41
      USE_POPCNT
    )
    target_compile_options(movementor_stockfish PRIVATE
      -msse2
      -mssse3
      -msse4.1
      -mpopcnt
    )
  endif()

  # Android 15+ 16 KB ELF page-size alignment compliance
  target_link_options(movementor_stockfish PRIVATE
    "-Wl,-z,max-page-size=16384"
  )
endif()

find_library(ATOMIC_LIB atomic)
find_library(LOG_LIB log)
target_link_libraries(movementor_stockfish PRIVATE
  $<$<BOOL:${ATOMIC_LIB}>:${ATOMIC_LIB}>
  $<$<BOOL:${LOG_LIB}>:${LOG_LIB}>
)
