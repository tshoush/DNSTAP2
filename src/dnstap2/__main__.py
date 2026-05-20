"""Allow `python -m dnstap2 ...`."""

from dnstap2.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
