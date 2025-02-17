#=============================================================================
# Copyright (c) 2020-2022, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#=============================================================================

cmake_minimum_required(VERSION 3.20.1 FATAL_ERROR)
file(DOWNLOAD https://raw.githubusercontent.com/rapidsai/rapids-cmake/branch-22.04/RAPIDS.cmake
    ${CMAKE_BINARY_DIR}/RAPIDS.cmake)
include(${CMAKE_BINARY_DIR}/RAPIDS.cmake)
include(rapids-cmake)
include(rapids-cpm)
include(rapids-cuda)
include(rapids-export)
include(rapids-find)

rapids_cuda_init_architectures(RAFT)

project(RAFT VERSION 22.04.00 LANGUAGES CXX CUDA)

##############################################################################
# - build type ---------------------------------------------------------------

# Set a default build type if none was specified
rapids_cmake_build_type(Release)

# this is needed for clang-tidy runs
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

##############################################################################
# - User Options  ------------------------------------------------------------

option(BUILD_TESTS "Build raft unit-tests" ON)
option(CUDA_ENABLE_KERNELINFO "Enable kernel resource usage info" OFF)
option(CUDA_ENABLE_LINEINFO "Enable the -lineinfo option for nvcc (useful for cuda-memcheck / profiler)" OFF)
option(CUDA_STATIC_RUNTIME "Statically link the CUDA runtime" OFF)
option(DETECT_CONDA_ENV "Enable detection of conda environment for dependencies" ON)
option(DISABLE_DEPRECATION_WARNINGS "Disable depreaction warnings " ON)
option(DISABLE_OPENMP "Disable OpenMP" OFF)
option(NVTX "Enable nvtx markers" OFF)

option(RAFT_COMPILE_LIBRARIES "Enable building raft shared library instantiations" ON)
option(RAFT_COMPILE_NN_LIBRARY "Enable building raft nearest neighbors shared library instantiations" OFF)
option(RAFT_COMPILE_DIST_LIBRARY "Enable building raft distant shared library instantiations" OFF)
option(RAFT_ENABLE_NN_DEPENDENCIES "Search for raft::nn dependencies like faiss" ${RAFT_COMPILE_LIBRARIES})
include(CMakeDependentOption)
cmake_dependent_option(RAFT_USE_FAISS_STATIC "Build and statically link the FAISS library for nearest neighbors search on GPU" ON RAFT_COMPILE_LIBRARIES OFF)

message(VERBOSE "RAFT: Build RAFT unit-tests: ${BUILD_TESTS}")
message(VERBOSE "RAFT: Enable detection of conda environment for dependencies: ${DETECT_CONDA_ENV}")
message(VERBOSE "RAFT: Disable depreaction warnings " ${DISABLE_DEPRECATION_WARNINGS})
message(VERBOSE "RAFT: Disable OpenMP: ${DISABLE_OPENMP}")
message(VERBOSE "RAFT: Enable kernel resource usage info: ${CUDA_ENABLE_KERNELINFO}")
message(VERBOSE "RAFT: Enable lineinfo in nvcc: ${CUDA_ENABLE_LINEINFO}")
message(VERBOSE "RAFT: Enable nvtx markers: ${NVTX}")
message(VERBOSE "RAFT: Statically link the CUDA runtime: ${CUDA_STATIC_RUNTIME}")

# Set RMM logging level
set(RMM_LOGGING_LEVEL "INFO" CACHE STRING "Choose the logging level.")
set_property(CACHE RMM_LOGGING_LEVEL PROPERTY STRINGS "TRACE" "DEBUG" "INFO" "WARN" "ERROR" "CRITICAL" "OFF")
message(VERBOSE "RAFT: RMM_LOGGING_LEVEL = '${RMM_LOGGING_LEVEL}'.")

##############################################################################
# - Conda environment detection ----------------------------------------------

if(DETECT_CONDA_ENV)
  rapids_cmake_support_conda_env( conda_env MODIFY_PREFIX_PATH )
  if (CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT AND DEFINED ENV{CONDA_PREFIX})
      message(STATUS "RAFT: No CMAKE_INSTALL_PREFIX argument detected, setting to: $ENV{CONDA_PREFIX}")
      set(CMAKE_INSTALL_PREFIX "$ENV{CONDA_PREFIX}")
  endif()
