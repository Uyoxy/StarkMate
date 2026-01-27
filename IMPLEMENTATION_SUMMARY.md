# Issue #93 Analysis Summary - For Quick Reference

**Assignee:** @soomtochukwu  
**Branch:** `security/refresh-token-rotation`  
**Due:** January 31, 2026 (4 days)  
**Status:** Ready to Implement

---

## What This Feature Does

Implements secure **refresh token rotation** with **theft detection** using the **Token Families pattern**:

1. **On Login**: Issue access token (short-lived) + refresh token in secure HTTP-only cookie
2. **On Refresh**: Validate old token, mark as used, issue new tokens in same family
3. **On Theft**: If token is reused → entire family invalidated → attacker + user both locked out
4. **On Logout**: Revoke all tokens for the player across all devices

---

## Tech Stack Summary

| Layer        | Technology                | Current State    | Required Changes              |
| ------------ | ------------------------- | ---------------- | ----------------------------- |
| **Backend**  | Rust + Actix-web 4.x      | ✅ Running       | - Stable                      |
| **Database** | PostgreSQL + SeaORM 1.1.0 | ✅ Running       | ✅ Add `refresh_tokens` table |
| **Auth**     | JWT via JwtService        | ✅ Access tokens | ✅ Add refresh token logic    |
| **Security** | `security/src/jwt.rs`     | ✅ Exists        | ✅ Add `token_service.rs`     |
| **API**      | `api/src/auth.rs`         | ⚠️ Mocks only    | ✅ Implement real endpoints   |
| **DTOs**     | `dto/src/auth.rs`         | ⚠️ Incomplete    | ✅ Add refresh token types    |

---

## High-Level Implementation (6 Phases)

### Phase 1: Database ✅ (Foundation)

Create `refresh_tokens` table with:

- `family_id` (UUID) - group tokens
- `token_hash` (SHA256) - never plaintext
- `used_at` - timestamp when consumed
- `is_revoked` - for theft detection
- Indexes on family_id, player_id, token_hash

**File:** `backend/modules/db/migrations/src/m20260127_create_refresh_tokens_table.rs`

---

### Phase 2: Service Layer ✅ (Business Logic)

Create `TokenService` with:

- `generate_refresh_token()` - 32 random bytes, base64-encoded, SHA256-hashed
- `verify_and_mark_used()` - detect reuse via `used_at IS NOT NULL`
- `invalidate_token_family()` - nuke entire family on theft
- `revoke_player_tokens()` - logout revokes all

**File:** `backend/modules/security/src/token_service.rs`

---

### Phase 3: API Endpoints ✅ (User-Facing)

Update `auth.rs` with:

- **POST /v1/auth/login** - return access + refresh tokens
- **POST /v1/auth/refresh** - rotate tokens, detect theft
- **POST /v1/auth/logout** - revoke all tokens

Implement in: `backend/modules/api/src/auth.rs`

---

### Phase 4: Error Handling ✅ (Robustness)

Add error types:

- `TokenNotFound`
- `TokenReuseDetected` ← Triggers family invalidation
- `TokenExpired`
- `TokenInvalid`

---

### Phase 5: Configuration ✅ (Flexibility)

Add to `.env.example`:

- `REFRESH_TOKEN_TTL_DAYS=7`
- `ACCOUNT_LOCK_DURATION_MINUTES=30`

---

### Phase 6: Testing ✅ (Validation)

Write 5+ integration tests:

1. Login returns refresh token ✓
2. Refresh rotates tokens ✓
3. **Token reuse triggers theft detection** ← Critical
4. Logout revokes all tokens ✓
5. Expired tokens rejected ✓

---

## Key Security Features

| Feature                  | Implementation                                    |
| ------------------------ | ------------------------------------------------- |
| **Token Generation**     | 32 random bytes + base64 encoding                 |
| **Token Storage**        | SHA256 hashing (never plaintext)                  |
| **Cookie Security**      | HttpOnly + Secure + SameSite=Strict               |
| **Theft Detection**      | Check `used_at IS NOT NULL` on refresh            |
| **Family Invalidation**  | Single UPDATE statement invalidates entire family |
| **Database Constraints** | CHECK constraints ensure state consistency        |

---

## File Structure (What Needs to Exist)

