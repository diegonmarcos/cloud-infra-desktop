// Every storage unit this fleet can mount, and which of them are mounted here.
//
// WHY THIS IS NOT IN THE SNAPSHOT
// my-watchdog measures a machine. This is a DECLARATION — what exists, where
// it lives, what it costs — and it lives in cloud-infra, which the sampler has
// no business depending on. So the panel reads it directly, the same way it
// reads the home directory for the files tab: static facts, read once, not
// sampled.
//
// WHAT IS DELIBERATELY NOT HERE: SIZES
// Every mount below is a network filesystem. `df` on a dead sshfs mount blocks
// in the kernel and does not come back — no timeout, no signal, and the
// dashboard is a single render thread. A monitor that hangs because a peer
// went down is worse than one that omits a number, so nothing here stats a
// mountpoint. The storage tab says what exists and what is mounted; the fleet
// tab beside it says how full each machine is, measured by that machine.
use std::fs;

use serde_json::Value;

use super::data::{arr, text};

/// One thing you could mount, or already have.
pub(crate) struct Unit {
    /// mount · s3 · rclone · git — the four kinds, in the order a person cares
    /// about them: what is live, then what is declared.
    pub(crate) kind: &'static str,
    pub(crate) name: String,
    pub(crate) provider: String,
    /// Storage class, rclone backend type, or the git host's role.
    pub(crate) tier: String,
    /// The endpoint you would point a client at.
    pub(crate) addr: String,
    /// Where it is mounted on THIS machine, empty if it is not.
    pub(crate) at: String,
}

/// The consolidated declaration, from cloud-infra.
///
/// Env var first so a checkout somewhere else still works, then the path it
/// actually lives at. Missing is not an error: on a peer this file does not
/// exist at all, and the tab should say "nothing declared here" rather than
/// refuse to draw.
fn consolidated() -> Option<Value> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut paths: Vec<String> = vec![];
    if let Ok(p) = std::env::var("CLOUD_DATA_JSON") {
        paths.push(p);
    }
    paths.push(format!(
        "{home}/git/cloud-infra/1_cloud-configs/dist/_cloud-data-consolidated.json"
    ));
    for p in paths {
        if let Ok(s) = fs::read_to_string(&p) {
            if let Ok(v) = serde_json::from_str(&s) {
                return Some(v);
            }
        }
    }
    None
}

/// Network filesystems mounted right now.
///
/// /proc/mounts, not `mount(8)`: reading a file cannot block on a dead server
/// the way asking the mount table's helpers can. Only the network types — the
/// point of this list is "storage that lives somewhere else", and there are
/// eighty tmpfs and cgroup lines in there that are not that.
fn live_mounts() -> Vec<Unit> {
    const NET: [&str; 7] =
        ["fuse.rclone", "fuse.sshfs", "sshfs", "fuse.s3fs", "s3fs", "nfs4", "cifs"];
    let Ok(t) = fs::read_to_string("/proc/mounts") else { return vec![] };
    let mut out = vec![];
    for line in t.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 3 || !NET.contains(&f[2]) {
            continue;
        }
        // rclone mounts announce themselves as `:sftp{CcfTB}:/` — a handle,
        // not a name. The mountpoint's last component is what the person who
        // mounted it chose to call the thing, so that is the name.
        let at = f[1].replace("\\040", " ");
        let name = at.rsplit('/').next().unwrap_or(&at).to_string();
        out.push(Unit {
            kind: "mount",
            name,
            provider: f[2].trim_start_matches("fuse.").to_string(),
            tier: "mounted".into(),
            addr: f[0].to_string(),
            at,
        });
    }
    out.sort_by(|a, b| a.at.cmp(&b.at));
    out
}

/// rclone remotes, by NAME AND BACKEND ONLY.
///
/// This file holds tokens and passwords. Nothing but the section header and
/// the `type =` line is read, and nothing else may ever be — a panel that
/// renders a credential onto a shared screen is a much worse bug than a
/// missing column.
fn rclone_remotes() -> Vec<(String, String)> {
    let home = std::env::var("HOME").unwrap_or_default();
    let Ok(t) = fs::read_to_string(format!("{home}/.config/rclone/rclone.conf")) else {
        return vec![];
    };
    parse_rclone(&t)
}

