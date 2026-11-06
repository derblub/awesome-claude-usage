#!/bin/sh
# Stand-in for curl: answers the usage request with the scenario's api.json. Reads no network and
# no credentials; the header file and every other argument are ignored.
cat "$CU_SHOT_DIR/api.json"
printf '\n200'