```
backend/modules/
├── db/
│   ├── migrations/src/
│   │   └── m20260127_create_refresh_tokens_table.rs  ← NEW
│   └── entity/src/
│       ├── refresh_token.rs  ← NEW
│       ├── user.rs
│       ├── player.rs
│       └── mod.rs  ← UPDATE
├── security/src/
│   ├── token_service.rs  ← NEW
│   ├── jwt.rs
│   └── lib.rs  ← UPDATE
├── api/src/
│   ├── auth.rs  ← UPDATE (implement real logic)
│   ├── server.rs  ← UPDATE (register new routes)
│   └── auth_tests.rs  ← NEW
├── dto/src/
│   └── auth.rs  ← UPDATE (add refresh token DTOs)
└── error/src/
    └── lib.rs  ← UPDATE (add token error types)
```

---

## Critical Implementation Details

### Token Hash Storage (Security)

```rust
// NEVER store plaintext token
token_hash = sha256(token)  // Hash it
DB.insert(token_hash)        // Store hash only
// Client stores plaintext token for later refresh calls
```

### Theft Detection Logic

```rust
// On refresh attempt:
if used_at IS NOT NULL {
    // Token already used = THEFT!
    invalidate_token_family(family_id)  // Nuke entire family
    return 401 Unauthorized
}
// If we get here, token is valid
update_token.used_at = NOW   // Mark as consumed
generate_new_token_in_same_family()
```

### HTTP-Only Cookie

```rust
Cookie::build("refresh_token", token)
    .http_only(true)      // ← Prevents JS access
    .secure(true)         // ← HTTPS only (production)
    .same_site(Strict)    // ← CSRF protection
    .finish()
```

---

## Testing Strategy

### Unit Tests

- Token generation uniqueness
- Hash determinism
- Expiration validation

### Integration Tests (Most Important)

1. **Normal Flow**: login → refresh → new tokens ✓
2. **Theft Detection**: reuse old token → family invalidated ✓
3. **Logout**: revoke all tokens ✓
4. **Expiration**: expired tokens rejected ✓
5. **Concurrent**: multiple devices/families work independently ✓

---

## Dependencies to Add

```toml
# Cargo.toml entries needed
rand = "0.8"              # Random number generation
sha2 = "0.10"             # SHA256 hashing
base64 = "0.21"           # Base64 encoding
uuid = { version = "1", features = ["v4"] }  # Already present
```

---

## Success Checklist

- [ ] Refresh tokens table created with migration
- [ ] SeaORM entity for refresh_tokens
- [ ] TokenService implemented (generate, verify, invalidate)
- [ ] DTOs updated with refresh token types
- [ ] Login endpoint returns refresh token in cookie
- [ ] Refresh endpoint rotates tokens
- [ ] Token reuse detects theft and invalidates family
- [ ] Logout revokes all tokens
- [ ] 5+ integration tests passing
- [ ] Swagger documentation updated
- [ ] .env.example updated with new config vars
- [ ] PR created and linked to #93

---

## Estimated Implementation Time

| Phase | Task                        | Time           |
| ----- | --------------------------- | -------------- |
| 1     | Database migration & entity | 30 min         |
| 2     | TokenService (core logic)   | 1 hour         |
| 3     | API endpoints (handlers)    | 1.5 hours      |
| 4     | Error handling              | 15 min         |
| 5     | Configuration               | 10 min         |
| 6     | Tests (5+ tests)            | 1.5 hours      |
| -     | **Total**                   | **~4.5 hours** |

---

## Notes for Developer

1. **Token Families** - Group tokens by UUID, invalidate entire group on reuse
2. **Plaintext Never Stored** - Always hash before DB insertion
3. **Async Rust** - All DB operations are async/await
4. **Rate Limiting** - Already configured on auth endpoints (don't disable!)
5. **Testing** - Mock DB with SQLite for unit tests, real DB for integration tests
6. **Production Ready** - Security flags must be enabled in production environment

---

## Quick Links

- **Full Plan:** See `IMPLEMENTATION_PLAN.md` for detailed specs
- **Issue:** https://github.com/NOVUS-X/XLMate/issues/93
- **Branch:** `security/refresh-token-rotation`
- **Due Date:** January 31, 2026

---

**Document:** Analysis Summary  
**Version:** 1.0  
**Date:** January 27, 2026  
**Author:** Full-Stack Analysis
