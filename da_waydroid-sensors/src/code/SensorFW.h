/*
 * SensorFW.h — IIO-backed reimplementation of the Waydroid sensors data source.
 *
 * Drop-in replacement for droidian/waydroid-sensors' SensorFW (which sourced data
 * from a sensorfwd Qt daemon, unavailable on NixOS). This version reads the host's
 * Linux IIO accelerometer (/sys/bus/iio) directly. The class name and the method
 * surface consumed by Sensors.cpp/service.cpp are preserved verbatim so those upstream
 * files compile UNCHANGED. The ID/macro block below is kept verbatim from upstream.
 *
 * Original SensorFW © 2021 Waydroid Project (Erfan Abdi), GPL-3.0.
 * IIO data source © 2026 Diego Nepomuceno Marcos, GPL-3.0.
 */

#ifndef SENSORHW_H_
#define SENSORHW_H_

#include <stdint.h>
#include <glib.h>
#include <string>
#include <vector>   // Sensors.cpp/service.cpp rely on this via SensorFW.h (upstream did too)

namespace waydroid {

#define MAX_NUM_SENSORS 11

#define SUPPORTED_SENSORS  ((1<<MAX_NUM_SENSORS)-1)

#define  ID_BASE                        0
#define  ID_ACCELEROMETER               (ID_BASE+0)
#define  ID_GYROSCOPE                   (ID_BASE+1)
#define  ID_HUMIDITY                    (ID_BASE+2)
#define  ID_LIGHT                       (ID_BASE+3)
#define  ID_MAGNETIC_FIELD              (ID_BASE+4)
#define  ID_MAGNETIC_FIELD_UNCALIBRATED (ID_BASE+5)
#define  ID_DEVICE_ORIENTATION          (ID_BASE+6)
#define  ID_PRESSURE                    (ID_BASE+7)
#define  ID_PROXIMITY                   (ID_BASE+8)
#define  ID_STEPCOUNTER                 (ID_BASE+9)
#define  ID_TEMPERATURE                 (ID_BASE+10)

#define  SENSORS_ACCELEROMETER                (1 << ID_ACCELEROMETER)
#define  SENSORS_GYROSCOPE                    (1 << ID_GYROSCOPE)
#define  SENSORS_HUMIDITY                     (1 << ID_HUMIDITY)
#define  SENSORS_LIGHT                        (1 << ID_LIGHT)
#define  SENSORS_MAGNETIC_FIELD               (1 << ID_MAGNETIC_FIELD)
#define  SENSORS_MAGNETIC_FIELD_UNCALIBRATED  (1 << ID_MAGNETIC_FIELD_UNCALIBRATED)
#define  SENSORS_DEVICE_ORIENTATION           (1 << ID_DEVICE_ORIENTATION)
#define  SENSORS_PRESSURE                     (1 << ID_PRESSURE)
#define  SENSORS_PROXIMITY                    (1 << ID_PROXIMITY)
#define  SENSORS_STEPCOUNTER                  (1 << ID_STEPCOUNTER)
#define  SENSORS_TEMPERATURE                  (1 << ID_TEMPERATURE)

#define  ID_CHECK(x)  ((unsigned)((x) - ID_BASE) < MAX_NUM_SENSORS)

#define  SENSORS_LIST  \
    SENSOR_(ACCELEROMETER,"accelerometer") \
    SENSOR_(GYROSCOPE,"gyroscope") \
    SENSOR_(HUMIDITY, "humidity") \
    SENSOR_(LIGHT, "light") \
    SENSOR_(MAGNETIC_FIELD,"magnetic-field") \
    SENSOR_(MAGNETIC_FIELD_UNCALIBRATED,"magnetic-field-uncalibrated") \
    SENSOR_(DEVICE_ORIENTATION,"device-orientation") \
    SENSOR_(PRESSURE, "pressure") \
    SENSOR_(PROXIMITY,"proximity") \
    SENSOR_(STEPCOUNTER, "stepcounter") \
    SENSOR_(TEMPERATURE,"temperature")

static const struct {
    const char*  name;
    int          id; } _sensorIds[MAX_NUM_SENSORS] =
{
#define SENSOR_(x,y)  { y, ID_##x },
    SENSORS_LIST
#undef  SENSOR_
};

static inline const char* _SensorIdToName(int id) {
    int nn;
    for (nn = 0; nn < MAX_NUM_SENSORS; nn++)
        if (id == _sensorIds[nn].id)
            return _sensorIds[nn].name;
    return "<UNKNOWN>";
}

typedef void (*sensor_event_cb_t)(void *userdata, int id);

/* Per-axis remap: Android axis = sign * (one of the raw IIO x/y/z channels).
 * Resolves the device mount matrix declaratively (see build.json -> iio.mount). */
struct AxisMap { int src; int sign; };   // src: 0=x 1=y 2=z

struct SensorFW {
    SensorFW();
    ~SensorFW();

