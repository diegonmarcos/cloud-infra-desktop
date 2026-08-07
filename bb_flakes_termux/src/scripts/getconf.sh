#!/usr/bin/env bash
case "$1" in
  LONG_BIT)       echo 64 ;;
  PAGE_SIZE)      echo 4096 ;;
  _NPROCESSORS_ONLN) nproc 2>/dev/null || echo 1 ;;
  *)              echo "" ;;
esac
