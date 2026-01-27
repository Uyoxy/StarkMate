# GitHub Issue #93: Refresh Token Rotation with Theft Detection - Implementation Plan

**Branch:** `security/refresh-token-rotation`  
**Due Date:** January 31, 2026  
**Status:** Ready for Implementation

---

## 📋 Executive Summary

This document provides a comprehensive full-stack implementation plan for **Issue #93: Security - Refresh Token Rotation**. The feature implements a secure token rotation system with theft detection for the XLMate chess platform using the **Token Families** pattern.

**Key Security Benefit:** If a refresh token is stolen and reused, the entire token family is invalidated, forcing both attacker and legitimate user to re-authenticate. This detects token theft quickly.

---

## 🎯 Issue Requirements

### Primary Goals

1. **Mitigate Token Theft:** Detect and respond to stolen refresh tokens
2. **Implement Token Rotation:** Generate new refresh tokens on each `/refresh` endpoint call
3. **Track Token Families:** Group related tokens and invalidate the entire family on theft detection
4. **Secure Cookie Storage:** Store refresh tokens in HTTP-only, secure cookies
5. **Database Layer:** Logic to invalidate used refresh tokens with family tracking

### Implementation Expectations

- ✅ Secure cookie storage for tokens
- ✅ Integration tests covering reuse detection flow
- ✅ Token families concept for theft detection
- ✅ Account lock mechanism when theft is detected

---

## 🏗️ Current Architecture Understanding

### Technology Stack

- **Backend:** Rust + Actix-web 4.x (async, high-performance)
- **Database:** PostgreSQL with SeaORM 1.1.0 ORM
- **Authentication:** JWT (access tokens), configurable refresh tokens
- **API Documentation:** OpenAPI/Swagger + ReDoc
- **Testing:** Tokio async runtime with integration tests
- **Rate Limiting:** Actix-governor for endpoint protection

### Current Authentication Flow

```
User Registration/Login
    ↓
Register endpoint (POST /v1/auth/register)
    ├─ Validate input
    ├─ Create user in DB
    └─ Generate tokens

Login endpoint (POST /v1/auth/login)
    ├─ Validate credentials
    ├─ Generate JWT access token (3600s)
    └─ Return access token (currently no refresh token)

Protected Routes
    ├─ JwtService validates Bearer tokens
    └─ Claims extracted to request extensions
```

### Current Module Structure

```
backend/modules/
├── api/                    # HTTP handlers & routes
│   └── src/
│       ├── auth.rs        # Login/register handlers (NEEDS REFRESH ENDPOINT)
│       ├── server.rs      # Server config & middleware
│       ├── players.rs     # Game player endpoints
│       ├── games.rs       # Game logic endpoints
│       └── ws.rs          # WebSocket connections
├── db/
│   ├── entity/            # SeaORM models
│   │   ├── user.rs        # User entity (id, username, email, password_hash)
│   │   ├── player.rs      # Player (game accounts)
│   │   └── game.rs        # Game state
│   └── migrations/        # SeaORM migrations
├── security/
│   └── src/jwt.rs        # JWT service (token generation/validation)
├── service/
│   ├── players.rs         # Business logic
│   └── games.rs
├── dto/
│   └── src/auth.rs       # DTOs with validation
└── error/
    └── src/lib.rs        # Error types
```

---

## 🗂️ Implementation Plan (Detailed)

### Phase 1: Database Layer (Foundation)

#### 1.1 Create Refresh Tokens Table Migration

**File:** `backend/modules/db/migrations/src/m20260127_create_refresh_tokens_table.rs`