    /* Surface consumed by Sensors.cpp / service.cpp — DO NOT change signatures. */
    void RegisterSensors(sensor_event_cb_t cb, void *userdata);
    bool IsSensorAvailable(int id);
    bool IsSensorEventEnable(int id);
    int  EnableSensorEvents(int id);
    int  DisableSensorEvents(int id);

    /* x,y,z are returned in centi-m/s^2 (Sensors.cpp divides by 100.0f). */
    int GetAccelerometerEvent(uint64_t *ts, int *x, int *y, int *z);
    int GetGyroscopeEvent(uint64_t *ts, int *x, int *y, int *z);
    int GetHumidityEvent(uint64_t *ts, unsigned *value);
    int GetLightEvent(uint64_t *ts, unsigned *value);
    int GetMagnetometerEvent(uint64_t *ts, int *x, int *y, int *z,
        int *rx, int *ry, int *rz, int* level);
    int GetOrientationEvent(uint64_t *ts, int *degree);
    int GetPressureEvent(uint64_t *ts, unsigned *value);
    int GetProximityEvent(uint64_t *ts, unsigned *value, bool *isNear);
    int GetStepcounterEvent(uint64_t *ts, unsigned *value);
    int GetTemperatureEvent(uint64_t *ts, unsigned *value);

    /* Called by the GLib timeout to sample IIO and notify Sensors via the cb. */
    void pollOnce();

    /* Upper bound (ms) for Sensors::poll()'s blocking wait — data-driven from the
     * conf (POLL_WAIT_MS). Sensors.cpp reads this so an absent/idle sensor source
     * can never deadlock SensorService init (Waydroid boot hang). */
    int GetPollWaitMs() const { return mPollWaitMs; }

private:
    bool loadConfig();          // parse KEY=VALUE conf (env WAYDROID_SENSORS_CONF)
    bool resolveAccelDevice();  // find /sys/bus/iio device by name, read scale
    bool readAccelRaw(double *ax, double *ay, double *az); // m/s^2, axis-remapped

    sensor_event_cb_t mCb = nullptr;
    void* mUserdata = nullptr;
    guint mTimerId = 0;

    bool mAvailable[MAX_NUM_SENSORS] = { false };
    bool mEnabled[MAX_NUM_SENSORS]   = { false };

    /* accelerometer (IIO) config + state */
    std::string mIioName = "accel_3d";
    std::string mAccelPath;     // resolved /sys/bus/iio/devices/iio:deviceN
    double mAccelScale = 1.0;   // raw * scale -> m/s^2
    int    mPollMs = 200;
    int    mPollWaitMs = 3000;  // poll() blocking-wait ceiling (conf POLL_WAIT_MS)
    AxisMap mMap[3] = { {0,+1}, {1,+1}, {2,+1} };  // x,y,z passthrough by default
    int    mAccelX = 0, mAccelY = 0, mAccelZ = 0;  // centi-m/s^2
    uint64_t mAccelTs = 0;
};

}  // namespace waydroid

#endif  // SENSORHW_H_
