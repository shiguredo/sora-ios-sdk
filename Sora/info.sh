#!/bin/sh

JSON=$(dirname $0)/info.json
cat > $JSON << EOS
{
    "version" : "2021.1",
    "branch" : "`git rev-parse --abbrev-ref HEAD`",
    "revision" : "`git rev-parse HEAD`"
}
EOS
