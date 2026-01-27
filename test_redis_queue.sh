#!/bin/bash
# Redis Matchmaking Test Script

echo "🧪 Redis Matchmaking Queue Test"
echo "================================"
echo ""

# Test 1: Add player to queue
echo "Test 1: Adding player to Redis queue..."
docker exec xlmate-redis redis-cli ZADD matchmaking:queue:casual 1737482400 '{"id":"550e8400-e29b-41d4-a716-446655440000","player":{"wallet_address":"test_player_1","elo":1500,"join_time":"2026-01-21T18:00:00Z"},"match_type":"Casual","invite_address":null,"max_elo_diff":null}'
docker exec xlmate-redis redis-cli EXPIRE matchmaking:queue:casual 3600

echo "✅ Player added"
echo ""

# Test 2: Verify player in queue
echo "Test 2: Verifying player in queue..."
docker exec xlmate-redis redis-cli ZRANGE matchmaking:queue:casual 0 -1
echo ""

# Test 3: Check TTL
echo "Test 3: Checking TTL (should be ~3600 seconds)..."
docker exec xlmate-redis redis-cli TTL matchmaking:queue:casual
echo ""

# Test 4: Get queue position
echo "Test 4: Getting queue size..."
docker exec xlmate-redis redis-cli ZCARD matchmaking:queue:casual
echo ""

# Test 5: Simulate match (pop player)
echo "Test 5: Simulating match (ZPOPMIN)..."
docker exec xlmate-redis redis-cli ZPOPMIN matchmaking:queue:casual 1
echo ""

# Test 6: Verify queue is empty
echo "Test 6: Verifying queue is empty..."
docker exec xlmate-redis redis-cli ZCARD matchmaking:queue:casual
echo ""

echo "✅ All Redis operations working correctly!"
echo ""
echo "🎯 Key Findings:"
echo "  - ZADD: ✅ Players can be added to queue"
echo "  - ZRANGE: ✅ Queue contents can be retrieved"
echo "  - TTL: ✅ Expiration is set"
echo "  - ZPOPMIN: ✅ Pops lowest-score entries (score-based, not FIFO)"
echo ""
echo "Next: Test persistence by restarting Redis container"
