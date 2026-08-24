// Mesh — the WireGuard peers, and reading another peer's watchdog snapshot.
//
// WHY NOT `wg show`
// The obvious source for peer state is wg(8), and it is unavailable: the
// interface is root-owned, so an unprivileged panel gets "Operation not
// permitted" for wg0 and wg-public alike. Running the dash as root to read a
// handshake timestamp is not a trade worth making.
//
// ~/.ssh/config is the better source anyway. It is already the declarative
// list of who is on the mesh, it is maintained because people ssh with it,
// and — unlike wg — it carries the one thing the remote-target feature needs:
// the alias to connect BY. So the peer table is derived from it, and liveness
// is measured directly with a TCP connect rather than inferred from a
// handshake counter we cannot read.
//
// Both the probe and the remote fetch run on their own threads. The render
// loop ticks at 1s and a peer that is merely down costs a full connect
// timeout, so doing either inline would stall the whole UI on exactly the
// case it exists to show.
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

/// How long a peer gets to answer before it counts as down. Mesh RTTs here are
/// single-digit milliseconds; anything past this is not "slow", it is gone.
const PROBE_TIMEOUT: Duration = Duration::from_millis(900);
const PROBE_PORT: u16 = 22;
const PROBE_EVERY: Duration = Duration::from_secs(5);
const FETCH_EVERY: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, Default)]
pub struct Peer {
    pub alias: String,
    pub ip: String,
    pub up: bool,
    pub rtt_ms: f64,
    /// False until the first probe lands, so a fresh panel shows "…" rather
    /// than reporting every peer down before it has asked any of them.
    pub probed: bool,
}

/// Mesh peers from ~/.ssh/config, one row per ADDRESS rather than per Host.
///
/// The config lists several aliases per machine (`oci-apps`, its -dropbear
/// twin, its -pub and -v6 addresses). Keyed by address and keeping the
/// shortest alias, that collapses to one row per way in, which is what a peer
/// list should show — and the shortest alias is invariably the plain one, the
/// one that works for a normal ssh.
pub fn peers_from_ssh_config() -> Vec<Peer> {
    let Some(home) = std::env::var_os("HOME") else { return vec![] };
    let path = std::path::Path::new(&home).join(".ssh/config");
    let Ok(text) = std::fs::read_to_string(path) else { return vec![] };

    let mut by_ip: BTreeMap<String, String> = BTreeMap::new();
    let mut host: Option<String> = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = strip_key(t, "Host") {
            host = rest.split_whitespace().next().map(|s| s.to_string());
        } else if let Some(rest) = strip_key(t, "HostName") {
            let Some(addr) = rest.split_whitespace().next() else { continue };
            if !is_mesh_addr(addr) {
                continue;
            }
            let Some(h) = host.clone() else { continue };
            by_ip
                .entry(addr.to_string())
                .and_modify(|cur| {
                    if h.len() < cur.len() {
                        *cur = h.clone();
                    }
                })
                .or_insert(h);
        }
    }
    by_ip
        .into_iter()
        .map(|(ip, alias)| Peer { alias, ip, ..Default::default() })
        .collect()
}

/// Case-insensitive `Key value` match. ssh_config keywords are not
/// case-sensitive and people really do write `hostname`.
fn strip_key<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let (k, rest) = line.trim().split_once(|c: char| c.is_whitespace() || c == '=')?;
    if k.eq_ignore_ascii_case(key) { Some(rest.trim()) } else { None }
}

/// Mesh addresses only — the private WireGuard ranges this fleet uses. A
/// HostName of `github.com` is a real ssh target and not a peer, and putting
/// it in the mesh box would be a lie about what the mesh is.
fn is_mesh_addr(a: &str) -> bool {
    a.starts_with("10.0.0.") || a.starts_with("10.1.0.") || a.starts_with("fd0c:")
}

/// One TCP connect, timed. Reachability that the kernel actually confirmed —
/// a SYN/ACK from the peer's sshd — rather than a config file's opinion.
fn probe(ip: &str) -> Option<f64> {
    let addr: IpAddr = ip.parse().ok()?;
    let sock = SocketAddr::new(addr, PROBE_PORT);
    let t0 = Instant::now();
    TcpStream::connect_timeout(&sock, PROBE_TIMEOUT).ok()?;
    Some(t0.elapsed().as_secs_f64() * 1000.0)
}

