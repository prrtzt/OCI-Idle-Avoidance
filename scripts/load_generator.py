#!/usr/bin/env python3
"""
Load generator script for OCI Idle Avoidance.

Consumes a configurable fraction of CPU per second to maintain minimum usage.
"""

import argparse
import signal
import sys
import time
from typing import NoReturn

# Flag for graceful shutdown
_shutdown_requested = False


def _signal_handler(signum: int, frame: object) -> None:
    """Handle termination signals gracefully."""
    global _shutdown_requested
    _shutdown_requested = True


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Consume CPU for a fraction of each second."
    )
    parser.add_argument(
        "usage",
        type=float,
        help="CPU busy-loop fraction per second (from 0.0 to 1.0)",
    )
    args = parser.parse_args()

    if args.usage < 0.0 or args.usage > 1.0:
        parser.error("usage must be between 0.0 and 1.0")
    return args


def main() -> NoReturn:
    """Main loop that consumes CPU cycles."""
    # Register signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    args = parse_args()

    usage = args.usage
    sleep_time = max(0.0, 1.0 - usage)

    try:
        while not _shutdown_requested:
            start = time.perf_counter()
            while time.perf_counter() - start < usage:
                if _shutdown_requested:
                    break

            if sleep_time > 0 and not _shutdown_requested:
                time.sleep(sleep_time)
    except Exception as e:
        print(f"Error in main loop: {e}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
