#!/bin/sh
# Check GitHub Actions workflow status
echo "=== GitHub Actions Workflow Status ==="
echo ""
echo "Repository: 777qwqq/wechatmoments"
echo ""

# Get latest workflow runs
RUNS=$(curl -s "https://api.github.com/repos/777qwqq/wechatmoments/actions/runs?per_page=3")

TOTAL=$(echo "$RUNS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_count'])")

echo "Total workflow runs: $TOTAL"
echo ""

if [ "$TOTAL" -gt 0 ]; then
  LATEST_RUN=$(echo "$RUNS" | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
  STATUS=$(echo "$RUNS" | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['status'])")
  CONCLUSION=$(echo "$RUNS" | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0].get('conclusion', 'N/A'))")
  
  echo "Latest run ID: $LATEST_RUN"
  echo "Status: $STATUS"
  echo "Conclusion: $CONCLUSION"
  echo ""
  echo "Run URL: https://github.com/777qwqq/wechatmoments/actions/runs/$LATEST_RUN"
  echo ""
  
  if [ "$STATUS" = "completed" ]; then
    if [ "$CONCLUSION" = "success" ]; then
      echo "✓ Build completed successfully!"
      
      # Get artifacts
      ARTIFACTS=$(curl -s "https://api.github.com/repos/777qwqq/wechatmoments/actions/runs/$LATEST_RUN/artifacts")
      
      ARTIFACT_COUNT=$(echo "$ARTIFACTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_count'])")
      
      if [ "$ARTIFACT_COUNT" -gt 0 ]; then
        ARTIFACT_NAME=$(echo "$ARTIFACTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['artifacts'][0]['name'])")
        DOWNLOAD_URL=$(echo "$ARTIFACTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['artifacts'][0]['archive_download_url'])")
        
        echo ""
        echo "Artifact: $ARTIFACT_NAME"
        echo "Download URL: $DOWNLOAD_URL"
      fi
    else
      echo "✗ Build failed!"
    fi
  else
    echo "⏳ Build in progress..."
  fi
fi