endif()

##############################################################################
# - compiler options ---------------------------------------------------------

# * find CUDAToolkit package
# * determine GPU architectures
# * enable the CMake CUDA language
# * set other CUDA compilation flags
rapids_find_package(CUDAToolkit REQUIRED
    BUILD_EXPORT_SET raft-exports
    INSTALL_EXPORT_SET raft-exports
    )
include(cmake/modules/ConfigureCUDA.cmake)

##############################################################################
# - Requirements -------------------------------------------------------------

if (NOT DISABLE_OPENMP)
  find_package(OpenMP)
  if(OPENMP_FOUND)
    message(VERBOSE "RAFT: OpenMP found in ${OpenMP_CXX_INCLUDE_DIRS}")
  endif()
endif()

# add third party dependencies using CPM
rapids_cpm_init()

# thrust before rmm/cuco so we get the right version of thrust/cub
include(cmake/thirdparty/get_thrust.cmake)
include(cmake/thirdparty/get_rmm.cmake)
include(cmake/thirdparty/get_cuco.cmake)
include(cmake/thirdparty/get_libcudacxx.cmake)
include(cmake/thirdparty/get_faiss.cmake)

if(BUILD_TESTS)
  include(cmake/thirdparty/get_gtest.cmake)
  include(cmake/thirdparty/get_nccl.cmake)
  include(cmake/thirdparty/get_ucx.cmake)
endif()

##############################################################################
# - raft ---------------------------------------------------------------------

add_library(raft INTERFACE)
add_library(raft::raft ALIAS raft)

target_include_directories(raft INTERFACE
        "$<BUILD_INTERFACE:${RAFT_SOURCE_DIR}/include>"
        "$<INSTALL_INTERFACE:include>")

target_link_libraries(raft INTERFACE
  raft::Thrust
  CUDA::cublas
  CUDA::curand
  CUDA::cusolver
  CUDA::cudart
  CUDA::cusparse
  $<$<BOOL:${NVTX}>:CUDA::nvToolsExt>
  rmm::rmm
  cuco::cuco)

target_compile_definitions(raft INTERFACE $<$<BOOL:${NVTX}>:NVTX_ENABLED>)
target_compile_features(raft INTERFACE cxx_std_17 $<BUILD_INTERFACE:cuda_std_17>)

if(RAFT_COMPILE_LIBRARIES OR RAFT_COMPILE_DIST_LIBRARY OR RAFT_COMPILE_NN_LIBRARY)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/fatbin.ld"
[=[
SECTIONS
{
.nvFatBinSegment : { *(.nvFatBinSegment) }
.nv_fatbin : { *(.nv_fatbin) }
}
]=])
endif()
##############################################################################
# - raft_distance ------------------------------------------------------------
add_library(raft_distance INTERFACE)

if(TARGET raft_distance AND (NOT TARGET raft::distance))
  add_library(raft::distance ALIAS raft_distance)
endif()

set_target_properties(raft_distance PROPERTIES EXPORT_NAME distance)

