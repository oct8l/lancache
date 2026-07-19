#!/usr/bin/env python3
"""Regenerates fixture.bin: a deterministic 2.5MB binary fixture used by the
cache integration test. Spans more than two 1MB proxy_cache slices so range
requests can exercise multi-slice assembly. Re-run this and commit the result
if the fixture ever needs to change; it must stay reproducible from the fixed
seed below so the checked-in checksum keeps matching.
"""
import random

SEED = 1337
SIZE = 2_500_000
OUTPUT = "fixture.bin"

random.seed(SEED)
with open(OUTPUT, "wb") as f:
    f.write(bytes(random.getrandbits(8) for _ in range(SIZE)))
