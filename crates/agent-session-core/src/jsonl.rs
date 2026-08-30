//! Bounded, O(n) JSONL access. Mirrors the Swift package's rule that session
//! logs are only ever read with a moving cursor — never `String(contentsOf:)`
//! whole-file loads — and that a reader survives arbitrarily broken lines.

use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

/// Longest line the readers will parse; anything longer is skipped, not an
/// error (agent logs can embed entire files on one line).
pub const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;
/// Largest whole-file streaming pass exposed by [`for_each_json_line`].
pub const MAX_JSONL_SCAN_BYTES: u64 = 64 * 1024 * 1024;
/// Largest tail window accepted by [`tail_json_lines`].
pub const MAX_TAIL_BYTES: u64 = 8 * 1024 * 1024;
/// Largest number of parsed values returned by [`tail_json_lines`].
pub const MAX_TAIL_LINES: usize = 10_000;
/// Largest number of parsed head records returned by [`head_json_lines`].
pub const MAX_HEAD_LINES: usize = 128;
/// Largest prefix scanned by [`head_json_lines`], including malformed lines.
pub const MAX_HEAD_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadStats {
    /// Bytes consumed from the supplied reader. This never exceeds the
    /// requested cap; an already-buffered reader may have prefetched a small
    /// implementation-defined amount beyond it.
    pub bytes_read: u64,
    /// The scan stopped because it reached the supplied byte cap.
    pub truncated: bool,
}

/// Iterate over parsed JSON lines with a hard whole-file scan cap.
/// `f` returns `false` to stop early. Inspect [`ReadStats::truncated`] before
/// treating a completed callback sequence as a complete file.
pub fn for_each_json_line(path: &Path, f: impl FnMut(Value) -> bool) -> std::io::Result<ReadStats> {
    for_each_json_line_bounded(path, MAX_JSONL_SCAN_BYTES, f)
}

/// Iterate over parsed JSON lines without reading an unbounded amount of a
/// growing log. A cap of zero still permits one line so callers can make
/// forward progress and report a useful truncation state.
pub fn for_each_json_line_bounded(
    path: &Path,
    max_bytes: u64,
    f: impl FnMut(Value) -> bool,
) -> std::io::Result<ReadStats> {
    let file = open_regular_file(path)?;
    let capacity = usize::try_from(max_bytes)
        .unwrap_or(usize::MAX)
        .clamp(1, 256 * 1024);
    for_each_json_line_bounded_reader(BufReader::with_capacity(capacity, file), max_bytes, f)
}

/// Iterate over parsed JSONL records from an already-open reader. This is the
/// capability-safe variant for hosts that validated and opened a session file
/// themselves; no path is reopened while parsing.
pub fn for_each_json_line_bounded_reader<R: BufRead>(
    mut reader: R,
    max_bytes: u64,
    mut f: impl FnMut(Value) -> bool,
) -> std::io::Result<ReadStats> {
    let mut buf: Vec<u8> = Vec::new();
    let mut bytes_read = 0u64;
    let cap = max_bytes.max(1);
    loop {
        if bytes_read >= cap {
            return Ok(ReadStats {
                bytes_read,
                truncated: true,
            });
        }
        buf.clear();
        let remaining = usize::try_from(cap - bytes_read).unwrap_or(usize::MAX);
        let line = read_limited_line(&mut reader, &mut buf, remaining)?;
        if line.consumed == 0 {
            return Ok(ReadStats {
                bytes_read,
                truncated: false,
            });
        }
        bytes_read = bytes_read.saturating_add(line.consumed as u64);
        if line.hit_budget {
            return Ok(ReadStats {
                bytes_read,
                truncated: true,
            });
        }
        if buf.len() >= MAX_LINE_BYTES {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(&buf) else {
            continue;
        };
        if !f(value) {
            return Ok(ReadStats {
                bytes_read,
                truncated: false,
            });
        }
    }
}

/// First `limit` parsed JSON lines within a bounded prefix of the file.
///
/// A malformed prefix beyond [`MAX_HEAD_BYTES`] is intentionally not scanned.
pub fn head_json_lines(path: &Path, limit: usize) -> std::io::Result<Vec<Value>> {
    let limit = limit.min(MAX_HEAD_LINES);
    if limit == 0 {
        return Ok(Vec::new());
    }
    let mut out = Vec::with_capacity(limit);
    let _stats = for_each_json_line_bounded(path, MAX_HEAD_BYTES, |value| {
        out.push(value);
        out.len() < limit
    })?;
    Ok(out)
}

/// Parsed JSON lines from roughly the last `tail_bytes` of the file (the
/// first, possibly partial, line of the window is dropped). Both the byte
/// window and returned record count are capped; when there are too many
/// records, the newest [`MAX_TAIL_LINES`] are retained.
pub fn tail_json_lines(path: &Path, tail_bytes: u64) -> std::io::Result<Vec<Value>> {
    let mut file = open_regular_file(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(tail_bytes.min(MAX_TAIL_BYTES));
    file.seek(SeekFrom::Start(start))?;
    let initial_window = len - start;
    let mut reader = BufReader::with_capacity(256 * 1024, file.take(initial_window));
    if start > 0 {
        // Drop the partial first line of the window.
        let mut scratch = Vec::new();
        read_limited_line(&mut reader, &mut scratch, usize::MAX)?;
    }
    let mut out = VecDeque::with_capacity(MAX_TAIL_LINES);
    let mut buf: Vec<u8> = Vec::new();
    loop {
        buf.clear();
        let line = read_limited_line(&mut reader, &mut buf, usize::MAX)?;
        if line.consumed == 0 {
            return Ok(out.into_iter().collect());
        }
        if buf.len() >= MAX_LINE_BYTES {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(&buf) {
            if out.len() == MAX_TAIL_LINES {
                out.pop_front();
            }
            out.push_back(value);
        }
    }
}

/// Reject a symlink or any non-regular leaf before a session reader opens it.
///
/// This is deliberately only a leaf check: a portable std-only implementation
/// cannot atomically combine it with `open`, so a same-user attacker can still
/// race a path replacement. Hosts that cross a trust boundary must use an
/// opaque session reference and resolve it inside their trusted backend.
pub fn open_regular_file(path: &Path) -> std::io::Result<File> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "session source must be a non-symlink regular file",
        ));
    }
    File::open(path)
}

