# Safe recovery

Stop issuing new operations on unknown, stale, foreign or contradictory evidence, a busy/abandoned host lock, or a provider timeout. Do not bypass locks, delete lock files, remove media, force-stop or restore a live DC snapshot.

1. Obtain the same machine-wide host lock, then the existing lab lock. If busy or denied, refuse; never take ownership by PID/age. Always inspect all journals and reservations after acquisition, even when the OS did not report abandonment. No real orchestration path is enabled yet.
2. Preserve the original journal, media and read-only observations. Verify the complete hash chain and local ACLs. Corrupt/torn journals require explicit manual recovery; do not trim or recreate. Record only bounded, redacted reason codes externally.
3. Reconcile exact lab/guest/VM/media IDs, base digest, complete registered/running/media inventory, internal peer scope and guest health. Unknowns retain all reservations. A foreign VM or changed attachment is a conflict, not something to adopt or delete.
4. Use N09's explicit recovery rules: undispatched intent may be cancelled only with verified prior-state evidence; dispatched operation may be completed only after independently verified result and release/readiness. No automatic retry or rollback.
5. Recompute resources and the plan. Request fresh approval; never reuse the old fingerprint after partial completion. If isolation cannot be restored safely, keep the lab stopped where already stopped, preserve evidence and involve the operator; no automatic destructive action.

See [N09 recovery contract](../tests/recovery/README.md) and [N12 switch contract](../tests/switch/README.md). This is a recovery policy, not a qualified native recovery utility.
