#!/bin/sh
python3 benchmarks/test.py --run --generate-solutions > test/tmp.log
python3 test/readlog.py test/tmp.log
rm test/tmp.log