cmake_minimum_required(VERSION 3.13)
project(waydroid-sensors CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)

pkg_check_modules(GIO      REQUIRED gio-2.0)
pkg_check_modules(GIO_UNIX REQUIRED gio-unix-2.0)
pkg_check_modules(GLIB     REQUIRED glib-2.0)
pkg_check_modules(GLIB_UTIL REQUIRED libglibutil)
pkg_check_modules(GBINDER  REQUIRED libgbinder>=1.1.20)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -pthread")

# Upstream gbinder/HIDL @1.0 ISensors layer (verbatim) + IIO data source (ours).
add_executable(waydroid-sensord
    SensorFW.cpp     # IIO-backed data source (replaces upstream sensorfw source)
    Sensors.cpp      # verbatim upstream — ISensors@1.0 poll model
    service.cpp      # verbatim upstream — gbinder service registration
)

target_include_directories(waydroid-sensord PUBLIC
    ${GIO_INCLUDE_DIRS} ${GIO_UNIX_INCLUDE_DIRS} ${GLIB_INCLUDE_DIRS}
    ${GLIB_UTIL_INCLUDE_DIRS} ${GBINDER_INCLUDE_DIRS}
)
target_link_libraries(waydroid-sensord PUBLIC
    ${GIO_LDFLAGS} ${GIO_LIBRARIES}
    ${GIO_UNIX_LDFLAGS} ${GIO_UNIX_LIBRARIES}
    ${GLIB_LDFLAGS} ${GLIB_LIBRARIES}
    ${GLIB_UTIL_LDFLAGS} ${GLIB_UTIL_LIBRARIES}
    ${GBINDER_LDFLAGS} ${GBINDER_LIBRARIES}
)

install(TARGETS waydroid-sensord RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
