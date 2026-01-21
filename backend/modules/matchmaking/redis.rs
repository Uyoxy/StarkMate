use deadpool_redis::{Config, Pool, Runtime};
use redis::AsyncCommands;

/// Creates a Redis connection pool from a Redis URL
pub fn create_redis_pool(redis_url: &str) -> Result<Pool, Box<dyn std::error::Error>> {
    let cfg = Config::from_url(redis_url);
    let pool = cfg.create_pool(Some(Runtime::Tokio1))?;
    Ok(pool)
}

/// Tests the Redis connection by sending a PING command
pub async fn test_redis_connection(pool: &Pool) -> Result<(), String> {
    let mut conn = pool
        .get()
        .await
        .map_err(|e| format!("Failed to get Redis connection: {}", e))?;

    redis::cmd("PING")
        .query_async::<_, String>(&mut conn)
        .await
        .map_err(|e| format!("Redis PING failed: {}", e))?;

    Ok(())
}