if(RAFT_COMPILE_LIBRARIES OR RAFT_COMPILE_DIST_LIBRARY)
  add_library(raft_distance_lib SHARED
    src/distance/specializations/detail
    src/distance/specializations/detail/canberra.cu
    src/distance/specializations/detail/chebyshev.cu
    src/distance/specializations/detail/correlation.cu
    src/distance/specializations/detail/cosine.cu
    src/distance/specializations/detail/hamming_unexpanded.cu
    src/distance/specializations/detail/hellinger_expanded.cu
    src/distance/specializations/detail/jensen_shannon_float_float_float_int.cu
    src/distance/specializations/detail/jensen_shannon_float_float_float_uint32.cu
    src/distance/specializations/detail/jensen_shannon_double_double_double_int.cu
    src/distance/specializations/detail/kl_divergence_float_float_float_int.cu
    src/distance/specializations/detail/kl_divergence_float_float_float_uint32.cu
    src/distance/specializations/detail/kl_divergence_double_double_double_int.cu
    src/distance/specializations/detail/l1_float_float_float_int.cu
    src/distance/specializations/detail/l1_float_float_float_uint32.cu
    src/distance/specializations/detail/l1_double_double_double_int.cu
    src/distance/specializations/detail/l2_expanded_float_float_float_int.cu
    src/distance/specializations/detail/l2_expanded_float_float_float_uint32.cu
    src/distance/specializations/detail/l2_expanded_double_double_double_int.cu
    src/distance/specializations/detail/l2_sqrt_expanded_float_float_float_int.cu
    src/distance/specializations/detail/l2_sqrt_expanded_float_float_float_uint32.cu
    src/distance/specializations/detail/l2_sqrt_expanded_double_double_double_int.cu
    src/distance/specializations/detail/l2_sqrt_unexpanded_float_float_float_int.cu
    src/distance/specializations/detail/l2_sqrt_unexpanded_float_float_float_uint32.cu
    src/distance/specializations/detail/l2_sqrt_unexpanded_double_double_double_int.cu
    src/distance/specializations/detail/l2_unexpanded_double_double_double_int.cu
    src/distance/specializations/detail/l2_unexpanded_float_float_float_uint32.cu
    src/distance/specializations/detail/l2_unexpanded_float_float_float_int.cu
    src/distance/specializations/detail/lp_unexpanded_double_double_double_int.cu
    src/distance/specializations/detail/lp_unexpanded_float_float_float_uint32.cu
    src/distance/specializations/detail/lp_unexpanded_float_float_float_int.cu
  )
  set_target_properties(raft_distance_lib PROPERTIES OUTPUT_NAME raft_distance)

  target_link_libraries(raft_distance_lib PRIVATE raft::raft)
  target_compile_options(raft_distance_lib
          PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${RAFT_CXX_FLAGS}>"
          "$<$<COMPILE_LANGUAGE:CUDA>:${RAFT_CUDA_FLAGS}>"
          )
  target_compile_definitions(raft_distance_lib
          INTERFACE "RAFT_DISTANCE_COMPILED")

  # ensure CUDA symbols aren't relocated to the middle of the debug build binaries
  target_link_options(raft_distance_lib PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/fatbin.ld")

endif()

target_link_libraries(raft_distance INTERFACE raft::raft
    $<TARGET_NAME_IF_EXISTS:raft_distance_lib>
    $<TARGET_NAME_IF_EXISTS:raft::raft_distance_lib>
)

##############################################################################
# - raft_nn ------------------------------------------------------------------
add_library(raft_nn INTERFACE)

if(TARGET raft_nn AND (NOT TARGET raft::nn))
  add_library(raft::nn ALIAS raft_nn)
endif()

set_target_properties(raft_nn PROPERTIES EXPORT_NAME nn)

if(RAFT_COMPILE_LIBRARIES OR RAFT_COMPILE_NN_LIBRARY)
  add_library(raft_nn_lib SHARED
    src/nn/specializations/ball_cover.cu
    src/nn/specializations/detail/ball_cover_lowdim.cu
    src/nn/specializations/fused_l2_knn_long_float_true.cu
    src/nn/specializations/fused_l2_knn_long_float_false.cu
    src/nn/specializations/fused_l2_knn_int_float_true.cu
    src/nn/specializations/fused_l2_knn_int_float_false.cu
    src/nn/specializations/knn.cu
  )
  set_target_properties(raft_nn_lib PROPERTIES OUTPUT_NAME raft_nn)

  target_link_libraries(raft_nn_lib PRIVATE raft::raft faiss::faiss)
  target_compile_options(raft_nn_lib
          PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${RAFT_CXX_FLAGS}>"
          "$<$<COMPILE_LANGUAGE:CUDA>:${RAFT_CUDA_FLAGS}>"
          )
  # ensure CUDA symbols aren't relocated to the middle of the debug build binaries
  target_link_options(raft_nn_lib PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/fatbin.ld")

  target_compile_definitions(raft_nn_lib
          INTERFACE "RAFT_NN_COMPILED")

endif()

target_link_libraries(raft_nn INTERFACE raft::raft faiss::faiss
    $<TARGET_NAME_IF_EXISTS:raft_nn_lib>
    $<TARGET_NAME_IF_EXISTS:raft::raft_nn_lib>)

##############################################################################
# - install targets-----------------------------------------------------------
rapids_cmake_install_lib_dir( lib_dir )
include(GNUInstallDirs)
include(CPack)

install(TARGETS raft
        DESTINATION ${lib_dir}
        EXPORT raft-exports)
install(TARGETS raft_distance
        DESTINATION ${lib_dir}
        EXPORT raft-distance-exports)
install(TARGETS raft_nn
        DESTINATION ${lib_dir}
        EXPORT raft-nn-exports)

if(TARGET raft_distance_lib)
  install(TARGETS raft_distance_lib
          DESTINATION ${lib_dir}
          EXPORT raft-distance-exports)
endif()

if(TARGET raft_nn_lib)
  install(TARGETS raft_nn_lib
          DESTINATION ${lib_dir}
          EXPORT raft-nn-exports)
endif()


install(DIRECTORY include/raft/
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/raft
        )

# Temporary install of raft.hpp while the file is removed
install(FILES include/raft.hpp
	DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/raft)

##############################################################################
# - install export -----------------------------------------------------------
set(doc_string
[=[
Provide targets for the RAFT: RAPIDS Analytics Framework Toolkit.

RAPIDS Analytics Framework Toolkit contains shared representations,
mathematical computational primitives, and utilities that accelerate
building analytics and data science algorithms in the RAPIDS ecosystem.

Optional Components:
  - nn
  - distance

Imported Targets:
  - raft::raft
  - raft::nn brought in by the `nn` optional component
  - raft::distance brought in by the `distance` optional component

]=])

set(code_string
[=[
thrust_create_target(raft::Thrust FROM_OPTIONS)

if(distance IN_LIST raft_FIND_COMPONENTS)
  enable_language(CUDA)
endif()

if(nn IN_LIST raft_FIND_COMPONENTS)
  enable_language(CUDA)

  if(TARGET faiss AND (NOT TARGET faiss::faiss))
      add_library(faiss::faiss ALIAS faiss)
  elseif(TARGET faiss::faiss AND (NOT TARGET faiss))
      add_library(faiss ALIAS faiss::faiss)
  endif()
endif()
]=]
)

# Use `rapids_export` for 22.04 as it will have COMPONENT support
include(cmake/modules/raft_export.cmake)
raft_export(INSTALL raft
    EXPORT_SET raft-exports
    COMPONENTS nn distance
    GLOBAL_TARGETS raft nn distance
    NAMESPACE raft::
    DOCUMENTATION doc_string
    FINAL_CODE_BLOCK code_string
    )

##############################################################################
# - build export -------------------------------------------------------------

raft_export(BUILD raft
    EXPORT_SET raft-exports
    COMPONENTS nn distance
    GLOBAL_TARGETS raft raft_distance raft_nn
    DOCUMENTATION doc_string
    NAMESPACE raft::
    FINAL_CODE_BLOCK code_string
    )

##############################################################################
# - export/install optional components  --------------------------------------

include("${rapids-cmake-dir}/export/write_dependencies.cmake")

set(raft_components distance nn)
foreach(comp IN LISTS raft_components)
  install(
    EXPORT raft-${comp}-exports
    FILE raft-${comp}-targets.cmake
    NAMESPACE raft::
    DESTINATION "${lib_dir}/cmake/raft"
  )
  export(
    EXPORT raft-${comp}-exports
    FILE ${RAFT_BINARY_DIR}/raft-${comp}-targets.cmake
    NAMESPACE raft::
  )
  rapids_export_write_dependencies(
    BUILD raft-${comp}-exports "${PROJECT_BINARY_DIR}/raft-${comp}-dependencies.cmake"
  )
  rapids_export_write_dependencies(
    INSTALL raft-${comp}-exports "${PROJECT_BINARY_DIR}/rapids-cmake/raft/export/raft-${comp}-dependencies.cmake"
  )

endforeach()

##############################################################################
# - build test executable ----------------------------------------------------

if(BUILD_TESTS)
  include(test/CMakeLists.txt)
endif()

##############################################################################
# - doxygen targets ----------------------------------------------------------

include(cmake/doxygen.cmake)
add_doxygen_target(IN_DOXYFILE doxygen/Doxyfile.in
  OUT_DOXYFILE ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile
  CWD ${CMAKE_CURRENT_BINARY_DIR})
