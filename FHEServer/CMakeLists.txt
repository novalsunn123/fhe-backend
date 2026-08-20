cmake_minimum_required(VERSION 3.5.1)
project(FHEServer)
set(CMAKE_CXX_STANDARD 17)

find_package(OpenFHE CONFIG REQUIRED)
set(CMAKE_CXX_FLAGS ${OpenFHE_CXX_FLAGS})
include_directories(${OPENMP_INCLUDES})
include_directories(${OpenFHE_INCLUDE})
include_directories(${OpenFHE_INCLUDE}/third-party/include)
include_directories(${OpenFHE_INCLUDE}/core)
include_directories(${OpenFHE_INCLUDE}/pke)
include_directories(${OpenFHE_INCLUDE}/binfhe)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../Common)
link_directories(${OpenFHE_LIBDIR})
link_directories(${OPENMP_LIBRARIES})
set(CMAKE_EXE_LINKER_FLAGS ${OpenFHE_EXE_LINKER_FLAGS})
link_libraries(${OpenFHE_SHARED_LIBRARIES})

add_executable(FHEServer
        src/main.cpp
        src/BatchPolicy.cpp
        src/BatchPolicy.h
        src/FHEController.cpp
        src/FHEController.h
        src/PackedWeights.cpp
        src/PackedWeights.h
        src/Profiler.cpp
        src/Profiler.h
        src/Utils.h)

add_executable(FHEWeightPacker
        tools/PackWeights.cpp
        src/PackedWeights.cpp
        src/PackedWeights.h)
target_include_directories(FHEWeightPacker PRIVATE src)

set(PACKED_WEIGHTS_FILE "${CMAKE_CURRENT_BINARY_DIR}/packed-weights.bin")
file(GLOB TEXT_WEIGHT_FILES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/weights/*.bin")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/weights/fc.bin")
    add_custom_command(
            OUTPUT "${PACKED_WEIGHTS_FILE}"
            COMMAND $<TARGET_FILE:FHEWeightPacker>
                    "${CMAKE_CURRENT_SOURCE_DIR}/weights"
                    "${PACKED_WEIGHTS_FILE}"
            DEPENDS FHEWeightPacker ${TEXT_WEIGHT_FILES}
            COMMENT "Packing text model weights into one binary archive"
            VERBATIM)
    add_custom_target(FHEServerPackedWeights ALL DEPENDS "${PACKED_WEIGHTS_FILE}")
    add_dependencies(FHEServer FHEServerPackedWeights)
else()
    message(WARNING "FHEServer/weights is unavailable; binary weight archive will not be generated")
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(FHEServerProfilerSmokeTest
            tests/ProfilerSmokeTest.cpp
            src/Profiler.cpp
            src/Profiler.h)
    target_include_directories(FHEServerProfilerSmokeTest PRIVATE src)
    add_test(NAME FHEServerProfilerSmokeTest
            COMMAND FHEServerProfilerSmokeTest
                    ${CMAKE_CURRENT_BINARY_DIR}/profiler-smoke-report)
    add_test(NAME FHEServerProfilerDisabledTest
            COMMAND FHEServerProfilerSmokeTest
                    ${CMAKE_CURRENT_BINARY_DIR}/profiler-disabled-report disabled)

    add_executable(FHEServerPackedWeightsTest
            tests/PackedWeightsTest.cpp
            src/PackedWeights.cpp
            src/PackedWeights.h)
    target_include_directories(FHEServerPackedWeightsTest PRIVATE src)
    add_test(NAME FHEServerPackedWeightsTest
            COMMAND FHEServerPackedWeightsTest
                    ${CMAKE_CURRENT_BINARY_DIR}/packed-weights-test)

    add_executable(FHEServerBatchPolicyTest
            tests/BatchPolicyTest.cpp
            src/BatchPolicy.cpp
            src/BatchPolicy.h)
    target_include_directories(FHEServerBatchPolicyTest PRIVATE src)
    add_test(NAME FHEServerBatchPolicyTest COMMAND FHEServerBatchPolicyTest)
endif()
