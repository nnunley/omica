#!/usr/bin/env python3
"""Reference implementation of the shared Mica benchmark corpus.

Each workload mirrors the corresponding `.mica` file in `benchmarks/mica/`:
same operation counts, same loop shape, same output name. The measurement
approach matches `tools/micabench`: calibrate an inner repeat count so one
sample spans ~20ms, warm up twice, take N samples, and report the median
nanoseconds per workload call. This is a baseline, not a Mica runtime: it
answers "how does this language compare to ordinary CPython" rather than
"is this a fair implementation".

Output is TSV with the same columns as the Mica drivers:
    name<TAB>median_ns<TAB>min_ns<TAB>samples
"""

from __future__ import annotations

import statistics
import sys
import time

SAMPLES = 15
BUDGET_SECONDS = 0.020


def language_arithmetic() -> int:
    """100k iterations of an integer multiply-add."""
    index = 0
    total = 0
    while index < 100_000:
        total = total + index * 3
        index = index + 1
    return total


def language_list() -> int:
    """100k indexed reads of an 8-element list."""
    items = [1, 2, 3, 4, 5, 6, 7, 8]
    slot = 0
    index = 0
    total = 0
    while index < 100_000:
        total = total + items[slot]
        slot = slot + 1
        if slot == 8:
            slot = 0
        index = index + 1
    return total


def language_map() -> int:
    """200k dict lookups over a 4-entry dict."""
    table = {"a": 1, "b": 2, "c": 3, "d": 4}
    index = 0
    total = 0
    while index < 100_000:
        total = total + table["a"]
        total = total + table["b"]
        index = index + 1
    return total


def language_map_large() -> int:
    """256 lookups in a 256-entry dict."""
    table = {i: i * 10 for i in range(256)}
    total = 0
    for index in range(256):
        total = total + table[index]
    return total


def language_string() -> int:
    """1000 concatenations of a one-character string (naive rebuild)."""
    text = ""
    index = 0
    while index < 1000:
        text = text + "x"
        index = index + 1
    return len(text)


def language_string_append() -> int:
    """1000 appends through a growable buffer (the amortized form)."""
    parts: list[str] = []
    index = 0
    while index < 1000:
        parts.append("x")
        index = index + 1
    return len("".join(parts))


def language_call() -> int:
    """30k calls to a two-argument helper function."""

    def add(a: int, b: int) -> int:
        return a + b

    index = 0
    total = 0
    while index < 30_000:
        total = add(total, 1)
        index = index + 1
    return total


def harness_empty() -> int:
    """The per-call floor: a workload that does nothing."""
    return 1


WORKLOADS = [
    ("language_arithmetic.mica", language_arithmetic),
    ("language_list.mica", language_list),
    ("language_map.mica", language_map),
    ("language_map_large.mica", language_map_large),
    ("language_string.mica", language_string),
    ("language_string_append.mica", language_string_append),
    ("language_call.mica", language_call),
    ("harness_empty.mica", harness_empty),
]


def measure(name: str, workload) -> tuple[str, int, int, int]:
    # Calibrate one call, then a repeat count for the sampling budget.
    start = time.perf_counter_ns()
    workload()
    single = time.perf_counter_ns() - start
    inner = max(1, int(BUDGET_SECONDS * 1e9) // single) if single else 1

    for _ in range(2):
        for _ in range(inner):
            workload()

    samples: list[int] = []
    for _ in range(SAMPLES):
        start = time.perf_counter_ns()
        for _ in range(inner):
            workload()
        samples.append((time.perf_counter_ns() - start) // inner)

    samples.sort()
    median = samples[len(samples) // 2]
    return name, median, samples[0], len(samples)


def main() -> int:
    samples = int(sys.argv[1]) if len(sys.argv) > 1 else SAMPLES
    del samples  # kept for CLI symmetry; SAMPLES is module-level
    for name, workload in WORKLOADS:
        print("\t".join(str(field) for field in measure(name, workload)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