/// Shared, cheap to clone, and the only thing the UI touches.
#[derive(Clone)]
pub struct Mesh {
    pub peers: Arc<Mutex<Vec<Peer>>>,
    /// None = measure this machine. Some(alias) = measure that peer.
    target: Arc<Mutex<Option<String>>>,
    /// The remote snapshot, plus whatever went wrong getting it. Null until
    /// the first fetch returns; the error is kept so a remote that cannot be
    /// read says why instead of just showing stale local numbers.
    remote: Arc<Mutex<(Value, String)>>,
}

impl Mesh {
    /// Starts both workers. They run for the life of the process and are
    /// detached on purpose: there is nothing to join, and a panel that has to
    /// shut threads down cleanly on quit is machinery for no benefit.
    pub fn start() -> Mesh {
        let m = Mesh {
            peers: Arc::new(Mutex::new(peers_from_ssh_config())),
            target: Arc::new(Mutex::new(None)),
            remote: Arc::new(Mutex::new((Value::Null, String::new()))),
        };

        let peers = m.peers.clone();
        std::thread::spawn(move || loop {
            // Snapshot the list, probe outside the lock, write back. Holding
            // it across a 900ms connect would block every render.
            let list: Vec<Peer> = peers.lock().map(|p| p.clone()).unwrap_or_default();
            for mut p in list {
                let rtt = probe(&p.ip);
                p.up = rtt.is_some();
                p.rtt_ms = rtt.unwrap_or(0.0);
                p.probed = true;
                if let Ok(mut cur) = peers.lock() {
                    if let Some(slot) = cur.iter_mut().find(|x| x.ip == p.ip) {
                        *slot = p;
                    }
                }
            }
            std::thread::sleep(PROBE_EVERY);
        });

        let target = m.target.clone();
        let remote = m.remote.clone();
        std::thread::spawn(move || loop {
            let t = target.lock().ok().and_then(|x| x.clone());
            if let Some(alias) = t {
                let out = super::sh_timeout(
                    8,
                    &format!(
                        "ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new {alias} \
                         'cat \"${{XDG_RUNTIME_DIR:-/run/user/$(id -u)}}/my-konsole-watchdog.json\"'"
                    ),
                );
                let parsed: Value = serde_json::from_str(out.trim()).unwrap_or(Value::Null);
                let err = if parsed.is_null() {
                    // The remote answering with nothing is the common case and
                    // has exactly one cause worth naming.
                    format!("{alias}: no snapshot — is my-konsole-tray running there?")
                } else {
                    String::new()
                };
                if let Ok(mut slot) = remote.lock() {
                    *slot = (parsed, err);
                }
            }
            std::thread::sleep(FETCH_EVERY);
        });

        m
    }

    pub fn target(&self) -> Option<String> {
        self.target.lock().ok().and_then(|t| t.clone())
    }

    /// Switching target clears the last remote snapshot, so the panel cannot
    /// spend a couple of seconds showing one machine's numbers under another
    /// machine's name.
    pub fn set_target(&self, alias: Option<String>) {
        if let Ok(mut t) = self.target.lock() {
            *t = alias;
        }
        if let Ok(mut r) = self.remote.lock() {
            *r = (Value::Null, "fetching…".into());
        }
    }

    pub fn remote_snapshot(&self) -> (Value, String) {
        self.remote.lock().map(|r| r.clone()).unwrap_or((Value::Null, String::new()))
    }

    pub fn list(&self) -> Vec<Peer> {
        self.peers.lock().map(|p| p.clone()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // One row per address with the shortest alias, and non-mesh HostNames
    // dropped entirely — the two rules the peer table depends on.
    #[test]
    fn ssh_config_collapses_aliases_and_ignores_non_mesh_hosts() {
        assert_eq!(strip_key("HostName 10.0.0.6", "HostName"), Some("10.0.0.6"));
        assert_eq!(strip_key("  hostname   10.0.0.6", "HostName"), Some("10.0.0.6"));
        assert_eq!(strip_key("Host oci-apps", "HostName"), None);
        assert!(is_mesh_addr("10.0.0.1"));
        assert!(is_mesh_addr("fd0c:1d01::9"));
        assert!(!is_mesh_addr("github.com"));
        assert!(!is_mesh_addr("192.168.47.219"));
    }
}