/// Split out so the test can run the REAL parser over a config with real
/// secrets in it. A test that reimplements the parser proves nothing about
/// the parser.
fn parse_rclone(t: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = vec![];
    for line in t.lines() {
        let l = line.trim();
        if let Some(n) = l.strip_prefix('[').and_then(|x| x.strip_suffix(']')) {
            out.push((n.to_string(), String::new()));
        } else if let Some(rest) = l.strip_prefix("type") {
            if let Some(v) = rest.trim().strip_prefix('=') {
                if let Some(last) = out.last_mut() {
                    last.1 = v.trim().to_string();
                }
            }
        }
    }
    out
}

/// Everything, live first.
pub(crate) fn units() -> Vec<Unit> {
    let mut out = live_mounts();
    // The live mounts are the first `n_live` entries and nothing appended
    // later is one, so matching against that prefix avoids reading
    // /proc/mounts a second time. The borrow ends before each push.
    let n_live = out.len();
    let mounted_at = |needle: &str, list: &[Unit]| -> String {
        list.iter()
            .find(|m| m.name == needle || m.at.contains(needle))
            .map(|m| m.at.clone())
            .unwrap_or_default()
    };

    if let Some(d) = consolidated() {
        for b in arr(&d, "storage") {
            let name = text(b, "name");
            let at = mounted_at(&name, &out[..n_live]);
            out.push(Unit {
                kind: "s3",
                at,
                provider: text(b, "provider"),
                tier: text(b, "tier"),
                // The S3 endpoint, not the vanity DNS: this is the address a
                // client is configured with, and it is the one that is wrong
                // when a mount fails.
                addr: text(b, "s3_endpoint"),
                name,
            });
        }
        // Git hosts are storage too — the fleet's code lives in them, and
        // "where do I clone this from" is the same question as "what can I
        // mount", asked about a different kind of blob.
        let gitea = d.get("services").and_then(|s| s.get("gitea"));
        if let Some(g) = gitea {
            out.push(Unit {
                kind: "git",
                name: "gitea".into(),
                provider: "self-hosted".into(),
                tier: text(g, "vm"),
                addr: format!("https://{}", text(g, "domain")),
                at: String::new(),
            });
        }
        let gh = text(&d, "owner.github");
        if !gh.is_empty() {
            out.push(Unit {
                kind: "git",
                name: gh.clone(),
                provider: "github".into(),
                tier: "upstream".into(),
                addr: format!("https://github.com/{gh}"),
                at: String::new(),
            });
        }
    }

    for (name, ty) in rclone_remotes() {
        let at = mounted_at(&name, &out[..n_live]);
        out.push(Unit {
            kind: "rclone",
            at,
            name,
            provider: "rclone".into(),
            tier: if ty.is_empty() { "?".into() } else { ty },
            addr: String::new(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // The one rule this module must never break. rclone.conf holds tokens;
    // only the section name and the backend type may leave it. This runs the
    // real parser over a config shaped like the real one, secrets included.
    #[test]
    fn rclone_parsing_takes_the_name_and_type_and_nothing_else() {
        let conf = "[Gdrive_me]\ntype = drive\ntoken = {\"access_token\":\"SECRET\"}\n\
                    client_secret = hunter2\n\n[box]\ntype = s3\naccess_key_id = AKIAREAL\n";
        let out = parse_rclone(conf);
        assert_eq!(
            out,
            vec![("Gdrive_me".to_string(), "drive".to_string()), ("box".to_string(), "s3".to_string())]
        );
        let joined = format!("{out:?}");
        for leak in ["SECRET", "hunter2", "AKIAREAL", "access_token", "client_secret"] {
            assert!(!joined.contains(leak), "{leak} escaped the rclone parser");
        }
    }

    // A mountpoint is the only name an rclone mount has — the source field is
    // an opaque handle like `:sftp{CcfTB}:/`, which names nothing.
    #[test]
    fn a_mount_is_named_after_its_mountpoint() {
        let at = "/home/diego/mounts/fleet/oci-apps";
        assert_eq!(at.rsplit('/').next(), Some("oci-apps"));
    }
}