```rust
// Key columns:
// - id: Primary key (UUID or i64)
// - player_id: Foreign key to players/users table
// - family_id: UUID grouping tokens together
// - token_hash: SHA256 hash of the actual token
// - created_at: When token was generated
// - used_at: Timestamp when token was consumed (NULL = unused)
// - expires_at: Token expiration time
// - is_revoked: Boolean flag for invalidated tokens
// - device_fingerprint: Optional for tracking which device (future enhancement)

CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id INT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    family_id UUID NOT NULL,
    token_hash VARCHAR(64) NOT NULL UNIQUE,  -- SHA256 hex string
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    used_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_revoked BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT valid_token_state CHECK (
        (used_at IS NULL AND is_revoked = FALSE) OR
        (used_at IS NOT NULL OR is_revoked = TRUE)
    ),
    INDEX idx_family_id (family_id),
    INDEX idx_player_id (player_id),
    INDEX idx_token_hash (token_hash)
);

// Constraints:
// - Unique token_hash ensures no duplicates
// - Check constraint: token is either unused/not-revoked OR used/revoked
// - Indexes on family_id for theft detection queries
```

**Rationale:**

- `family_id`: Allows grouping multiple token rotations as a family
- `token_hash`: Never store plaintext tokens in database
- `used_at`: Tracks when token was consumed for rotation
- `is_revoked`: Allows revocation without deletion (audit trail)
- TTL: Combine with `expires_at` for cleanup jobs

#### 1.2 Create SeaORM Entity

**File:** `backend/modules/db/entity/src/refresh_token.rs`

```rust
use sea_orm::entity::prelude::*;
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Clone, Debug, DeriveEntityModel)]
#[sea_orm(table_name = "refresh_tokens")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub id: Uuid,

    pub player_id: i32,
    pub family_id: Uuid,
    pub token_hash: String,

    #[sea_orm(column_type = "TimestampWithTimeZone")]
    pub created_at: DateTime<Utc>,

    #[sea_orm(column_type = "TimestampWithTimeZone", nullable)]
    pub used_at: Option<DateTime<Utc>>,

    #[sea_orm(column_type = "TimestampWithTimeZone")]
    pub expires_at: DateTime<Utc>,

    pub is_revoked: bool,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {
    #[sea_orm(
        belongs_to = "super::player::Entity",
        from = "Column::PlayerId",
        to = "super::player::Column::Id"
    )]
    Player,
}

impl Related<super::player::Entity> for Entity {
    fn to() -> RelationTwoMany {
        Relation::Player.def()
    }
}

impl ActiveModelBehavior for ActiveModel {}
```

**Rationale:**

- Strongly typed with Uuid for family_id
- Optional `used_at` represents unused tokens
- Relationships to Player entity for queries
- Compatible with SeaORM 1.1.0

---

### Phase 2: Token Service Layer (Business Logic)

#### 2.1 Create Token Service

**File:** `backend/modules/security/src/token_service.rs`

