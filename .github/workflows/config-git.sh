#!/bin/sh
# Git config for GitHub Actions
git config --global user.email "243122037@qq.com"
git config --global user.name "GitHub Actions"
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
