#!/bin/bash

pacman -R man-pages --noconfirm
pacman -S ruby glibc libxcrypt --noconfirm
gem install bundle rake
export PATH="`ruby -e 'puts Gem.user_dir'`/bin:$PATH"
bundle
rake install
warding
