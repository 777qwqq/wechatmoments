DEBUG ?= 0
FINALPACKAGE ?= 1
ARCHS = arm64 arm64e

# 所有打包方案统一 iOS 15 起步，与 tweak.json / control 的声明保持一致。
TARGET = iphone:clang:16.5:15.0
