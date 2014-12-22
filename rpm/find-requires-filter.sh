#!/bin/sh

if [ -x /usr/lib/rpm/redhat/find-requires ] ; then
    FINDREQ=/usr/lib/rpm/redhat/find-requires
else
    FINDREQ=/usr/lib/rpm/find-requires
fi

$FINDREQ $* | grep -v AptPkg