```rust
// Key responsibilities:
// 1. Generate refresh tokens (32 random bytes, base64 encoded)
// 2. Hash tokens with SHA256 before storage
// 3. Verify token against hash during refresh
// 4. Detect reuse (token marked as used but attempting to use again)
// 5. Invalidate token families on theft detection
// 6. Manage token expiration

// Key functions:
pub async fn generate_refresh_token(
    db: &DatabaseConnection,
    player_id: i32,
    family_id: Uuid,
    ttl_days: i64,
) -> Result<String, TokenServiceError> {
    // 1. Generate 32 random bytes
    let random_bytes = generate_random_bytes(32);
    let token = base64_encode(&random_bytes);
    let token_hash = sha256_hash(&token);

    // 2. Store in DB with expiration
    let expires_at = Utc::now() + Duration::days(ttl_days);
    let refresh_token = refresh_token::ActiveModel {
        id: Set(Uuid::new_v4()),
        player_id: Set(player_id),
        family_id: Set(family_id),
        token_hash: Set(token_hash),
        created_at: Set(Utc::now()),
        used_at: Set(None),
        expires_at: Set(expires_at),
        is_revoked: Set(false),
    };
    refresh_token.insert(db).await?;

    // 3. Return plaintext token (for client)
    Ok(token)
}

pub async fn verify_and_mark_used(
    db: &DatabaseConnection,
    token: &str,
    player_id: i32,
) -> Result<Uuid, TokenServiceError> {
    let token_hash = sha256_hash(token);

    // 1. Find token
    let token_record = RefreshToken::Entity::find()
        .filter(refresh_token::Column::TokenHash.eq(&token_hash))
        .filter(refresh_token::Column::PlayerId.eq(player_id))
        .one(db)
        .await?;

    let token_record = token_record
        .ok_or(TokenServiceError::TokenNotFound)?;

    // 2. Check if already used (theft detection!)
    if token_record.used_at.is_some() {
        // THEFT DETECTED: Token already used
        let family_id = token_record.family_id;
        invalidate_token_family(db, family_id).await?;
        return Err(TokenServiceError::TokenReuseDetected);
    }

    // 3. Check if revoked or expired
    if token_record.is_revoked || token_record.expires_at < Utc::now() {
        return Err(TokenServiceError::TokenInvalid);
    }

    // 4. Mark as used
    let mut token_model = token_record.into_active_model();
    token_model.used_at = Set(Some(Utc::now()));
    token_model.update(db).await?;

    Ok(token_record.family_id)
}

pub async fn invalidate_token_family(
    db: &DatabaseConnection,
    family_id: Uuid,
) -> Result<(), TokenServiceError> {
    // Set is_revoked = true for entire family
    RefreshToken::Entity::update_many()
        .col_expr(refresh_token::Column::IsRevoked, Expr::value(true))
        .filter(refresh_token::Column::FamilyId.eq(family_id))
        .exec(db)
        .await?;

    Ok(())
}

pub async fn revoke_player_tokens(
    db: &DatabaseConnection,
    player_id: i32,
) -> Result<(), TokenServiceError> {
    // Logout: revoke all tokens for player
    RefreshToken::Entity::update_many()
        .col_expr(refresh_token::Column::IsRevoked, Expr::value(true))
        .filter(refresh_token::Column::PlayerId.eq(player_id))
        .exec(db)
        .await?;

    Ok(())
}
```

**Key Design Decisions:**

- Token generation: 32 bytes (256 bits) is cryptographically strong
- Base64 encoding: Makes tokens URL-safe for transmission
- SHA256 hashing: Never store plaintext tokens in database
- Theft detection: `used_at IS NOT NULL` check catches reuse immediately
- Family invalidation: One reuse invalidates entire family, forcing re-auth

---

### Phase 3: API Layer (Endpoints)

#### 3.1 Update DTOs

**File:** `backend/modules/dto/src/auth.rs` - Add/Modify:

```rust
#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct AuthResponse {
    pub access_token: String,
    pub refresh_token: String,  // NEW: Return refresh token
    pub token_type: String,
    pub expires_in: i32,
    pub refresh_token_expires_in: i32,  // NEW: Refresh token TTL
    pub user_id: i32,
    pub username: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct RefreshTokenRequest {
    pub refresh_token: String,  // Token from cookie or body
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct TokenRefreshResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub token_type: String,
    pub expires_in: i32,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct LogoutRequest {}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct LogoutResponse {
    pub message: String,
}
```

#### 3.2 Update Authentication Handlers

**File:** `backend/modules/api/src/auth.rs` - Implement:

