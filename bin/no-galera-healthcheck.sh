#!/bin/sh

socat \
    TCP-LISTEN:$1,crlf,reuseaddr,end-close,fork \
    SYSTEM:"
        echo HTTP/1.1 200 OK;
        echo Content-Type\: text/plain;
        echo;
        echo \"Fake report: healthy\";
    "
