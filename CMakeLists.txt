cmake_minimum_required(VERSION 3.28)

# Supported architectures: 75 (Turing), 86 (Ampere), 120a (Blackwell)
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 75 CACHE STRING "CUDA architectures to build")
endif()
if(NOT (CMAKE_CUDA_ARCHITECTURES STREQUAL "75" OR
        CMAKE_CUDA_ARCHITECTURES STREQUAL "86" OR
        CMAKE_CUDA_ARCHITECTURES STREQUAL "120a"))
  message(FATAL_ERROR
    "NInfer supports only CMAKE_CUDA_ARCHITECTURES=75, 86, or 120a; got "
    "'${CMAKE_CUDA_ARCHITECTURES}'")
endif()

project(ninfer-2080ti-22g LANGUAGES C CXX CUDA)

# --- Global settings ---------------------------------------------------------
option(NINFER_BUILD_APPS "Build the NInfer CLI and server" ON)
option(BUILD_TESTING "Build NInfer tests" OFF)
option(NINFER_BUILD_BENCHMARKS "Build NInfer benchmarks" OFF)
option(NINFER_CUDA_WHOLE_PROGRAM
  "Disable relocatable CUDA device code for whole-program ptxas optimization" OFF)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 20)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)        # clangd / IDE tooling
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

if(CMAKE_GENERATOR MATCHES "Ninja")
  set_property(GLOBAL PROPERTY JOB_POOLS cuda_link=1)
  set(CMAKE_JOB_POOL_LINK cuda_link)
endif()

if(CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 12.8)
  message(FATAL_ERROR
    "NInfer requires CUDA 12.8 or newer; found CUDA compiler "
    "${CMAKE_CUDA_COMPILER_VERSION}")
endif()

if(CMAKE_CUDA_ARCHITECTURES STREQUAL "75")
  add_compile_definitions(NINFER_SM75=1)
elseif(CMAKE_CUDA_ARCHITECTURES STREQUAL "86")
  add_compile_definitions(NINFER_SM86=1)
elseif(CMAKE_CUDA_ARCHITECTURES STREQUAL "120a")
  add_compile_definitions(NINFER_SM120A=1)
endif()

set(NINFER_BUILD_MEDIA_ACQUIRE OFF)
if(NINFER_BUILD_APPS OR BUILD_TESTING)
  set(NINFER_BUILD_MEDIA_ACQUIRE ON)
endif()

set(NINFER_BUILD_PROMPT_INPUT OFF)
if(NINFER_BUILD_APPS)
  set(NINFER_BUILD_PROMPT_INPUT ON)
endif()

set(NINFER_BUILD_SERVE OFF)
if(NINFER_BUILD_APPS OR BUILD_TESTING)
  set(NINFER_BUILD_SERVE ON)
endif()

find_package(CUDAToolkit REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET
  libavformat>=60 libavcodec>=60 libavutil>=58 libswscale>=7)
if(NINFER_BUILD_MEDIA_ACQUIRE)
  pkg_check_modules(LIBCURL REQUIRED IMPORTED_TARGET libcurl>=7.85)
endif()
find_package(Threads REQUIRED)

# --- Subdirectories ----------------------------------------------------------
add_subdirectory(src)

# The decode-shaped W8 GEMV cores are a Turing-only route measured on RTX 2080 Ti. Keep the
# generic source manifest unchanged for SM86/SM120a and add these launchers only to the SM75
# archive where the dispatch table can select them.
if(CMAKE_CUDA_ARCHITECTURES STREQUAL "75")
  target_sources(ninfer_ops PRIVATE
    src/ops/linear/w8/w8_decode_gemv.cu)
endif()

# NInfer currently has no cross-translation-unit device calls, device function pointers, dynamic
# parallelism, or external device/constant definitions. Keep the established RDC build as the
# default, but expose a controlled A/B mode for SM75 resource audits and WSL2 ptxas qualification.
# The option is applied after src creates the targets so it overrides their archive defaults without
# changing the normal build path.
if(NINFER_CUDA_WHOLE_PROGRAM)
  foreach(target IN ITEMS ninfer_core ninfer_ops)
    if(TARGET ${target})
      set_target_properties(${target} PROPERTIES
        CUDA_SEPARABLE_COMPILATION OFF
        CUDA_RESOLVE_DEVICE_SYMBOLS OFF)
    endif()
  endforeach()
  message(STATUS "NInfer CUDA whole-program mode enabled (RDC disabled for core/ops)")
endif()

if(NINFER_BUILD_APPS)
  add_subdirectory(apps)
endif()
if(BUILD_TESTING)
  enable_testing()
  add_subdirectory(tests)
endif()
if(NINFER_BUILD_BENCHMARKS)
  add_subdirectory(bench)
endif()
