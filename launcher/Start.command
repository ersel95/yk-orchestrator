#!/usr/bin/env bash
# YK Orchestrator — Terminal'de çift tıkla başlatıcı
# Terminal'in Desktop yetkisi olduğu için TCC sorununu yaşamaz.
SELF="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SELF/.startup.sh"
