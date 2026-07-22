// integration smoke test: start the engine in-process, drive a real PTY over ws.
use std::net::TcpStream;
use std::time::{Duration, Instant};
use tungstenite::Message;

#[test]
fn smoke_start_write_output() {
    let addr = "127.0.0.1:7399";
    std::thread::spawn(move || my_konsole_engine::run(addr));
    std::thread::sleep(Duration::from_millis(200)); // let the listener bind

    // ponytail: connect our own TcpStream (not tungstenite::connect's MaybeTlsStream)
    // so we can set a read timeout before handing it to the ws handshake.
    let tcp = TcpStream::connect(addr).expect("tcp connect");
    tcp.set_read_timeout(Some(Duration::from_millis(200))).ok();
    let (mut ws, _resp) = tungstenite::client(format!("ws://{addr}"), tcp).expect("ws handshake");

    ws.send(Message::Text(
        r#"{"op":"start","id":"t","cols":80,"rows":24,"cwd":null}"#.into(),
    ))
    .unwrap();
    ws.send(Message::Text(
        r#"{"op":"write","id":"t","data":"echo HELLO_ENGINE\r"}"#.into(),
    ))
    .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut found = false;
    while Instant::now() < deadline && !found {
        match ws.read() {
            Ok(Message::Text(txt)) => {
                if txt.contains("HELLO_ENGINE") && txt.contains("\"ev\":\"output\"") {
                    found = true;
                }
            }
            Ok(_) => {}
            Err(_) => {} // read timeout / would-block; keep polling until deadline
        }
    }

    ws.send(Message::Text(r#"{"op":"kill","id":"t"}"#.into()))
        .ok();
    assert!(found, "expected an output frame containing HELLO_ENGINE");
}
