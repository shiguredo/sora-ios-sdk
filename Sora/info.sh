#!/bin/sh

cat << EOS
{
    "branch" : "`git rev-parse --abbrev-ref HEAD`",
    "revision" : "`git rev-parse HEAD`"
}
EOS
