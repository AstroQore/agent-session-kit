//! Read-only smoke check against a real shared index:
//! `cargo run --example smoke -- <path-to-session_index.sqlite3>`
use agent_session_core::index::{SessionIndexReader, SessionListFilter};

fn main() {
    let path = std::env::args().nth(1).expect("usage: smoke <index path>");
    let reader = SessionIndexReader::open(std::path::Path::new(&path)).expect("open");
    println!("sessions: {}", reader.session_count().expect("count"));
    let rows = reader
        .list(&SessionListFilter { limit: 5, ..Default::default() })
        .expect("list");
    for row in &rows {
        println!(
            "- [{}] {} ({} msgs)",
            row.provider.raw_value(),
            row.title.as_deref().unwrap_or("<untitled>").chars().take(60).collect::<String>(),
            row.message_count.unwrap_or(0)
        );
    }
    let hits = reader
        .search("vibe", &SessionListFilter { limit: 3, ..Default::default() })
        .expect("search");
    println!("search 'vibe' hits: {}", hits.len());
}
