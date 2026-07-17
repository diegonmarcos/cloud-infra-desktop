//! my-browser-rust-chromium — Rust front-end + Chromium (CEF) backend.
//!
//! SKELETON. This does not render web content yet — it stands up the process
//! shape CEF requires (the sub-process dispatch + main-loop) so the real
//! wiring drops in without restructuring. See README.md for the phase plan.
//!
//! CEF's model: ONE binary is re-exec'd as several process types (browser, gpu,
//! renderer, utility). `cef::execute_process` MUST run first; for helper
//! process types it never returns. Only the browser process continues to build
//! the window + UI. That is the opposite of qute (Python shell hosting an
//! in-process QtWebEngine) — here CEF forks real Chromium child processes, which
//! is exactly why the fingerprint is genuine Chrome.

fn main() {
    // ponytail: skeleton — real cef-rs calls go here once the flake pins libcef.
    // The intended shape (pseudocode against the cef crate API):
    //
    //     let args = cef::args::Args::new();
    //     // Helper process types (gpu/renderer/utility) dispatch and exit here:
    //     if let Some(code) = cef::execute_process(&args, None, None) {
    //         std::process::exit(code);
    //     }
    //     let settings = cef::Settings::new();          // no-sandbox off; real Chrome defaults
    //     cef::initialize(&args, &settings, None, None);
    //     // ... create our winit window, embed a CEF browser view, draw the
    //     //     Rust chrome bar (tab strip + omnibar) around it ...
    //     cef::run_message_loop();
    //     cef::shutdown();

    eprintln!(
        "my-browser-rust-chromium: skeleton only — no CEF wired yet.\n\
         Next: pin libcef in src/flake.nix (fixed-output), then implement the \n\
         execute_process/initialize/run_message_loop cycle above.\n\
         Acceptance test: JA4 at tls.peet.ws must equal a current Chrome profile."
    );
}
