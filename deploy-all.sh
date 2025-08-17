#!/bin/bash

# Deploy All Script - Commits, pushes, and deploys to dev and prod simultaneously

set -e

echo "🚀 Starting deployment process..."

# Check if there are any changes to commit
if [[ -n $(git status --porcelain) ]]; then
    echo "📝 Changes detected, committing and pushing..."
    
    # Add all changes
    git add .
    
    # Create commit with timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    git commit -m "Deploy: $TIMESTAMP

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>"
    
    # Push to remote
    git push
    echo "✅ Changes committed and pushed"
else
    echo "ℹ️  No changes to commit, proceeding with deployment..."
fi

# Create log directory if it doesn't exist
mkdir -p logs

# Start deployments in parallel
echo "🔄 Starting parallel deployments..."

# Deploy to dev in background
echo "🟡 Starting dev deployment..."
./scripts/deploy.sh dev > logs/deploy-dev.log 2>&1 &
DEV_PID=$!

# Deploy to prod in background  
echo "🔴 Starting prod deployment..."
./scripts/deploy.sh prod > logs/deploy-prod.log 2>&1 &
PROD_PID=$!

echo "📋 Deployment processes started:"
echo "   Dev PID: $DEV_PID (logs: logs/deploy-dev.log)"
echo "   Prod PID: $PROD_PID (logs: logs/deploy-prod.log)"
echo ""
echo "💡 Monitor progress with:"
echo "   tail -f logs/deploy-dev.log"
echo "   tail -f logs/deploy-prod.log"
echo ""
echo "🔍 Check status with:"
echo "   ps -p $DEV_PID $PROD_PID"
echo ""

# Function to check deployment status
check_status() {
    local pid=$1
    local env=$2
    
    if kill -0 $pid 2>/dev/null; then
        echo "🟡 $env deployment still running (PID: $pid)"
        return 1
    else
        wait $pid
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo "✅ $env deployment completed successfully"
        else
            echo "❌ $env deployment failed (exit code: $exit_code)"
        fi
        return $exit_code
    fi
}

# Wait for deployments to complete (optional - comment out if you want to detach immediately)
echo "⏳ Waiting for deployments to complete..."
echo "   (Press Ctrl+C to detach and let deployments run in background)"

trap 'echo "🔌 Detaching from deployments... They will continue running in background"; exit 0' INT

DEV_DONE=false
PROD_DONE=false

while [ "$DEV_DONE" = false ] || [ "$PROD_DONE" = false ]; do
    if [ "$DEV_DONE" = false ]; then
        if ! check_status $DEV_PID "Dev"; then
            sleep 5
        else
            DEV_DONE=true
        fi
    fi
    
    if [ "$PROD_DONE" = false ]; then
        if ! check_status $PROD_PID "Prod"; then
            sleep 5
        else
            PROD_DONE=true
        fi
    fi
done

echo ""
echo "🎉 All deployments completed!"
echo "📊 Check final logs:"
echo "   Dev: logs/deploy-dev.log"
echo "   Prod: logs/deploy-prod.log"