#!/bin/bash

pacman -R man-pages --noconfirm
pacman -S ruby glibc libxcrypt --noconfirm
gem install bundle rake
git clone https://github.com/marlospomin/warding
export PATH="`ruby -e 'puts Gem.user_dir'`/bin:$PATH"
cd warding
bundle
rake install
warding