/// Reads one line into `buf` without the trailing newline, refusing to grow
/// past `MAX_LINE_BYTES` and to consume beyond `budget`. A caller that runs
/// out of budget receives `hit_budget` rather than draining an unterminated
/// oversized line to EOF.
struct LineRead {
    consumed: usize,
    hit_budget: bool,
}

fn read_limited_line<R: BufRead>(
    reader: &mut R,
    buf: &mut Vec<u8>,
    budget: usize,
) -> std::io::Result<LineRead> {
    let mut consumed = 0usize;
    loop {
        if consumed == budget {
            return Ok(LineRead {
                consumed,
                hit_budget: true,
            });
        }
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(LineRead {
                consumed,
                hit_budget: false,
            });
        }
        let allowed = available.len().min(budget - consumed);
        let chunk = &available[..allowed];
        match memchr(b'\n', chunk) {
            Some(pos) => {
                let take = &chunk[..pos];
                if buf.len() < MAX_LINE_BYTES {
                    let room = MAX_LINE_BYTES - buf.len();
                    buf.extend_from_slice(&take[..take.len().min(room)]);
                }
                let advance = pos + 1;
                reader.consume(advance);
                return Ok(LineRead {
                    consumed: consumed + advance,
                    hit_budget: false,
                });
            }
            None => {
                let take_len = chunk.len();
                if buf.len() < MAX_LINE_BYTES {
                    let room = MAX_LINE_BYTES - buf.len();
                    buf.extend_from_slice(&chunk[..take_len.min(room)]);
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

    #[test]
    fn bounds_head_and_tail_requests() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        let mut f = File::create(&path).unwrap();
        for value in 0..200 {
            writeln!(f, "{{\"a\":{value}}}").unwrap();
        }
        drop(f);

        assert_eq!(
            head_json_lines(&path, usize::MAX).unwrap().len(),
            MAX_HEAD_LINES
        );
        assert!(!tail_json_lines(&path, u64::MAX).unwrap().is_empty());
    }

    #[test]
    fn tail_keeps_only_the_newest_bounded_record_count() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        let mut f = File::create(&path).unwrap();
        for value in 0..(MAX_TAIL_LINES + 10) {
            writeln!(f, "{{\"a\":{value}}}").unwrap();
        }
        drop(f);

        let tail = tail_json_lines(&path, u64::MAX).unwrap();
        assert_eq!(tail.len(), MAX_TAIL_LINES);
        assert_eq!(tail.first().unwrap()["a"], 10);
        assert_eq!(tail.last().unwrap()["a"], MAX_TAIL_LINES + 9);
    }

    #[test]
    fn head_stops_after_its_byte_cap_even_without_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        std::fs::write(&path, vec![b'x'; MAX_HEAD_BYTES as usize + 2]).unwrap();

        assert!(head_json_lines(&path, MAX_HEAD_LINES).unwrap().is_empty());
    }

    #[test]
    fn bounded_reader_reports_a_byte_cap() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        std::fs::write(&path, "{\"a\":1}\n{\"a\":2}\n").unwrap();

        let stats = for_each_json_line_bounded(&path, 1, |_| true).unwrap();
        assert!(stats.truncated);
        assert_eq!(stats.bytes_read, 1);
    }

    #[test]
    fn bounded_reader_does_not_drain_a_giant_unterminated_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.jsonl");
        std::fs::write(&path, vec![b'x'; 2 * 1024 * 1024]).unwrap();

        let stats = for_each_json_line_bounded(&path, 1024, |_| true).unwrap();
        assert!(stats.truncated);
        assert_eq!(stats.bytes_read, 1024);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_sources() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.jsonl");
        std::fs::write(&target, "{\"a\":1}\n").unwrap();
        let link = dir.path().join("link.jsonl");
        symlink(&target, &link).unwrap();

        let error = head_json_lines(&link, 1).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    }
}
