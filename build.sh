#!/bin/sh
# Usage: ./build.sh          release build (bin/mob)
#        ./build.sh debug    debug build with leak tracking
#        ./build.sh test     run the test suite
set -e
cd "$(dirname "$0")"
mkdir -p bin
case "$1" in
	debug) odin build src -out:bin/mob -debug -vet-unused-imports ;;
	test)  odin test tests -out:bin/tests ;;
	*)     odin build src -out:bin/mob -o:speed ;;
esac