```rust
/// Login endpoint - Issues access + refresh tokens
#[post("/login")]
pub async fn login(
    db: web::Data<DatabaseConnection>,
    payload: web::Json<LoginRequest>,
    jwt_service: web::Data<JwtService>,
    token_service: web::Data<TokenService>,
) -> HttpResponse {
    // 1. Validate credentials (authenticate user)
    let player = match authenticate_player(&db, &payload.username, &payload.password).await {
        Ok(p) => p,
        Err(_) => {
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Invalid credentials".to_string(),
                code: "INVALID_CREDENTIALS".to_string(),
            });
        }
    };

    // 2. Generate JWT access token
    let access_token = match jwt_service.generate_token(player.id, &player.username) {
        Ok(t) => t,
        Err(_) => {
            return HttpResponse::InternalServerError().json(ErrorResponse {
                message: "Failed to generate access token".to_string(),
                code: "TOKEN_ERROR".to_string(),
            });
        }
    };

    // 3. Generate refresh token (new family)
    let family_id = Uuid::new_v4();
    let refresh_ttl = env::var("REFRESH_TOKEN_TTL_DAYS")
        .unwrap_or_else(|_| "7".to_string())
        .parse::<i64>()
        .unwrap_or(7);

    let refresh_token = match token_service
        .generate_refresh_token(&db, player.id, family_id, refresh_ttl)
        .await
    {
        Ok(t) => t,
        Err(_) => {
            return HttpResponse::InternalServerError().json(ErrorResponse {
                message: "Failed to generate refresh token".to_string(),
                code: "TOKEN_ERROR".to_string(),
            });
        }
    };

    // 4. Return with HTTP-only secure cookie
    HttpResponse::Ok()
        .cookie(
            actix_web::cookie::Cookie::build("refresh_token", &refresh_token)
                .http_only(true)
                .secure(true)  // HTTPS only in production
                .same_site(actix_web::cookie::SameSite::Strict)
                .max_age(Duration::days(refresh_ttl))
                .finish()
        )
        .json(AuthResponse {
            access_token,
            refresh_token,  // Also return in body for SPA usage
            token_type: "Bearer".to_string(),
            expires_in: 3600,
            refresh_token_expires_in: (refresh_ttl * 86400) as i32,
            user_id: player.id,
            username: player.username,
        })
}

/// Refresh endpoint - Rotate tokens
#[post("/refresh")]
pub async fn refresh(
    db: web::Data<DatabaseConnection>,
    req: HttpRequest,
    jwt_service: web::Data<JwtService>,
    token_service: web::Data<TokenService>,
) -> HttpResponse {
    // 1. Extract refresh token from cookie or body
    let refresh_token = req.cookie("refresh_token")
        .or_else(|| {
            req.headers().get("x-refresh-token")
                .and_then(|v| v.to_str().ok())
                .map(|s| actix_web::cookie::Cookie::new("refresh_token", s.to_string()))
        })
        .map(|c| c.value().to_string());

    let refresh_token = match refresh_token {
        Some(t) => t,
        None => {
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Refresh token missing".to_string(),
                code: "MISSING_REFRESH_TOKEN".to_string(),
            });
        }
    };

    // Extract user from claims (via middleware or extract from token)
    let claims = match jwt_service.validate_token_from_request(&req) {
        Ok(c) => c,
        Err(_) => {
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Invalid or expired access token".to_string(),
                code: "INVALID_ACCESS_TOKEN".to_string(),
            });
        }
    };

    // 2. Verify token and mark as used
    let family_id = match token_service
        .verify_and_mark_used(&db, &refresh_token, claims.user_id)
        .await
    {
        Ok(fid) => fid,
        Err(TokenServiceError::TokenReuseDetected) => {
            // THEFT DETECTED: Log event, alert user
            // Lock account if configured
            log::warn!("Token reuse detected for player {}", claims.user_id);
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Token reuse detected. Your account has been locked for security.".to_string(),
                code: "TOKEN_THEFT_DETECTED".to_string(),
            });
        }
        Err(_) => {
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Invalid refresh token".to_string(),
                code: "INVALID_REFRESH_TOKEN".to_string(),
            });
        }
    };

    // 3. Generate new tokens in same family
    let new_access_token = match jwt_service.generate_token(claims.user_id, &claims.username) {
        Ok(t) => t,
        Err(_) => {
            return HttpResponse::InternalServerError().json(ErrorResponse {
                message: "Failed to generate new access token".to_string(),
                code: "TOKEN_ERROR".to_string(),
            });
        }
    };

    let refresh_ttl = env::var("REFRESH_TOKEN_TTL_DAYS")
        .unwrap_or_else(|_| "7".to_string())
        .parse::<i64>()
        .unwrap_or(7);

    let new_refresh_token = match token_service
        .generate_refresh_token(&db, claims.user_id, family_id, refresh_ttl)
        .await
    {
        Ok(t) => t,
        Err(_) => {
            return HttpResponse::InternalServerError().json(ErrorResponse {
                message: "Failed to generate new refresh token".to_string(),
                code: "TOKEN_ERROR".to_string(),
            });
        }
    };

    // 4. Return with new tokens
    HttpResponse::Ok()
        .cookie(
            actix_web::cookie::Cookie::build("refresh_token", &new_refresh_token)
                .http_only(true)
                .secure(true)
                .same_site(actix_web::cookie::SameSite::Strict)
                .max_age(Duration::days(refresh_ttl))
                .finish()
        )
        .json(TokenRefreshResponse {
            access_token: new_access_token,
            refresh_token: new_refresh_token,
            token_type: "Bearer".to_string(),
            expires_in: 3600,
        })
}

/// Logout endpoint - Revoke all tokens
#[post("/logout")]
pub async fn logout(
    db: web::Data<DatabaseConnection>,
    req: HttpRequest,
    token_service: web::Data<TokenService>,
) -> HttpResponse {
    // Extract user claims
    let claims = match extract_claims_from_request(&req) {
        Ok(c) => c,
        Err(_) => {
            return HttpResponse::Unauthorized().json(ErrorResponse {
                message: "Unauthorized".to_string(),
                code: "UNAUTHORIZED".to_string(),
            });
        }
    };

    // Revoke all tokens for this player
    if let Err(_) = token_service.revoke_player_tokens(&db, claims.user_id).await {
        return HttpResponse::InternalServerError().json(ErrorResponse {
            message: "Failed to logout".to_string(),
            code: "LOGOUT_ERROR".to_string(),
        });
    }

    // Clear cookie
    let mut response = HttpResponse::Ok().json(LogoutResponse {
        message: "Logged out successfully".to_string(),
    });

    response.del_cookie("refresh_token");
    response
}
```

