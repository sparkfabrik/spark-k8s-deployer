#!/bin/bash

if find .hooks/ -type f -name '*.sh' ! -executable | grep -q .; then
  echo The following hook files are not executable, please fix.
  find .hooks/ -type f -name '*.sh' ! -executable
  exit 1
fi
