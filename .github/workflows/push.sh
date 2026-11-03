#!/bin/sh
# Configure Git for GitHub Actions
git config --global user.email "243122037@qq.com"
git config --global user.name "GitHub Actions"
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > ~/.git-credentials

# Add and commit workflow file
git add .github/workflows/build.yml
git add .github/workflows/config-git.sh
git add .github/workflows/push.sh

# Create commit
COMMIT_MSG="Add GitHub Actions workflow for WeChat Moments tweak build"
git commit -m "$COMMIT_MSG" || echo "No changes to commit"

# Push to GitHub
git push origin main || git push origin master

echo "Workflow pushed successfully!"
