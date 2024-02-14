#!/bin/bash

########

mkdir /tmp/dpkg_hist
rsync -av /var/log/dpkg.log* /tmp/dpkg_hist
pushd /tmp/dpkg_hist
gunzip *.gz
for f in $(ls -rt); do
	cat $f | egrep 'install|remove' >>$HOME/hist.log
done
popd

sort -u $HOME/hist.log >$HOME/dpkg_history.log && rm $HOME/hist.log
rm -f /tmp/dpkg_hist/*
rmdir /tmp/dpkg_hist

########

mkdir /tmp/apt_hist
rsync -av /var/log/apt/history.log* /tmp/apt_hist
pushd /tmp/apt_hist
gunzip *.gz
for f in $(ls -rt); do
	cat $f >>$HOME/hist.log
done
popd

mv $HOME/hist.log $HOME/apt_history.log
rm -f /tmp/apt_hist/*
rmdir /tmp/apt_hist

########
