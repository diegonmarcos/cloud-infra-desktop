// Cloud-Comms IPC — push callback interface.
// Mirrors contract/comms-ipc-v1.json::aidl.callbacks. SuperApp implements this
// and registers it via ICommsService.registerCallback; the hub invokes it when
// a fork reports a new message or a sync-state transition.
package com.diegonmarcos.comms;

oneway interface ICommsCallback {
    void onNewMessage(String domain, String threadId);
    void onSyncStateChanged(String domain, String state);
}
