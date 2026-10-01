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

if(MSVC)
  add_compile_definitions(
    CCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING
    NOMINMAX
    WIN32_LEAN_AND_MEAN)
  add_compile_options(
    $<$<COMPILE_LANGUAGE:C,CXX>:/utf-8>
    $<$<COMPILE_LANGUAGE:C,CXX>:/Zc:preprocessor>)
elseif(WIN32)
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# --- Global settings ---------------------------------------------------------
option(NINFER_BUILD_APPS "Build the NInfer CLI and server" ON)
option(BUILD_TESTING "Build NInfer tests" OFF)
option(NINFER_BUILD_BENCHMARKS "Build NInfer benchmarks" OFF)
option(NINFER_QWEN38_ONLY
  "Build the production Qwen3.8-27B target profile and disable non-target heavy kernels" OFF)

if(NINFER_QWEN38_ONLY)
  if(NOT CMAKE_CUDA_ARCHITECTURES STREQUAL "75")
    message(FATAL_ERROR "NINFER_QWEN38_ONLY is the SM75 production profile")
  endif()
  add_compile_definitions(NINFER_QWEN38_ONLY=1)
  message(STATUS "NInfer profile: Qwen3.8-27B / SM75 production")
endif()

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

# The native Windows SM75 distribution must not depend on a CUDA Toolkit runtime DLL being
# installed on PATH. Other platform/architecture combinations retain the existing shared runtime.
set(NINFER_CUDART_TARGET CUDA::cudart)
if(WIN32 AND CMAKE_CUDA_ARCHITECTURES STREQUAL "75")
  set(CMAKE_CUDA_RUNTIME_LIBRARY Static)
  set(NINFER_CUDART_TARGET CUDA::cudart_static)
endif()

if(WIN32)
  # vcpkg's FFmpeg port provides FindFFMPEG.cmake rather than an upstream
  # package config. Normalize it to the same imported target name used by the
  # Linux/pkg-config path so the rest of the build stays platform-neutral.
  find_package(FFMPEG REQUIRED)
  add_library(PkgConfig::FFMPEG INTERFACE IMPORTED GLOBAL)
  target_include_directories(PkgConfig::FFMPEG INTERFACE ${FFMPEG_INCLUDE_DIRS})
  target_link_directories(PkgConfig::FFMPEG INTERFACE ${FFMPEG_LIBRARY_DIRS})
  target_link_libraries(PkgConfig::FFMPEG INTERFACE ${FFMPEG_LIBRARIES})

  if(NINFER_BUILD_MEDIA_ACQUIRE)
    find_package(CURL 7.85 REQUIRED)
    add_library(PkgConfig::LIBCURL INTERFACE IMPORTED GLOBAL)
    target_link_libraries(PkgConfig::LIBCURL INTERFACE CURL::libcurl)
  endif()
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET
    libavformat>=60 libavcodec>=60 libavutil>=58 libswscale>=7)
  if(NINFER_BUILD_MEDIA_ACQUIRE)
    pkg_check_modules(LIBCURL REQUIRED IMPORTED_TARGET libcurl>=7.85)
  endif()
endif()
find_package(Threads REQUIRED)

# --- Subdirectories ----------------------------------------------------------
add_subdirectory(src)
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