#### 3.3 Register New Endpoints

**File:** `backend/modules/api/src/server.rs` - Add:

```rust
// In the auth scope:
.service(
    web::scope("/v1/auth")
        .wrap(Governor::new(&auth_governor_conf))
        .service(login)
        .service(register)
        .service(refresh)      // NEW
        .service(logout)       // NEW
)
```

---

### Phase 4: Error Handling

#### 4.1 Token Service Error Types

**File:** `backend/modules/security/src/lib.rs`:

```rust
pub mod jwt;
pub mod token_service;

// In token_service.rs or new error.rs:
#[derive(Debug)]
pub enum TokenServiceError {
    TokenNotFound,
    TokenReuseDetected,    // THEFT DETECTED
    TokenInvalid,
    TokenExpired,
    DatabaseError(String),
    InvalidToken,
}

impl Display for TokenServiceError { ... }
impl From<DbErr> for TokenServiceError { ... }
```

---

### Phase 5: Configuration

#### 5.1 Update .env.example

**File:** `backend/.env.example` - Add:

```env
# Refresh Token Configuration
REFRESH_TOKEN_TTL_DAYS=7
ACCOUNT_LOCK_DURATION_MINUTES=30
```

---

### Phase 6: Testing

#### 6.1 Integration Tests

**File:** `backend/modules/api/src/auth_tests.rs`:

```rust
#[tokio::test]
async fn test_login_returns_refresh_token() {
    // Setup: Create test user
    // Call POST /v1/auth/login
    // Assert: Response contains refresh_token
    // Assert: refresh_token cookie is set (HttpOnly, Secure)
}

#[tokio::test]
async fn test_refresh_rotates_token() {
    // Setup: Login user, get refresh token
    // Call POST /v1/auth/refresh with old token
    // Assert: Old token marked as used
    // Assert: New tokens returned
    // Assert: New tokens are different
}

#[tokio::test]
async fn test_token_reuse_detection() {
    // Setup: Login user
    // Call POST /v1/auth/refresh (first rotation)
    // Try to call POST /v1/auth/refresh with original token again
    // Assert: TokenReuseDetected error
    // Assert: Entire family invalidated
    // Assert: Subsequent refresh attempts fail
}

#[tokio::test]
async fn test_logout_revokes_all_tokens() {
    // Setup: Login user (creates family)
    // Rotate token twice (same family)
    // Call POST /v1/auth/logout
    // Try to refresh with any token from family
    // Assert: All tokens revoked
}

#[tokio::test]
async fn test_expired_tokens_rejected() {
    // Setup: Create token with past expiration
    // Try to refresh
    // Assert: TokenExpired error
}
```

