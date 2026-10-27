import multiprocessing
import sys

# Helper processes (started by libraries the speech models use) re-run this executable;
# this sends them to their job instead of opening another RealBook window.
multiprocessing.freeze_support()

if "--selftest" in sys.argv:
    from realbook.selftest import main as selftest

    sys.exit(selftest([a for a in sys.argv[1:] if a != "--selftest"]))

from realbook.app import main

main()
