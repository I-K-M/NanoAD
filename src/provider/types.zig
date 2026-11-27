const std = @import("std");

pub const Uuid = struct {
    text: [36]u8,

    pub fn parse(input: []const u8) error{InvalidUuid}!Uuid {
        if (input.len != 36) return error.InvalidUuid;
        var result: Uuid = undefined;
        var nonzero = false;
        for (input, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (c != '-') return error.InvalidUuid;
            } else {
                const lower = std.ascii.toLower(c);
                if (!std.ascii.isDigit(lower) and !(lower >= 'a' and lower <= 'f'))
                    return error.InvalidUuid;
                if (lower != '0') nonzero = true;
            }
            result.text[i] = std.ascii.toLower(c);
        }
        if (!nonzero) return error.InvalidUuid;
        return result;
    }

    pub fn valid(self: Uuid) bool {
        const canonical = parse(&self.text) catch return false;
        return self.eql(canonical);
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.text, &b.text);
    }
};

pub const OwnedGuest = struct {
    // Populated only from a future verified local ownership record, not arbitrary CLI input.
    lab: Uuid,
    guest: Uuid,
    vm: Uuid,

    pub fn valid(self: OwnedGuest) bool {
        return self.lab.valid() and self.guest.valid() and self.vm.valid() and
            !self.lab.eql(self.guest) and !self.lab.eql(self.vm) and !self.guest.eql(self.vm);
    }

    pub fn network(self: OwnedGuest) [43]u8 {
        return "nanoad-".* ++ self.lab.text;
    }
};

pub const PowerState = enum { powered_off, running, paused, saved, aborted, transitional, unknown };
pub const NetworkEvidence = enum { compatible, rejected, incomplete };

pub const Observation = struct {
    vm: Uuid,
    power: PowerState,
    memory_bytes: u64,
    network: NetworkEvidence,
    // Positive network evidence is NOT a complete isolation attestation.
    isolation_verified: bool = false,
};

pub const Failure = error{
    Unsupported,
    InvalidResponse,
    OutputLimit,
    Timeout,
    ProviderFailure,
    OwnershipMismatch,
    IsolationUnverified,
    ResourceRefused,
    ApprovalRequired,
    JournalRequired,
    WrongState,
    ReadinessTimeout,
    ShutdownTimeout,
    RecoveryRequired,
};

test "UUID canonicalisation rejects names, empty and zero identity" {
    const id = try Uuid.parse("01234567-89AB-CDEF-0123-456789ABCDEF");
    try std.testing.expectEqualStrings("01234567-89ab-cdef-0123-456789abcdef", &id.text);
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("DC01"));
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("00000000-0000-0000-0000-000000000000"));
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("01234567-89ab-cdef-0123-456789abcde!"));
}
