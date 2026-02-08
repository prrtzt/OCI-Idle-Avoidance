import argparse
import time


def parse_args() -> argparse.Namespace:
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


def main() -> None:
    args = parse_args()
    usage = args.usage
    sleep_time = max(0.0, 1.0 - usage)

    while True:
        start = time.perf_counter()
        while time.perf_counter() - start < usage:
            pass

        if sleep_time > 0:
            time.sleep(sleep_time)


if __name__ == "__main__":
    main()