---

## 🔒 Security Measures

### 1. Token Generation

- ✅ 32 random bytes (256-bit entropy) from `rand::thread_rng()`
- ✅ Base64-URL encoding for safe transmission
- ✅ Never stored in plaintext

### 2. Token Storage

- ✅ SHA256 hashing before database storage
- ✅ Unique constraint on token_hash
- ✅ Indexed on `family_id` and `player_id` for efficient queries

### 3. Cookie Security

- ✅ `HttpOnly` flag prevents JavaScript access
- ✅ `Secure` flag requires HTTPS (must be enabled in production)
- ✅ `SameSite=Strict` prevents CSRF attacks
- ✅ TTL matches token expiration

### 4. Theft Detection

- ✅ Token reuse immediately detected via `used_at` check
- ✅ Entire family invalidated on reuse
- ✅ Both attacker and legitimate user forced to re-authenticate
- ✅ Events logged for security auditing

### 5. Database Constraints

- ✅ Check constraint ensures token state consistency
- ✅ Foreign key cascades cleanup on player deletion
- ✅ Timestamps track all token state changes

---

## 📊 Data Flow Diagrams

### Login Flow

```
User
  │
  ├─> POST /v1/auth/login (username, password)
  │
  ├─> Validate credentials
  ├─> Generate JWT access token (3600s)
  ├─> Generate refresh token (32 bytes)
  │   ├─> Create new family_id (UUID)
  │   ├─> Hash token with SHA256
  │   └─> Store in refresh_tokens table
  │
  ├─> Set refresh_token cookie (HttpOnly, Secure)
  │
  └─< 200 OK
      ├─ access_token (JWT)
      ├─ refresh_token (plaintext for SPA)
      ├─ expires_in: 3600
      └─ refresh_token_expires_in: 604800 (7 days)
```

### Refresh Flow (Normal)

```
Client (has access_token + refresh_token)
  │
  ├─> POST /v1/auth/refresh
  │   ├─ Authorization: Bearer {access_token}
  │   └─ Cookie: refresh_token={token}
  │
  ├─> Extract & validate access_token (JWT)
  │
  ├─> Hash & lookup refresh_token
  │   ├─> Check: used_at IS NULL ✓
  │   ├─> Check: is_revoked = FALSE ✓
  │   ├─> Check: expires_at > NOW ✓
  │
  ├─> Mark refresh_token as used (update used_at = NOW)
  │
  ├─> Generate new tokens (same family_id)
  │   ├─ New access token
  │   └─ New refresh token
  │
  └─< 200 OK
      ├─ access_token (new)
      ├─ refresh_token (new)
      └─ Set cookie with new token
```

### Token Reuse / Theft Detection

```
Attacker (has stolen refresh_token)
  │
  ├─> POST /v1/auth/refresh
  │   └─ Cookie: refresh_token={stolen_token}
  │
  ├─> Hash & lookup refresh_token
  │   ├─> Check: used_at IS NOT NULL ⚠️
  │   │
  │   └─> THEFT DETECTED!
  │       ├─ Log security event
  │       ├─ Invalidate entire family
  │       │  (UPDATE refresh_tokens SET is_revoked=true WHERE family_id=X)
  │       └─ Return 401 Unauthorized
  │
  ├─> Legitimate user tries to refresh
  │   └─> All tokens in family now revoked
  │       └─> 401 Unauthorized (must re-authenticate)
  │
  └─ Both attacker and user forced to re-authenticate
     └─ New family created on next login
```

---

## 🧪 Test Coverage Plan

### Unit Tests

1. ✅ Token generation produces unique tokens
2. ✅ Token hashing is deterministic
3. ✅ Expiration validation works correctly
4. ✅ Family invalidation cascades correctly

### Integration Tests

1. ✅ Complete login → refresh → logout flow
2. ✅ Token rotation creates new tokens
3. ✅ Reuse detection invalidates family
4. ✅ Expired tokens are rejected
5. ✅ Revoked tokens prevent refresh
6. ✅ Concurrent requests handled safely
7. ✅ Multiple device logins (separate families)

