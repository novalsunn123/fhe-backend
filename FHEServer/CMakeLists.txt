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
link_directories(${OpenFHE_LIBDIR})
link_directories(${OPENMP_LIBRARIES})
set(CMAKE_EXE_LINKER_FLAGS ${OpenFHE_EXE_LINKER_FLAGS})
link_libraries(${OpenFHE_SHARED_LIBRARIES})

add_executable(FHEServer
        src/main.cpp
        src/FHEController.cpp
        src/FHEController.h
        src/Profiler.cpp
        src/Profiler.h
        src/Utils.h)

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
endif()
