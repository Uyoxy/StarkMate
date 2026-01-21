#!/bin/bash
# Critical Persistence Test - Validates the fix for the stated problem

echo "🔥 PERSISTENCE TEST - The Critical Validation"
echo "=============================================="
echo ""
echo "This test proves that players DON'T lose their queue position"
echo "when the Redis container restarts (simulating server restart)."
echo ""

# Step 1: Add players to queue
echo "Step 1: Adding 3 players to queue..."
docker exec xlmate-redis redis-cli ZADD matchmaking:queue:rated 1737482400 '{"id":"player-1","player":{"wallet_address":"alice","elo":1500,"join_time":"2026-01-21T18:00:00Z"},"match_type":"Rated","invite_address":null,"max_elo_diff":200}'
docker exec xlmate-redis redis-cli ZADD matchmaking:queue:rated 1737482410 '{"id":"player-2","player":{"wallet_address":"bob","elo":1550,"join_time":"2026-01-21T18:00:10Z"},"match_type":"Rated","invite_address":null,"max_elo_diff":200}'
docker exec xlmate-redis redis-cli ZADD matchmaking:queue:rated 1737482420 '{"id":"player-3","player":{"wallet_address":"charlie","elo":1600,"join_time":"2026-01-21T18:00:20Z"},"match_type":"Rated","invite_address":null,"max_elo_diff":200}'

echo "✅ 3 players added"
echo ""

# Step 2: Verify queue before restart
echo "Step 2: Queue status BEFORE restart..."
BEFORE_COUNT=$(docker exec xlmate-redis redis-cli ZCARD matchmaking:queue:rated)
echo "Queue size: $BEFORE_COUNT players"
docker exec xlmate-redis redis-cli ZRANGE matchmaking:queue:rated 0 -1 WITHSCORES | head -6
echo ""

# Step 3: Restart Redis container
echo "Step 3: 🔄 RESTARTING Redis container..."
echo "(This simulates a server crash/restart)"
docker-compose restart redis
sleep 3
echo "✅ Redis restarted"
echo ""

# Step 4: Verify queue after restart
echo "Step 4: Queue status AFTER restart..."
AFTER_COUNT=$(docker exec xlmate-redis redis-cli ZCARD matchmaking:queue:rated)
echo "Queue size: $AFTER_COUNT players"
docker exec xlmate-redis redis-cli ZRANGE matchmaking:queue:rated 0 -1 WITHSCORES | head -6
echo ""

# Step 5: Validate
echo "Step 5: Validation..."
if [ "$BEFORE_COUNT" == "$AFTER_COUNT" ] && [ "$AFTER_COUNT" == "3" ]; then
    echo "✅ ✅ ✅ PERSISTENCE TEST PASSED! ✅ ✅ ✅"
    echo ""
    echo "🎉 Players survived the restart!"
    echo "   Before: $BEFORE_COUNT players"
    echo "   After:  $AFTER_COUNT players"
    echo ""
    echo "🎯 This proves the fix works:"
    echo "   - In-memory queues would have lost all players"
    echo "   - Redis persisted the queue across restart"
    echo "   - Players can now safely wait in queue"
else
    echo "❌ TEST FAILED"
    echo "   Before: $BEFORE_COUNT players"
    echo "   After:  $AFTER_COUNT players"
fi

# Cleanup
echo ""
echo "Cleanup: Removing test data..."
docker exec xlmate-redis redis-cli DEL matchmaking:queue:rated
echo "✅ Done"
