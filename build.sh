#! /usr/bin/env bash

zig build-lib main.zig -target wasm32-freestanding --single-threaded -OReleaseSafe