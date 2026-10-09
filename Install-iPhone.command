#!/bin/zsh
cd -- "${0:A:h}"
python3 scripts/install_iphone.py
result=$?
echo
read "?Press Enter to close."
exit $result
