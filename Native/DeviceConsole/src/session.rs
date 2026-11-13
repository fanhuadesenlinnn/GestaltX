// SPDX-License-Identifier: GPL-3.0-only
//! Session lifecycle: a single serialized device operation (pairing OR syslog
//! capture) at a time, each identified by a monotonic `generation`, each
//! cancellable from another thread.
//!
//! This is the part the integration plan insists must be rewritten rather than
//! copied from AirCard's reference, whose `softCancel()` only stopped the UI and
//! left the Rust listener running. Here cancellation is real: `cancel()` flips a
//! shared flag and (on the device build) wakes any awaiting future through a
//! `Notify`, so a blocked `accept()` / `read()` returns promptly, and the active
//! slot is only released once the worker has truly exited.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// A cancellation flag shared between the caller's thread and the worker.
pub struct CancelToken {
    flag: AtomicBool,
    #[cfg(feature = "device")]
    notify: tokio::sync::Notify,
}

impl CancelToken {
    fn new() -> Self {
        Self {
            flag: AtomicBool::new(false),
            #[cfg(feature = "device")]
            notify: tokio::sync::Notify::new(),
        }
    }

    /// Request cancellation. Idempotent; safe from any thread.
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        #[cfg(feature = "device")]
        self.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// Resolve as soon as cancellation is requested. Use inside `tokio::select!`
    /// so an in-flight connect/accept/read is dropped on cancel.
    #[cfg(feature = "device")]
    pub async fn cancelled(&self) {
        loop {
            if self.is_cancelled() {
                return;
            }
            // Register for notification *before* re-checking the flag to avoid a
            // lost wakeup between the check and the await.
            let waiter = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            waiter.await;
        }
    }
}

struct Active {
    generation: u64,
    cancel: Arc<CancelToken>,
}

/// Process-wide registry. `std::sync::Mutex::new` is const, so these are plain
/// statics with no lazy init.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);
static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);

/// Begin a new session. Returns `None` if one is already active (serialized
/// lifecycle — no overlapping pairing/capture runs). On success the caller owns
/// the returned token and must call [`end`] with the same generation when the
/// worker has fully exited.
pub fn begin() -> Option<(u64, Arc<CancelToken>)> {
    let mut guard = ACTIVE.lock().ok()?;
    if guard.is_some() {
        return None;
    }
    let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
    let cancel = Arc::new(CancelToken::new());
    *guard = Some(Active { generation, cancel: cancel.clone() });
    Some((generation, cancel))
}

/// The cancel token for `generation`, if it is the active session.
pub fn token_for(generation: u64) -> Option<Arc<CancelToken>> {
    let guard = ACTIVE.lock().ok()?;
    match guard.as_ref() {
        Some(active) if active.generation == generation => Some(active.cancel.clone()),
        _ => None,
    }
}

/// Signal cancellation for a specific generation. A stale generation (already
/// ended, or superseded) is ignored, so a late cancel never kills a new session.
pub fn cancel(generation: u64) {
    if let Some(token) = token_for(generation) {
        token.cancel();
    }
}

/// Release the active slot. Only clears it when `generation` still owns it.
pub fn end(generation: u64) {
    if let Ok(mut guard) = ACTIVE.lock() {
        if matches!(guard.as_ref(), Some(a) if a.generation == generation) {
            *guard = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reset() {
        if let Ok(mut g) = ACTIVE.lock() {
            *g = None;
        }
    }

    #[test]
    fn serializes_and_increments() {
        reset();
        let (g1, _t1) = begin().expect("first begin");
        assert!(begin().is_none(), "second begin must be refused while active");
        end(g1);
        let (g2, _t2) = begin().expect("begin after end");
        assert!(g2 > g1, "generation must advance");
        end(g2);
    }

    #[test]
    fn cancel_sets_token_and_is_generation_scoped() {
        reset();
        let (g, token) = begin().expect("begin");
        assert!(!token.is_cancelled());
        // A cancel for an unrelated generation is ignored.
        cancel(g.wrapping_add(999));
        assert!(!token.is_cancelled(), "stale-generation cancel must not fire");
        cancel(g);
        assert!(token.is_cancelled(), "matching cancel must fire");
        end(g);
    }

    #[test]
    fn end_is_generation_guarded() {
        reset();
        let (g1, _t1) = begin().expect("begin");
        // A stale end() for a previous generation must not free a newer slot.
        end(g1.wrapping_sub(1));
        assert!(begin().is_none(), "slot must still be held");
        end(g1);
        assert!(begin().is_some(), "slot freed by matching end");
        reset();
    }
}
