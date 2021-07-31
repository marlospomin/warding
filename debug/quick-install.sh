#!/bin/bash

pacman -R man-pages --noconfirm
pacman -Syy ruby glibc libxcrypt --noconfirm
gem install warding
export PATH="`ruby -e 'puts Gem.user_dir'`/bin:$PATH"
warding
