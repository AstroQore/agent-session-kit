//! Bounded, O(n) JSONL access. Mirrors the Swift package's rule that session
//! logs are only ever read with a moving cursor — never `String(contentsOf:)`
//! whole-file loads — and that a reader survives arbitrarily broken lines.

use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

/// Longest line the readers will parse; anything longer is skipped, not an
/// error (agent logs can embed entire files on one line).
pub const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Iterate over parsed JSON lines, skipping unparseable or oversized ones.
/// `f` returns `false` to stop early.
pub fn for_each_json_line(
    path: &Path,
    mut f: impl FnMut(Value) -> bool,
) -> std::io::Result<()> {
    let file = File::open(path)?;
    let mut reader = BufReader::with_capacity(256 * 1024, file);
    let mut buf: Vec<u8> = Vec::new();
    loop {
        buf.clear();
        let read = read_limited_line(&mut reader, &mut buf)?;
        if read == 0 {
            return Ok(());
        }
        if buf.len() >= MAX_LINE_BYTES {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(&buf) else {
            continue;
        };
        if !f(value) {
            return Ok(());
        }
    }
}

/// First `limit` parsed JSON lines of the file.
pub fn head_json_lines(path: &Path, limit: usize) -> std::io::Result<Vec<Value>> {
    let mut out = Vec::with_capacity(limit);
    for_each_json_line(path, |value| {
        out.push(value);
        out.len() < limit
    })?;
    Ok(out)
}

/// Parsed JSON lines from roughly the last `tail_bytes` of the file (the
/// first, possibly partial, line of the window is dropped).
pub fn tail_json_lines(path: &Path, tail_bytes: u64) -> std::io::Result<Vec<Value>> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(tail_bytes);
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::with_capacity(256 * 1024, file);
    if start > 0 {
        // Drop the partial first line of the window.
        let mut scratch = Vec::new();
        read_limited_line(&mut reader, &mut scratch)?;
    }
    let mut out = Vec::new();
    let mut buf: Vec<u8> = Vec::new();
    loop {
        buf.clear();
        let read = read_limited_line(&mut reader, &mut buf)?;
        if read == 0 {
            return Ok(out);
        }
        if buf.len() >= MAX_LINE_BYTES {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(&buf) {
            out.push(value);
        }
    }
}

/// Reads one line into `buf` without the trailing newline, refusing to grow
/// past `MAX_LINE_BYTES` (the remainder of an oversized line is drained).
/// Returns total bytes consumed (0 at EOF).
fn read_limited_line<R: BufRead>(reader: &mut R, buf: &mut Vec<u8>) -> std::io::Result<usize> {
    let mut consumed = 0usize;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(consumed);
        }
        match memchr(b'\n', available) {
            Some(pos) => {
                let take = &available[..pos];
                if buf.len() < MAX_LINE_BYTES {
                    let room = MAX_LINE_BYTES - buf.len();
                    buf.extend_from_slice(&take[..take.len().min(room)]);
                }
                let advance = pos + 1;
                reader.consume(advance);
                return Ok(consumed + advance);
            }
            None => {
                let take_len = available.len();
                if buf.len() < MAX_LINE_BYTES {
                    let room = MAX_LINE_BYTES - buf.len();
                    buf.extend_from_slice(&available[..take_len.min(room)]);
                }
                reader.consume(take_len);
                consumed += take_len;
            }
        }
    }
}

fn memchr(needle: u8, haystack: &[u8]) -> Option<usize> {
    haystack.iter().position(|&b| b == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn skips_broken_lines_and_stops_early() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        let mut f = File::create(&path).unwrap();
        writeln!(f, "{{\"a\":1}}").unwrap();
        writeln!(f, "not json").unwrap();
        writeln!(f, "{{\"a\":2}}").unwrap();
        writeln!(f, "{{\"a\":3}}").unwrap();
        drop(f);

        let head = head_json_lines(&path, 2).unwrap();
        assert_eq!(head.len(), 2);
        assert_eq!(head[1]["a"], 2);

        let tail = tail_json_lines(&path, 10).unwrap();
        assert!(!tail.is_empty());
        assert_eq!(tail.last().unwrap()["a"], 3);
    }
}
