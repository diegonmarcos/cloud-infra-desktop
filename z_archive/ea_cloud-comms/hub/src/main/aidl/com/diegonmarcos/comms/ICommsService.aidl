// Cloud-Comms IPC — action + push surface.
// Mirrors contract/comms-ipc-v1.json::aidl exactly. The hub IMPLEMENTS this
// (dispatching to the per-fork exporter services); Cloud-SuperApp BINDS it.
// Gated by the signature permission on the <service> declaration — a caller
// signed with a different key gets SecurityException at bind time.
package com.diegonmarcos.comms;

import com.diegonmarcos.comms.ICommsCallback;

interface ICommsService {
    /** Send a message/reply in a thread. Returns false if the domain is
        unconfigured or the owning fork isn't installed. */
    boolean send(String domain, String accountId, String threadId, String body);

    /** Mark a thread read. Returns false on the same conditions as send(). */
    boolean markRead(String domain, String accountId, String threadId);

    /** Deep-link into the owning fork app at the given thread for full content
        (full bodies/renderers never cross the IPC boundary). */
    void openInApp(String domain, String threadId);

    /** Request an immediate sync of one domain ("mail" | "chat" | "matrix"). */
    void forceSync(String domain);

    /** Register for onNewMessage / onSyncStateChanged push callbacks. */
    void registerCallback(ICommsCallback cb);

    void unregisterCallback(ICommsCallback cb);
}