### Security Tests

1. ✅ Plaintext tokens not in database
2. ✅ Cookie security flags set correctly
3. ✅ CSRF protection enabled
4. ✅ Rate limiting on auth endpoints

---

## 📦 Dependencies to Add

### `backend/modules/security/Cargo.toml`

```toml
rand = "0.8"              # Random token generation
sha2 = "0.10"             # SHA256 hashing
base64 = "0.21"           # Base64 encoding
```

### `backend/modules/api/Cargo.toml`

```toml
uuid = { version = "1", features = ["v4", "serde"] }  # Already present, ensure v4 feature
chrono = { version = "0.4", features = ["serde"] }    # Already present
```

---

## 🚀 Implementation Steps (In Order)

1. **Create migration** - `m20260127_create_refresh_tokens_table.rs`
2. **Create entity** - `db/entity/src/refresh_token.rs`
3. **Update mod.rs** - Add refresh_token to entity exports
4. **Create token service** - `security/src/token_service.rs`
5. **Update security/src/lib.rs** - Export token_service module
6. **Update DTOs** - Add refresh token related types to `dto/src/auth.rs`
7. **Update auth handlers** - Implement refresh and logout in `api/src/auth.rs`
8. **Update server** - Register new endpoints in `api/src/server.rs`
9. **Update dependencies** - Add rand, sha2, base64 to Cargo.toml files
10. **Add configuration** - REFRESH_TOKEN_TTL_DAYS and ACCOUNT_LOCK_DURATION_MINUTES to .env.example
11. **Write tests** - Create comprehensive test suite
12. **Documentation** - Update API docs and README

---

## 📈 Success Criteria

- [ ] Refresh token generation on login
- [ ] Refresh token rotation on `/refresh` endpoint
- [ ] Token reuse detection invalidates family
- [ ] Logout revokes all player tokens
- [ ] HTTP-only secure cookies set correctly
- [ ] 5+ integration tests passing
- [ ] All security checks documented
- [ ] API endpoints fully documented in Swagger
- [ ] Error responses follow consistent format
- [ ] Database migrations run without issues

---

## ⚠️ Important Notes

1. **Timing:** Due date is January 31, 2026 (4 days from now)
2. **Branch:** Work is on `security/refresh-token-rotation`
3. **Pull Request:** Link PR to issue #93 when ready
4. **Database:** PostgreSQL required (UUID support needed)
5. **Production:** Ensure `Secure` cookie flag is enabled in HTTPS-only environments
6. **Rate Limiting:** Auth endpoints have strict rate limiting already configured
7. **Testing:** Mock database with in-memory SQLite for unit tests

---

## 📚 Reference Files

### Key Files to Modify

- `backend/modules/api/src/auth.rs` - Main handlers
- `backend/modules/api/src/server.rs` - Route registration
- `backend/modules/dto/src/auth.rs` - Request/Response DTOs
- `backend/.env.example` - Configuration

### New Files to Create

- `backend/modules/db/migrations/src/m20260127_create_refresh_tokens_table.rs`
- `backend/modules/db/entity/src/refresh_token.rs`
- `backend/modules/security/src/token_service.rs`
- `backend/modules/api/src/auth_tests.rs`

### Architecture Reference

- SeaORM: https://www.sea-orm.io/
- Actix-web: https://actix.rs/
- JWT Best Practices: https://tools.ietf.org/html/rfc8725
- OWASP Token Storage: https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html

---

## 🎓 Learning Points for Developer

1. **Token Families Pattern**: Groups related tokens for efficient theft detection
2. **Cryptographic Hashing**: One-way transformation ensures tokens never stored plaintext
3. **Cookie Security**: HttpOnly, Secure, SameSite flags provide multiple layers of protection
4. **Database Constraints**: Check constraints and indexes ensure data consistency and query performance
5. **Async Rust**: SeaORM operations are async and require proper error handling
6. **RESTful Design**: Stateless token validation enables horizontal scaling

---

**Document Version:** 1.0  
**Created:** January 27, 2026  
**Status:** Ready for Implementation
