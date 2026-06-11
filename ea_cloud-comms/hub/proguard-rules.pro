# Hub is not minified (build.json release.minifyEnabled=false), so this file is
# a placeholder for parity with the gradle config. Keep the AIDL stubs + the
# ContentProvider/Service entry points if minification is ever enabled.
-keep class com.diegonmarcos.comms.ICommsService { *; }
-keep class com.diegonmarcos.comms.ICommsCallback { *; }
-keep class com.diegonmarcos.comms.CommsProvider { *; }
-keep class com.diegonmarcos.comms.CommsService { *; }
